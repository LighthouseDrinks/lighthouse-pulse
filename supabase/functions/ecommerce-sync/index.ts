// ecommerce-sync — Supabase Edge Function
// Sole owner of ecommerce_stores writes (the table is REVOKEd from authenticated
// in the phase 2 migration). Also handles store connection testing, order
// syncing from Shopify/WooCommerce, and pushing paid orders to Xero as invoices
// + payments against a clearing account.
//
// Deploy: supabase functions deploy ecommerce-sync
// Uses SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from the runtime env.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const FINANCE_ROLES = [
  'managing_director', 'operations_director', 'financial_controller',
  'business_analyst', 'ecommerce_manager',
];

const XERO_API           = 'https://api.xero.com';
const XERO_TOKEN_URL     = 'https://identity.xero.com/connect/token';
const SHOPIFY_API_VER    = '2026-01';
const PUSH_BATCH_LIMIT   = 50;
const SYNC_DEFAULT_DAYS  = 90;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function err(message: string, status = 400): Response {
  return json({ error: message }, status);
}

type AdminClient = ReturnType<typeof createClient>;

// ── Xero token helpers (mirrors xero-oauth so we don't cross-call functions) ──
async function getXeroCreds(adminClient: AdminClient) {
  const { data } = await adminClient
    .from('app_settings')
    .select('key, value')
    .in('key', ['xero_client_id', 'xero_client_secret']);
  const map: Record<string, string> = {};
  for (const row of (data ?? [])) {
    if (row.value && row.value.trim()) map[row.key] = row.value.trim();
  }
  return { clientId: map['xero_client_id'] ?? null, clientSecret: map['xero_client_secret'] ?? null };
}

function basicAuth(id: string, secret: string) {
  return 'Basic ' + btoa(`${id}:${secret}`);
}

async function refreshXeroIfNeeded(
  adminClient: AdminClient,
  clientId: string,
  clientSecret: string,
): Promise<{ ok: boolean; accessToken?: string; tenantId?: string; error?: string }> {
  const { data: conn } = await adminClient
    .from('xero_connection')
    .select('access_token, refresh_token, token_expiry, tenant_id')
    .eq('is_active', true)
    .maybeSingle();
  if (!conn) return { ok: false, error: 'No active Xero connection' };

  const expiry  = new Date(conn.token_expiry).getTime();
  const fiveMin = 5 * 60 * 1000;
  if (expiry > Date.now() + fiveMin) {
    return { ok: true, accessToken: conn.access_token, tenantId: conn.tenant_id };
  }

  console.log('[ecommerce-sync] refreshing Xero token');
  const tokenRes = await fetch(XERO_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization:   basicAuth(clientId, clientSecret),
    },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: conn.refresh_token }).toString(),
  });
  const tokenData = await tokenRes.json();
  if (tokenRes.status !== 200 || tokenData.error) {
    await adminClient
      .from('xero_connection')
      .update({ is_active: false, disconnected_at: new Date().toISOString() })
      .eq('is_active', true);
    return { ok: false, error: 'reconnect_required' };
  }
  const newExpiry = new Date(Date.now() + (tokenData.expires_in as number) * 1000).toISOString();
  const { data: wrote } = await adminClient.rpc('xero_do_refresh', {
    p_access_token:  tokenData.access_token,
    p_refresh_token: tokenData.refresh_token,
    p_token_expiry:  newExpiry,
  });
  if (!wrote) {
    const { data: fresh } = await adminClient
      .from('xero_connection')
      .select('access_token, tenant_id')
      .eq('is_active', true)
      .maybeSingle();
    if (!fresh) return { ok: false, error: 'No active Xero connection after refresh' };
    return { ok: true, accessToken: fresh.access_token, tenantId: fresh.tenant_id };
  }
  return { ok: true, accessToken: tokenData.access_token, tenantId: conn.tenant_id };
}

// ── Store helpers ─────────────────────────────────────────────────────────────
async function loadStore(adminClient: AdminClient, storeId: string) {
  const { data, error } = await adminClient
    .from('ecommerce_stores')
    .select('*')
    .eq('id', storeId)
    .single();
  if (error || !data) return null;
  return data as Record<string, unknown>;
}

async function updateStoreStatus(
  adminClient: AdminClient,
  storeId: string,
  fields: Record<string, unknown>,
) {
  await adminClient.from('ecommerce_stores').update(fields).eq('id', storeId);
}

// ── Shopify ───────────────────────────────────────────────────────────────────
function shopifyHeaders(token: string) {
  return { 'X-Shopify-Access-Token': token, 'Accept': 'application/json' };
}

function shopifyHost(storeUrl: string) {
  // Accept either myshop.myshopify.com or https://myshop.myshopify.com
  return storeUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '');
}

async function shopifyTestConnection(storeUrl: string, token: string) {
  const url = `https://${shopifyHost(storeUrl)}/admin/api/${SHOPIFY_API_VER}/shop.json`;
  console.log('[ecommerce-sync] shopify test:', url);
  const res = await fetch(url, { headers: shopifyHeaders(token) });
  if (res.status !== 200) {
    const text = await res.text().catch(() => '');
    return { ok: false, error: `Shopify ${res.status}: ${text.slice(0, 200)}` };
  }
  const data = await res.json();
  return { ok: true, shop_name: data?.shop?.name ?? 'Unknown' };
}

// Parses the Shopify Link response header to find the next page URL.
// Format example: `<https://...&page_info=abc>; rel="next", <...>; rel="previous"`
function shopifyNextLink(linkHeader: string | null): string | null {
  if (!linkHeader) return null;
  const m = linkHeader.match(/<([^>]+)>;\s*rel="next"/);
  return m ? m[1] : null;
}

async function shopifyFetchOrders(storeUrl: string, token: string, since: string) {
  const host = shopifyHost(storeUrl);
  // financial_status=paid excludes pending / refunded / cancelled — only push
  // genuinely-paid orders to Xero.
  let url: string | null = `https://${host}/admin/api/${SHOPIFY_API_VER}/orders.json`
    + `?status=any&financial_status=paid&limit=250&created_at_min=${encodeURIComponent(since)}`;
  const orders: Array<Record<string, unknown>> = [];
  while (url) {
    console.log('[ecommerce-sync] shopify fetch:', url);
    const res = await fetch(url, { headers: shopifyHeaders(token) });
    if (res.status !== 200) {
      const text = await res.text().catch(() => '');
      throw new Error(`Shopify orders ${res.status}: ${text.slice(0, 200)}`);
    }
    const data = await res.json();
    const batch = (data?.orders ?? []) as Array<Record<string, unknown>>;
    orders.push(...batch);
    url = shopifyNextLink(res.headers.get('Link'));
  }
  return orders;
}

// Builds normalised item rows from a Shopify order
function shopifyItemsForOrder(o: Record<string, unknown>) {
  const items: Array<Record<string, unknown>> = [];

  // Products — net of line-level discount_allocations (actual allocated discount)
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    const qty   = Number(li.quantity ?? 1);
    const price = Number(li.price ?? 0);
    let discount = 0;
    for (const d of ((li.discount_allocations ?? []) as Array<Record<string, unknown>>)) {
      discount += Number(d.amount ?? 0);
    }
    const lineTotal = (qty * price) - discount;
    const isGiftCard = (li.product_type as string)?.toLowerCase() === 'gift cards' || li.gift_card === true;
    items.push({
      sku:          li.sku ?? null,
      product_name: (li.title as string) ?? 'Unknown',
      quantity:     qty,
      unit_price:   price,
      line_total:   lineTotal,
      item_type:    isGiftCard ? 'gift_card_issued' : 'product',
      xero_account_key: isGiftCard ? 'gift_cards' : 'ecommerce_sales',
    });
  }

  // Shipping
  for (const s of ((o.shipping_lines ?? []) as Array<Record<string, unknown>>)) {
    const shipPrice = Number(s.price ?? 0);
    if (shipPrice <= 0) continue;
    items.push({
      sku:          null,
      product_name: (s.title as string) || 'Shipping',
      quantity:     1,
      unit_price:   shipPrice,
      line_total:   shipPrice,
      item_type:    'shipping',
      xero_account_key: 'shipping_revenue',
    });
  }

  // Order-level discount (single negative line). Most discount value is already
  // applied above via discount_allocations on line items, so this is mostly 0
  // — but Shopify occasionally emits order-level adjustments we want recorded.
  const orderDiscountTotal = Number((o.total_discounts as string | number) ?? 0);
  let lineDiscountsSum = 0;
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    for (const d of ((li.discount_allocations ?? []) as Array<Record<string, unknown>>)) {
      lineDiscountsSum += Number(d.amount ?? 0);
    }
  }
  const residualDiscount = orderDiscountTotal - lineDiscountsSum;
  if (residualDiscount > 0.005) {
    items.push({
      sku:          null,
      product_name: 'Order discount',
      quantity:     1,
      unit_price:   -residualDiscount,
      line_total:   -residualDiscount,
      item_type:    'discount',
      xero_account_key: 'ecommerce_discounts',
    });
  }
  return items;
}

// ── WooCommerce ───────────────────────────────────────────────────────────────
function wooHeaders(key: string, secret: string) {
  return { Authorization: basicAuth(key, secret), 'Accept': 'application/json' };
}

function wooHost(storeUrl: string) {
  return storeUrl.replace(/\/+$/, '');
}

async function wooTestConnection(storeUrl: string, key: string, secret: string) {
  const url = `${wooHost(storeUrl)}/wp-json/wc/v3/system_status`;
  console.log('[ecommerce-sync] woo test:', url);
  const res = await fetch(url, { headers: wooHeaders(key, secret) });
  if (res.status !== 200) {
    const text = await res.text().catch(() => '');
    return { ok: false, error: `WooCommerce ${res.status}: ${text.slice(0, 200)}` };
  }
  return { ok: true, shop_name: 'WooCommerce store' };
}

async function wooFetchOrders(storeUrl: string, key: string, secret: string, since: string) {
  const orders: Array<Record<string, unknown>> = [];
  let page = 1;
  while (true) {
    const url = `${wooHost(storeUrl)}/wp-json/wc/v3/orders`
      + `?per_page=100&page=${page}&status=completed,processing&after=${encodeURIComponent(since)}`;
    console.log('[ecommerce-sync] woo fetch:', url);
    const res = await fetch(url, { headers: wooHeaders(key, secret) });
    if (res.status !== 200) {
      const text = await res.text().catch(() => '');
      throw new Error(`WooCommerce orders ${res.status}: ${text.slice(0, 200)}`);
    }
    const batch = await res.json() as Array<Record<string, unknown>>;
    orders.push(...batch);
    const totalPages = parseInt(res.headers.get('X-WP-TotalPages') || '1', 10);
    if (page >= totalPages || batch.length === 0) break;
    page++;
  }
  return orders;
}

function wooItemsForOrder(o: Record<string, unknown>) {
  const items: Array<Record<string, unknown>> = [];
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    const qty   = Number(li.quantity ?? 1);
    const total = Number(li.total ?? 0);
    items.push({
      sku:          li.sku ?? null,
      product_name: (li.name as string) ?? 'Unknown',
      quantity:     qty,
      unit_price:   qty > 0 ? total / qty : total,
      line_total:   total,
      item_type:    'product',
      xero_account_key: 'ecommerce_sales',
    });
  }
  for (const s of ((o.shipping_lines ?? []) as Array<Record<string, unknown>>)) {
    const total = Number(s.total ?? 0);
    if (total <= 0) continue;
    items.push({
      sku:          null,
      product_name: (s.method_title as string) || 'Shipping',
      quantity:     1,
      unit_price:   total,
      line_total:   total,
      item_type:    'shipping',
      xero_account_key: 'shipping_revenue',
    });
  }
  const discount = Number((o.discount_total as string | number) ?? 0);
  if (discount > 0.005) {
    items.push({
      sku:          null,
      product_name: 'Order discount',
      quantity:     1,
      unit_price:   -discount,
      line_total:   -discount,
      item_type:    'discount',
      xero_account_key: 'ecommerce_discounts',
    });
  }
  return items;
}

// ── Common: upsert orders + items into Pulse DB ───────────────────────────────
function shopifyNormaliseOrder(storeId: string, o: Record<string, unknown>) {
  const customer = (o.customer ?? {}) as Record<string, unknown>;
  const gateways = (o.payment_gateway_names ?? []) as string[];
  const hasGiftCard = Array.isArray(gateways) && gateways.some((g) => g === 'gift_card');
  return {
    store_id:       storeId,
    external_id:    String(o.id),
    order_number:   String(o.order_number ?? o.name ?? o.id),
    customer_name:  [customer.first_name, customer.last_name].filter(Boolean).join(' ') || null,
    customer_email: (customer.email as string) ?? (o.email as string) ?? null,
    total_amount:   Number(o.total_price ?? 0),
    currency:       (o.currency as string) ?? 'EUR',
    status:         (o.financial_status as string) ?? 'paid',
    ordered_at:     (o.created_at as string) ?? new Date().toISOString(),
    payment_gateway: gateways[0] ?? null,
    payment_status:  (o.financial_status as string) ?? null,
    raw_data:       { source: 'shopify', has_gift_card_payment: hasGiftCard, order_id: o.id },
  };
}

function wooNormaliseOrder(storeId: string, o: Record<string, unknown>) {
  const billing = (o.billing ?? {}) as Record<string, unknown>;
  return {
    store_id:        storeId,
    external_id:     String(o.id),
    order_number:    String(o.number ?? o.id),
    customer_name:   [billing.first_name, billing.last_name].filter(Boolean).join(' ') || null,
    customer_email:  (billing.email as string) ?? null,
    total_amount:    Number(o.total ?? 0),
    currency:        (o.currency as string) ?? 'EUR',
    status:          (o.status as string) ?? 'completed',
    ordered_at:      (o.date_created_gmt as string) ? `${o.date_created_gmt}Z` : new Date().toISOString(),
    payment_gateway: (o.payment_method as string) ?? null,
    payment_status:  (o.status as string) ?? null,
    raw_data:        { source: 'woocommerce', has_gift_card_payment: false, order_id: o.id },
  };
}

async function upsertOrders(
  adminClient: AdminClient,
  storeId: string,
  normalised: Array<{ order: Record<string, unknown>; items: Array<Record<string, unknown>> }>,
) {
  if (!normalised.length) return { upserted: 0 };

  // Upsert orders one batch — supabase-js handles the array
  const orderRows = normalised.map((n) => n.order);
  const { data: upserted, error: orderErr } = await adminClient
    .from('ecommerce_orders')
    .upsert(orderRows, { onConflict: 'store_id,external_id' })
    .select('id, external_id');
  if (orderErr) throw new Error(`order upsert: ${orderErr.message}`);

  // Map external_id -> internal id so we can attach items
  const idMap = new Map<string, string>();
  for (const row of (upserted ?? [])) idMap.set(row.external_id, row.id);

  // Replace items for each order (delete then insert) — simpler than diffing
  // and orders are immutable from the source side once paid.
  const orderIds = Array.from(idMap.values()).filter(Boolean);
  if (orderIds.length) {
    await adminClient.from('ecommerce_order_items').delete().in('order_id', orderIds);
    const itemRows: Array<Record<string, unknown>> = [];
    for (const n of normalised) {
      const orderId = idMap.get(String(n.order.external_id));
      if (!orderId) continue;
      for (const it of n.items) itemRows.push({ ...it, order_id: orderId });
    }
    if (itemRows.length) {
      const { error: itemErr } = await adminClient.from('ecommerce_order_items').insert(itemRows);
      if (itemErr) throw new Error(`item insert: ${itemErr.message}`);
    }
  }
  return { upserted: orderRows.length };
}

// ── main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return err('Unauthorized', 401);

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const anonKey     = Deno.env.get('SUPABASE_ANON_KEY')!;

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return err('Unauthorized', 401);

    const adminClient = createClient(supabaseUrl, serviceKey);
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role')
      .eq('auth_user_id', user.id)
      .single();

    if (!appUser || !FINANCE_ROLES.includes(appUser.role)) {
      return err('Forbidden — finance roles only', 403);
    }

    const userId = appUser.id as string;
    const body   = await req.json() as Record<string, unknown>;
    const action = body.action as string;

    // ── add_store ───────────────────────────────────────────────────────────
    if (action === 'add_store') {
      const row = {
        name:                 ((body.name as string)        || '').trim(),
        platform:             ((body.platform as string)    || '').trim(),
        store_url:            ((body.store_url as string)   || '').trim(),
        api_key:              ((body.api_key as string)     || '').trim(),
        api_secret:           ((body.api_secret as string)  || '').trim(),
        sync_from_date:       (body.sync_from_date as string) || null,
        xero_sales_account:   (body.xero_sales_account as string) || null,
        xero_shipping_account: (body.xero_shipping_account as string) || null,
        created_by:           userId,
        is_active:            true,
        connection_status:    'disconnected',
      };
      if (!row.name || !row.platform || !row.store_url) return err('Missing name, platform, or store_url', 400);

      const { data, error } = await adminClient
        .from('ecommerce_stores')
        .insert(row)
        .select('id')
        .single();
      if (error) return err(`Failed to add store: ${error.message}`, 500);
      return json({ ok: true, id: data?.id });
    }

    // ── update_store ────────────────────────────────────────────────────────
    if (action === 'update_store') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);

      const updates: Record<string, unknown> = {};
      const setIf = (field: string, src: string) => {
        if (src in body && typeof body[src] !== 'undefined') {
          const v = body[src];
          updates[field] = typeof v === 'string' ? v.trim() : v;
        }
      };
      setIf('name', 'name');
      setIf('store_url', 'store_url');
      setIf('sync_from_date', 'sync_from_date');
      setIf('xero_sales_account', 'xero_sales_account');
      setIf('xero_shipping_account', 'xero_shipping_account');
      // Only overwrite credentials if explicitly provided non-empty (Configure
      // panel can omit them to keep the existing token in place).
      if (typeof body.api_key === 'string' && body.api_key.trim()) updates.api_key = body.api_key.trim();
      if (typeof body.api_secret === 'string' && body.api_secret.trim()) updates.api_secret = body.api_secret.trim();
      updates.updated_at = new Date().toISOString();

      const { error } = await adminClient.from('ecommerce_stores').update(updates).eq('id', id);
      if (error) return err(`Failed to update store: ${error.message}`, 500);
      return json({ ok: true });
    }

    // ── deactivate_store ────────────────────────────────────────────────────
    if (action === 'deactivate_store') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);
      const { error } = await adminClient
        .from('ecommerce_stores')
        .update({ is_active: false, updated_at: new Date().toISOString() })
        .eq('id', id);
      if (error) return err(`Failed to deactivate store: ${error.message}`, 500);
      return json({ ok: true });
    }

    // ── store_test_connection ───────────────────────────────────────────────
    if (action === 'store_test_connection') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);
      const store = await loadStore(adminClient, id);
      if (!store) return err('Store not found', 404);

      let result: { ok: boolean; error?: string; shop_name?: string };
      if (store.platform === 'shopify') {
        result = await shopifyTestConnection(store.store_url as string, store.api_key as string);
      } else if (store.platform === 'woocommerce') {
        result = await wooTestConnection(store.store_url as string, store.api_key as string, store.api_secret as string);
      } else {
        return err(`Unsupported platform: ${store.platform}`, 400);
      }

      await updateStoreStatus(adminClient, id, {
        connection_status: result.ok ? 'connected' : 'error',
        error_message:     result.ok ? null : result.error,
        updated_at:        new Date().toISOString(),
      });
      return result.ok ? json({ ok: true, shop_name: result.shop_name }) : err(result.error || 'Test failed', 400);
    }

    // ── store_sync_orders ───────────────────────────────────────────────────
    if (action === 'store_sync_orders') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);
      const store = await loadStore(adminClient, id);
      if (!store) return err('Store not found', 404);

      // Sync window: last_synced_at > sync_from_date > 90 days ago.
      // 90-day cap avoids edge function timeout on a fresh store with years
      // of orders. Operator can push sync_from_date back manually for backfill.
      let since: string;
      if (store.last_synced_at) since = store.last_synced_at as string;
      else if (store.sync_from_date) since = `${store.sync_from_date}T00:00:00Z`;
      else since = new Date(Date.now() - SYNC_DEFAULT_DAYS * 24 * 60 * 60 * 1000).toISOString();

      try {
        let rawOrders: Array<Record<string, unknown>>;
        let normalised: Array<{ order: Record<string, unknown>; items: Array<Record<string, unknown>> }>;
        if (store.platform === 'shopify') {
          rawOrders  = await shopifyFetchOrders(store.store_url as string, store.api_key as string, since);
          normalised = rawOrders.map((o) => ({
            order: shopifyNormaliseOrder(id, o),
            items: shopifyItemsForOrder(o),
          }));
        } else if (store.platform === 'woocommerce') {
          rawOrders  = await wooFetchOrders(store.store_url as string, store.api_key as string, store.api_secret as string, since);
          normalised = rawOrders.map((o) => ({
            order: wooNormaliseOrder(id, o),
            items: wooItemsForOrder(o),
          }));
        } else {
          return err(`Unsupported platform: ${store.platform}`, 400);
        }

        await upsertOrders(adminClient, id, normalised);

        // Recompute total + revenue from the table (avoids double-counting on re-sync)
        const { count: totalCount } = await adminClient
          .from('ecommerce_orders')
          .select('id', { count: 'exact', head: true })
          .eq('store_id', id);

        const { data: sumRows } = await adminClient
          .from('ecommerce_orders')
          .select('total_amount')
          .eq('store_id', id);
        const totalRevenue = (sumRows ?? []).reduce(
          (sum: number, r: { total_amount: number | null }) => sum + Number(r.total_amount ?? 0), 0,
        );

        await updateStoreStatus(adminClient, id, {
          connection_status:   'connected',
          error_message:       null,
          last_synced_at:      new Date().toISOString(),
          orders_synced_count: totalCount ?? 0,
          revenue_synced:      totalRevenue,
          updated_at:          new Date().toISOString(),
        });

        return json({ ok: true, fetched: rawOrders.length, total_orders: totalCount ?? 0 });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error('[ecommerce-sync] sync error:', msg);
        await updateStoreStatus(adminClient, id, {
          connection_status: 'error',
          error_message:     msg,
          updated_at:        new Date().toISOString(),
        });
        return err(msg, 500);
      }
    }

    // ── store_push_to_xero ──────────────────────────────────────────────────
    if (action === 'store_push_to_xero') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);
      const store = await loadStore(adminClient, id);
      if (!store) return err('Store not found', 404);

      // Preflight: all required mappings present
      const { data: mappings } = await adminClient
        .from('xero_mappings')
        .select('mapping_key, xero_account_code, xero_tax_type');
      const mapByKey = new Map<string, { code: string | null; tax: string | null }>();
      for (const m of (mappings ?? [])) {
        mapByKey.set(m.mapping_key as string, {
          code: (m.xero_account_code as string | null) ?? null,
          tax:  (m.xero_tax_type    as string | null) ?? null,
        });
      }
      const required = ['ecommerce_sales', 'shipping_revenue', 'ecommerce_discounts', 'ecommerce_payment_clearing'];
      for (const key of required) {
        const m = mapByKey.get(key);
        if (!m || !m.code) {
          return err(
            'Configure Xero account codes for Ecommerce Sales, Shipping Revenue, '
            + 'Ecommerce Discounts, and Ecommerce Payment Clearing in Xero Mappings before pushing.',
            400,
          );
        }
      }

      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const tok = await refreshXeroIfNeeded(adminClient, clientId, clientSecret);
      if (!tok.ok) return err(tok.error || 'Xero token error', 400);

      // Fetch unpushed orders with their items
      const { data: unpushed } = await adminClient
        .from('ecommerce_orders')
        .select('id, external_id, order_number, customer_name, customer_email, total_amount, currency, ordered_at, raw_data')
        .eq('store_id', id)
        .is('xero_push_status', null)
        .limit(PUSH_BATCH_LIMIT);
      const orders = (unpushed ?? []) as Array<Record<string, unknown>>;
      if (orders.length === 0) return json({ pushed: 0, failed: 0, skipped: 0 });

      // Skip gift-card-payment orders (Phase 3 will handle properly)
      const skipped: Array<string> = [];
      const pushable: typeof orders = [];
      for (const o of orders) {
        const raw = (o.raw_data ?? {}) as Record<string, unknown>;
        if (raw.has_gift_card_payment) {
          skipped.push(o.id as string);
          continue;
        }
        if (!o.customer_email) {
          skipped.push(o.id as string);
          continue;
        }
        pushable.push(o);
      }

      // Mark skipped orders so they don't keep appearing in the queue
      if (skipped.length) {
        await adminClient
          .from('ecommerce_orders')
          .update({
            xero_push_status: 'skipped',
            xero_error:       'Gift card payment or missing email — requires manual handling',
          })
          .in('id', skipped);
      }
      if (pushable.length === 0) return json({ pushed: 0, failed: 0, skipped: skipped.length });

      // Load items for the pushable orders
      const orderIds = pushable.map((o) => o.id as string);
      const { data: itemRows } = await adminClient
        .from('ecommerce_order_items')
        .select('order_id, product_name, quantity, unit_price, line_total, item_type, xero_account_key')
        .in('order_id', orderIds);
      const itemsByOrder = new Map<string, Array<Record<string, unknown>>>();
      for (const it of (itemRows ?? [])) {
        const arr = itemsByOrder.get(it.order_id as string) ?? [];
        arr.push(it);
        itemsByOrder.set(it.order_id as string, arr);
      }

      // If any line uses gift_cards mapping, require that mapping too
      const usesGiftCards = (itemRows ?? []).some((i) => i.xero_account_key === 'gift_cards');
      if (usesGiftCards) {
        const giftMap = mapByKey.get('gift_cards');
        if (!giftMap || !giftMap.code) {
          return err('Some orders include gift card sales — configure the Gift Cards Xero account before pushing.', 400);
        }
      }

      // Contact resolution
      const contactByEmail = new Map<string, string>();
      for (const o of pushable) {
        const email = (o.customer_email as string).trim();
        if (contactByEmail.has(email)) continue;
        const whereClause = `EmailAddress=="${email.replace(/"/g, '\\"')}"`;
        const findUrl = `${XERO_API}/api.xro/2.0/Contacts?where=${encodeURIComponent(whereClause)}&summaryOnly=true`;
        console.log('[ecommerce-sync] contact find:', email);
        const fRes = await fetch(findUrl, {
          headers: {
            Authorization: `Bearer ${tok.accessToken}`,
            'Xero-tenant-id': tok.tenantId!,
            'Accept': 'application/json',
          },
        });
        const fData = await fRes.json().catch(() => ({}));
        const existing = ((fData?.Contacts ?? []) as Array<Record<string, unknown>>)[0];
        if (existing?.ContactID) {
          contactByEmail.set(email, existing.ContactID as string);
          continue;
        }
        // Create
        const createRes = await fetch(`${XERO_API}/api.xro/2.0/Contacts`, {
          method: 'POST',
          headers: {
            Authorization:    `Bearer ${tok.accessToken}`,
            'Xero-tenant-id': tok.tenantId!,
            'Content-Type':   'application/json',
            'Accept':         'application/json',
          },
          body: JSON.stringify({
            Contacts: [{ Name: (o.customer_name as string) || email, EmailAddress: email }],
          }),
        });
        const cData = await createRes.json().catch(() => ({}));
        const created = ((cData?.Contacts ?? []) as Array<Record<string, unknown>>)[0];
        if (created?.ContactID) {
          contactByEmail.set(email, created.ContactID as string);
        } else {
          console.warn('[ecommerce-sync] contact create failed for', email, JSON.stringify(cData).slice(0, 200));
        }
      }

      // Build invoice payloads
      const today = new Date().toISOString().split('T')[0];
      const invoicePayloads: Array<Record<string, unknown>> = [];
      const ordersInOrder: typeof pushable = []; // matches index of invoicePayloads
      for (const o of pushable) {
        const email = (o.customer_email as string).trim();
        const contactId = contactByEmail.get(email);
        if (!contactId) continue;
        const items = itemsByOrder.get(o.id as string) ?? [];
        if (items.length === 0) continue;
        const lineItems = items.map((it) => {
          const key  = (it.xero_account_key as string) || 'ecommerce_sales';
          const map  = mapByKey.get(key);
          return {
            Description: it.product_name,
            Quantity:    Number(it.quantity ?? 1),
            UnitAmount:  Number(it.unit_price ?? 0),
            AccountCode: map?.code,
            TaxType:     map?.tax || undefined,
          };
        });
        invoicePayloads.push({
          Type:         'ACCREC',
          Contact:      { ContactID: contactId },
          Date:         (o.ordered_at as string)?.split('T')[0] ?? today,
          DueDate:      today,
          Reference:    o.order_number,
          Status:       'AUTHORISED',
          CurrencyCode: o.currency ?? 'EUR',
          LineItems:    lineItems,
        });
        ordersInOrder.push(o);
      }

      let pushed = 0;
      let failed = 0;
      if (invoicePayloads.length) {
        const invRes = await fetch(`${XERO_API}/api.xro/2.0/Invoices?summarizeErrors=false`, {
          method: 'POST',
          headers: {
            Authorization:    `Bearer ${tok.accessToken}`,
            'Xero-tenant-id': tok.tenantId!,
            'Content-Type':   'application/json',
            'Accept':         'application/json',
          },
          body: JSON.stringify({ Invoices: invoicePayloads }),
        });
        const invData = await invRes.json().catch(() => ({}));
        console.log('[ecommerce-sync] invoice batch status:', invRes.status, 'count:', (invData?.Invoices ?? []).length);

        const returned = ((invData?.Invoices ?? []) as Array<Record<string, unknown>>);
        const paymentPayloads: Array<Record<string, unknown>> = [];
        const orderIdToPaymentIndex = new Map<string, number>();

        // Match returned invoices to source orders by index (Xero preserves order)
        for (let i = 0; i < ordersInOrder.length; i++) {
          const order = ordersInOrder[i];
          const ret   = returned[i];
          if (!ret) {
            await adminClient.from('ecommerce_orders').update({
              xero_push_status: 'failed',
              xero_error:       'No response from Xero for this invoice',
            }).eq('id', order.id as string);
            failed++;
            continue;
          }
          if (ret.HasErrors || ret.StatusAttributeString === 'ERROR') {
            const valErr = (ret.ValidationErrors ?? []) as Array<Record<string, unknown>>;
            const msg = valErr.map((v) => v.Message).join('; ') || 'Xero invoice error';
            await adminClient.from('ecommerce_orders').update({
              xero_push_status: 'failed',
              xero_error:       msg,
            }).eq('id', order.id as string);
            failed++;
            continue;
          }

          await adminClient.from('ecommerce_orders').update({
            xero_invoice_id: ret.InvoiceID,
            xero_contact_id: contactByEmail.get((order.customer_email as string).trim()),
            xero_push_status: 'invoiced',
            xero_pushed_at:   new Date().toISOString(),
          }).eq('id', order.id as string);

          // Queue payment
          const clearing = mapByKey.get('ecommerce_payment_clearing');
          paymentPayloads.push({
            Invoice: { InvoiceID: ret.InvoiceID },
            Account: { Code: clearing?.code },
            Date:    (order.ordered_at as string)?.split('T')[0] ?? today,
            Amount:  Number(order.total_amount ?? 0),
          });
          orderIdToPaymentIndex.set(order.id as string, paymentPayloads.length - 1);
        }

        // Payment batch
        if (paymentPayloads.length) {
          const payRes = await fetch(`${XERO_API}/api.xro/2.0/Payments?summarizeErrors=false`, {
            method: 'POST',
            headers: {
              Authorization:    `Bearer ${tok.accessToken}`,
              'Xero-tenant-id': tok.tenantId!,
              'Content-Type':   'application/json',
              'Accept':         'application/json',
            },
            body: JSON.stringify({ Payments: paymentPayloads }),
          });
          const payData = await payRes.json().catch(() => ({}));
          const payments = ((payData?.Payments ?? []) as Array<Record<string, unknown>>);
          console.log('[ecommerce-sync] payment batch status:', payRes.status, 'count:', payments.length);

          for (const [orderId, idx] of orderIdToPaymentIndex.entries()) {
            const ret = payments[idx];
            if (ret && !ret.HasErrors) {
              await adminClient.from('ecommerce_orders').update({
                xero_payment_id:  ret.PaymentID,
                xero_push_status: 'pushed',
              }).eq('id', orderId);
              pushed++;
            } else {
              const valErr = (ret?.ValidationErrors ?? []) as Array<Record<string, unknown>>;
              const msg = valErr.map((v) => v.Message).join('; ') || 'Payment error';
              await adminClient.from('ecommerce_orders').update({
                xero_push_status: 'payment_failed',
                xero_error:       `Invoice OK but payment failed: ${msg}`,
              }).eq('id', orderId);
              failed++;
            }
          }
        }
      }

      return json({ pushed, failed, skipped: skipped.length, total_processed: pushable.length });
    }

    return err('Unknown action: ' + action, 400);

  } catch (e) {
    console.error('[ecommerce-sync] unhandled error:', e);
    return err(String(e), 500);
  }
});
