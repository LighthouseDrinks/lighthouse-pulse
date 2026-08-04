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

// Role policy is read from the `roles` table at request time
// (has_finance_access). See supabase/migrations/roles_table.sql.

const XERO_API           = 'https://api.xero.com';
const XERO_TOKEN_URL     = 'https://identity.xero.com/connect/token';
const SHOPIFY_API_VER    = '2026-01';
const PUSH_BATCH_LIMIT   = 50;
const SYNC_DEFAULT_DAYS  = 90;
const IE_VAT_RATE        = 0.23;   // Irish standard VAT — stripped from store RRP

// Store RRP is treated as VAT-inclusive; return it ex-VAT (2 dp), or null.
function rrpExVat(inclPrice: number): number | null {
  return inclPrice > 0 ? Math.round((inclPrice / (1 + IE_VAT_RATE)) * 100) / 100 : null;
}

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

// ── UPS helpers (Rating API with negotiated rates) ────────────────────────────
// Fully automatic: nothing UPS-related is configured in the UI. Client ID/Secret
// are edge-function env secrets (UPS_CLIENT_ID / UPS_CLIENT_SECRET); the account
// number and warehouse origin are hard-coded below. UPS_BASE defaults to
// production; point it at the UPS CIE test host to dry-run.
const UPS_BASE = Deno.env.get('UPS_BASE') || 'https://onlinetools.ups.com';
const UPS_RATE_VERSION = Deno.env.get('UPS_RATE_VERSION') || 'v2409';

// Lighthouse warehouse ship-from (origin). Same for every order, so it's baked in
// rather than entered by a user. Account can be overridden via env if it changes.
const UPS_ACCOUNT = Deno.env.get('UPS_ACCOUNT') || '7X933W';
const UPS_DEFAULT_SERVICE = '11';   // UPS Standard — fallback when the order's service is unknown
const UPS_DEFAULT_WEIGHT_KG = 1;    // fallback when the order carries no weight
const UPS_ORIGIN = {
  name:     'Lighthouse Drinks',
  address1: 'Unit 3/4 Cork Bonded Warehouses',
  address2: 'Little Island',
  city:     'Cork',
  postal:   'T45YF43',
  country:  'IE',
  state:    '',
};

// Maps a store shipping-method title/code to a UPS service code (mirrors what the
// real label uses). First match wins; falls back to Standard.
const UPS_SERVICE_MAP: Array<{ re: RegExp; code: string }> = [
  { re: /worldwide\s*express\s*plus/i,                 code: '54' },
  { re: /(worldwide\s*express\s*saver|express\s*saver)/i, code: '65' },
  { re: /worldwide\s*express/i,                        code: '07' },
  { re: /(worldwide\s*expedited|expedited)/i,          code: '08' },
  { re: /access\s*point/i,                             code: '70' },
  { re: /next\s*day\s*air\s*saver/i,                   code: '13' },
  { re: /next\s*day\s*air\s*early/i,                   code: '14' },
  { re: /next\s*day\s*air/i,                           code: '01' },
  { re: /(2nd\s*day\s*air|second\s*day)/i,             code: '02' },
  { re: /3\s*day\s*select/i,                           code: '12' },
  { re: /standard/i,                                   code: '11' },
  { re: /ground/i,                                     code: '03' },
  { re: /\bups\b/i,                                    code: '11' }, // generic "UPS" -> Standard
];
function resolveUpsServiceCode(title: string): string {
  const t = title || '';
  for (const m of UPS_SERVICE_MAP) if (m.re.test(t)) return m.code;
  return UPS_DEFAULT_SERVICE;
}

async function getUpsToken(): Promise<{ ok: boolean; token?: string; error?: string }> {
  const id     = Deno.env.get('UPS_CLIENT_ID');
  const secret = Deno.env.get('UPS_CLIENT_SECRET');
  if (!id || !secret) return { ok: false, error: 'UPS credentials not configured (UPS_CLIENT_ID / UPS_CLIENT_SECRET).' };
  const res = await fetch(`${UPS_BASE}/security/v1/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Authorization: basicAuth(id, secret) },
    body: new URLSearchParams({ grant_type: 'client_credentials' }).toString(),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) {
    return { ok: false, error: 'UPS token: ' + (data.error_description || data.error || ('HTTP ' + res.status)) };
  }
  return { ok: true, token: data.access_token as string };
}

interface UpsAddress {
  name?: string | null; company?: string | null;
  address1?: string | null; address2?: string | null;
  city?: string | null; postal?: string | null; country?: string | null; state?: string | null;
  residential?: boolean | null;
}

// Rates a single shipment using the hard-coded Lighthouse origin, the order's full
// destination, weight and (per-order) service — mirroring the real label inputs.
// Returns the account-negotiated total where available, otherwise the published total.
async function upsRate(
  token: string,
  dest: UpsAddress,
  weightKg: number,
  serviceCode: string,
): Promise<{ ok: boolean; cost?: number; currency?: string; negotiated?: boolean; error?: string }> {
  const destAddr = () => {
    const lines = [dest.address1, dest.address2].filter(Boolean) as string[];
    const out: Record<string, unknown> = {
      City:              dest.city  || '',
      PostalCode:        (dest.postal || '').replace(/\s+/g, ''),
      CountryCode:       (dest.country || '').toUpperCase(),
      StateProvinceCode: dest.state || '',
    };
    if (lines.length) out.AddressLine = lines;
    // UPS treats presence of this (empty) node as "residential", which affects price.
    if (dest.residential) out.ResidentialAddressIndicator = '';
    return out;
  };
  const shipperAddr = {
    AddressLine:       [UPS_ORIGIN.address1, UPS_ORIGIN.address2],
    City:              UPS_ORIGIN.city,
    PostalCode:        UPS_ORIGIN.postal.replace(/\s+/g, ''),
    CountryCode:       UPS_ORIGIN.country,
    StateProvinceCode: UPS_ORIGIN.state,
  };
  const payload = {
    RateRequest: {
      Request: { TransactionReference: { CustomerContext: 'lighthouse-pulse shipping report' } },
      Shipment: {
        Shipper:  { Name: UPS_ORIGIN.name, ShipperNumber: UPS_ACCOUNT, Address: shipperAddr },
        ShipFrom: { Name: UPS_ORIGIN.name, Address: shipperAddr },
        ShipTo:   { Name: dest.name || 'Customer', Address: destAddr() },
        Service:  { Code: serviceCode || UPS_DEFAULT_SERVICE },
        Package: {
          PackagingType: { Code: '02' },
          PackageWeight: { UnitOfMeasurement: { Code: 'KGS' }, Weight: String(weightKg) },
        },
        ShipmentRatingOptions: { NegotiatedRatesIndicator: 'Y' },
      },
    },
  };
  const res = await fetch(`${UPS_BASE}/api/rating/${UPS_RATE_VERSION}/Rate`, {
    method: 'POST',
    headers: {
      Authorization:  `Bearer ${token}`,
      'Content-Type': 'application/json',
      'Accept':       'application/json',
      transId:        crypto.randomUUID(),
      transactionSrc: 'lighthouse-pulse',
    },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data?.response?.errors?.[0]?.message || ('HTTP ' + res.status);
    return { ok: false, error: 'UPS rate: ' + msg };
  }
  const rs = data?.RateResponse?.RatedShipment;
  const shipment = Array.isArray(rs) ? rs[0] : rs;
  if (!shipment) return { ok: false, error: 'UPS rate: no shipment in response' };
  const negCharge = shipment?.NegotiatedRateCharges?.TotalCharge;
  const charge = negCharge || shipment?.TotalCharges;
  if (!charge || charge.MonetaryValue == null) return { ok: false, error: 'UPS rate: no charge in response' };
  return { ok: true, cost: Number(charge.MonetaryValue), currency: (charge.CurrencyCode as string) || 'EUR', negotiated: !!negCharge };
}

// ── Fulfild (fulfilment platform) actual booked shipping cost ─────────────────
// Fulfild is Supabase Postgres and the source of truth for the booked carrier
// cost (shipments.cost). We read its least-privilege view `pulse_order_shipping`
// via a read-only connection string (FULFILD_DB_URL). When the secret is absent
// the integration is simply disabled and the report falls back to DPD flat rate
// / UPS quote. Matching key is platform + external_order_id.
interface FulfildRow {
  carrier: string | null;
  service: string | null;
  weight_kg: number | null;
  cost: number | null;
  currency: string | null;
}

// Normalises Fulfild's carrier_code / service text to Pulse's carrier keys.
function normalizeCarrier(raw: string | null | undefined): string {
  const t = (raw || '').toLowerCase();
  if (t.includes('ups')) return 'ups';
  if (t.includes('dpd')) return 'dpd';
  if (t.includes('post')) return 'anpost';
  return t.trim() || 'unmatched';
}

async function fetchFulfildCosts(externalIds: string[]): Promise<Map<string, FulfildRow>> {
  const map = new Map<string, FulfildRow>();
  const dbUrl = Deno.env.get('FULFILD_DB_URL');
  const ids = Array.from(new Set(externalIds.filter(Boolean).map(String)));
  if (!dbUrl || !ids.length) return map;
  // deno-lint-ignore no-explicit-any
  let sql: any = null;
  try {
    const postgres = (await import('https://esm.sh/postgres@3.4.5')).default;
    // Supabase pooler: transaction mode (no prepared statements) over TLS.
    sql = postgres(dbUrl, { prepare: false, ssl: 'require', max: 1, idle_timeout: 5, connect_timeout: 10 });
    const rows = await sql`
      select external_order_id, platform, carrier, service, weight_kg, cost, currency
      from pulse_order_shipping
      where external_order_id = any(${ids})
    `;
    for (const r of rows) {
      const row: FulfildRow = {
        carrier:   r.carrier ?? null,
        service:   r.service ?? null,
        weight_kg: r.weight_kg != null ? Number(r.weight_kg) : null,
        cost:      r.cost != null ? Number(r.cost) : null,
        currency:  r.currency ?? null,
      };
      const platform = String(r.platform || '').toLowerCase();
      map.set(`${platform}:${r.external_order_id}`, row);
      // Platform-agnostic fallback key (first writer wins).
      if (!map.has(String(r.external_order_id))) map.set(String(r.external_order_id), row);
    }
  } catch (e) {
    console.error('[ecommerce-sync] fulfild read error:', e instanceof Error ? e.message : String(e));
  } finally {
    if (sql) { try { await sql.end({ timeout: 5 }); } catch { /* ignore */ } }
  }
  return map;
}

// Exclusive end date helper for range queries (YYYY-MM-DD -> next day).
function nextDayYmd(ymd: string): string {
  const p = ymd.split('-');
  const d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]));
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

// ── Shipping destination + weight + service extraction (for UPS rating) ───────
// Captures the same inputs UPS uses to price a label so the quote is accurate.
function shopifyShippingFields(o: Record<string, unknown>) {
  const sa    = (o.shipping_address ?? {}) as Record<string, unknown>;
  const lines = (o.shipping_lines ?? []) as Array<Record<string, unknown>>;
  const svcTitle = (lines[0]?.title as string) || (lines[0]?.code as string) || '';
  const company  = (sa.company as string) || null;
  return {
    ship_name:          (sa.name as string) ?? null,
    ship_company:       company,
    ship_address1:      (sa.address1 as string) ?? null,
    ship_address2:      (sa.address2 as string) ?? null,
    ship_city:          (sa.city as string) ?? null,
    ship_state:         (sa.province_code as string) ?? null,
    ship_postal:        (sa.zip as string) ?? null,
    ship_country:       (sa.country_code as string) ?? null,
    ship_residential:   !company,
    ship_service_name:  svcTitle || null,
    ship_service_code:  svcTitle ? resolveUpsServiceCode(svcTitle) : null,
    total_weight_grams: o.total_weight != null ? Number(o.total_weight) : null,
  };
}
function wooShippingFields(o: Record<string, unknown>) {
  const sh    = (o.shipping ?? {}) as Record<string, unknown>;
  const lines = (o.shipping_lines ?? []) as Array<Record<string, unknown>>;
  const svcTitle = (lines[0]?.method_title as string) || '';
  const company  = (sh.company as string) || null;
  const name     = [sh.first_name, sh.last_name].filter(Boolean).join(' ') || null;
  return {
    ship_name:          name,
    ship_company:       company,
    ship_address1:      (sh.address_1 as string) ?? null,
    ship_address2:      (sh.address_2 as string) ?? null,
    ship_city:          (sh.city as string) ?? null,
    ship_state:         (sh.state as string) ?? null,
    ship_postal:        (sh.postcode as string) ?? null,
    ship_country:       (sh.country as string) ?? null,
    ship_residential:   !company,
    ship_service_name:  svcTitle || null,
    ship_service_code:  svcTitle ? resolveUpsServiceCode(svcTitle) : null,
    total_weight_grams: null, // Woo orders don't expose an aggregate weight
  };
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

// Resolves an Admin API access token for a store.
//  • Legacy custom apps: api_key holds a permanent `shpat_...` token (no secret).
//  • Dev Dashboard apps (2026+): api_key = Client ID, api_secret = Client secret.
//    Shopify no longer exposes a static token, so we mint a short-lived one via
//    the client-credentials grant (valid ~24h; we fetch fresh per operation).
async function resolveShopifyToken(store: Record<string, unknown>): Promise<string> {
  const key    = (store.api_key    as string) || '';
  const secret = (store.api_secret as string) || '';
  if (key.startsWith('shpat_') && !secret) return key;
  if (key && secret) {
    const host = shopifyHost(store.store_url as string);
    const res = await fetch(`https://${host}/admin/oauth/access_token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ grant_type: 'client_credentials', client_id: key, client_secret: secret }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.access_token) {
      throw new Error('Shopify token exchange failed: ' + (data.error_description || data.error || ('HTTP ' + res.status)));
    }
    return data.access_token as string;
  }
  // Fallback: treat whatever is in api_key as the token.
  return key;
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
  // When shop prices are tax-inclusive, line_total includes VAT and must be
  // stripped to get ex-VAT net_sales; otherwise line_total is already ex-VAT.
  const taxesIncluded = o.taxes_included === true;

  // Products — net of line-level discount_allocations (actual allocated discount)
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    const qty   = Number(li.quantity ?? 1);
    const price = Number(li.price ?? 0);
    let discount = 0;
    for (const d of ((li.discount_allocations ?? []) as Array<Record<string, unknown>>)) {
      discount += Number(d.amount ?? 0);
    }
    const grossRaw = qty * price;             // pre-discount, store's tax mode
    const lineTotal = grossRaw - discount;
    let taxAmount = 0;
    for (const t of ((li.tax_lines ?? []) as Array<Record<string, unknown>>)) {
      taxAmount += Number(t.price ?? 0);
    }
    const netSales = taxesIncluded ? (lineTotal - taxAmount) : lineTotal;
    // Strip VAT from gross/discount using the same ex-VAT factor as net_sales so
    // gross_ex_vat - discount_ex_vat === net_sales for tax-inclusive stores too.
    const factor = taxesIncluded ? (lineTotal > 0 ? netSales / lineTotal : 1) : 1;
    const grossExVat = grossRaw * factor;
    const discountExVat = discount * factor;
    const isGiftCard = (li.product_type as string)?.toLowerCase() === 'gift cards' || li.gift_card === true;
    items.push({
      sku:          li.sku ?? null,
      product_name: (li.title as string) ?? 'Unknown',
      quantity:     qty,
      unit_price:   price,
      line_total:   lineTotal,
      tax_amount:   taxAmount,
      net_sales:    isGiftCard ? null : netSales,
      gross_ex_vat: isGiftCard ? null : grossExVat,
      discount_ex_vat: isGiftCard ? null : Math.max(0, discountExVat),
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

// Fetches the full Shopify product catalogue, flattened to one row per variant.
async function shopifyFetchProducts(storeUrl: string, token: string) {
  const host = shopifyHost(storeUrl);
  let url: string | null = `https://${host}/admin/api/${SHOPIFY_API_VER}/products.json?limit=250`;
  const out: Array<{ sku: string | null; product_name: string; external_id: string; rrp_ex_vat: number | null; store_status: string | null }> = [];
  while (url) {
    const res = await fetch(url, { headers: shopifyHeaders(token) });
    if (res.status !== 200) {
      const text = await res.text().catch(() => '');
      throw new Error(`Shopify products ${res.status}: ${text.slice(0, 200)}`);
    }
    const data = await res.json();
    for (const p of ((data?.products ?? []) as Array<Record<string, unknown>>)) {
      const title    = (p.title as string) ?? 'Unknown';
      // Shopify product status: 'active' | 'draft' | 'archived'. Treat anything
      // other than active (or unpublished to a sales channel) as not-for-sale.
      const status   = (p.status as string) || null;
      const storeStatus = (status && status !== 'active') ? status : (p.published_at == null ? 'draft' : status);
      const variants = (p.variants ?? []) as Array<Record<string, unknown>>;
      if (variants.length) {
        for (const v of variants) {
          const vTitle = (v.title && v.title !== 'Default Title') ? ` — ${v.title}` : '';
          // Regular price = struck-through compare_at_price when the item is on sale, else price.
          const priceNum = Number(v.price ?? 0);
          const compare  = v.compare_at_price != null ? Number(v.compare_at_price) : null;
          const regular  = (compare != null && compare > priceNum) ? compare : priceNum;
          out.push({ sku: (v.sku as string) || null, product_name: `${title}${vTitle}`, external_id: String(v.id ?? p.id), rrp_ex_vat: rrpExVat(regular), store_status: storeStatus });
        }
      } else {
        out.push({ sku: null, product_name: title, external_id: String(p.id), rrp_ex_vat: null, store_status: storeStatus });
      }
    }
    url = shopifyNextLink(res.headers.get('Link'));
  }
  return out;
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

// Woo stores weight on the product/variation (not the order line), in the store's
// configured unit. We fetch weights during sync and sum qty*weight per order so
// UPS rates on the real parcel weight instead of a fallback.
function toGrams(value: number, unit: string): number {
  switch ((unit || 'kg').toLowerCase()) {
    case 'g':   return value;
    case 'kg':  return value * 1000;
    case 'lbs':
    case 'lb':  return value * 453.59237;
    case 'oz':  return value * 28.349523;
    default:    return value * 1000;
  }
}

async function wooWeightUnit(storeUrl: string, key: string, secret: string): Promise<string> {
  try {
    const res = await fetch(`${wooHost(storeUrl)}/wp-json/wc/v3/settings/products/woocommerce_weight_unit`, { headers: wooHeaders(key, secret) });
    if (!res.ok) return 'kg';
    const d = await res.json().catch(() => ({}));
    return (d?.value as string) || 'kg';
  } catch { return 'kg'; }
}

// Weights for a set of simple/parent product ids (batched via include=).
async function wooProductWeights(storeUrl: string, key: string, secret: string, ids: number[]): Promise<Map<number, number>> {
  const map = new Map<number, number>();
  const uniq = Array.from(new Set(ids.filter((n) => n > 0)));
  const CHUNK = 50;
  for (let i = 0; i < uniq.length; i += CHUNK) {
    const chunk = uniq.slice(i, i + CHUNK);
    const url = `${wooHost(storeUrl)}/wp-json/wc/v3/products?include=${chunk.join(',')}&per_page=${chunk.length}&_fields=id,weight`;
    const res = await fetch(url, { headers: wooHeaders(key, secret) });
    if (!res.ok) continue;
    const batch = await res.json().catch(() => []) as Array<Record<string, unknown>>;
    for (const p of batch) {
      const w = parseFloat(String(p.weight ?? ''));
      if (!isNaN(w) && w > 0) map.set(Number(p.id), w);
    }
  }
  return map;
}

// Weights for specific (product_id, variation_id) pairs. Variation weight can be
// set on the variation or inherited from the parent (empty here).
async function wooVariationWeights(storeUrl: string, key: string, secret: string, pairs: Array<[number, number]>): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  const seen = new Set<string>();
  for (const [pid, vid] of pairs) {
    if (!(pid > 0 && vid > 0)) continue;
    const k = `${pid}:${vid}`;
    if (seen.has(k)) continue;
    seen.add(k);
    const url = `${wooHost(storeUrl)}/wp-json/wc/v3/products/${pid}/variations/${vid}?_fields=id,weight`;
    const res = await fetch(url, { headers: wooHeaders(key, secret) });
    if (!res.ok) continue;
    const v = await res.json().catch(() => ({})) as Record<string, unknown>;
    const w = parseFloat(String(v.weight ?? ''));
    if (!isNaN(w) && w > 0) map.set(k, w);
  }
  return map;
}

interface WooWeightCtx { unit: string; prodW: Map<number, number>; varW: Map<string, number> }

// Sums qty * (variation|product) weight for an order, converted to grams. Returns
// null when no line item has a usable weight (so the fallback weight applies).
function wooOrderWeightGrams(o: Record<string, unknown>, ctx: WooWeightCtx): number | null {
  let total = 0;
  let any = false;
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    const qty = Number(li.quantity ?? 0);
    const pid = Number(li.product_id ?? 0);
    const vid = Number(li.variation_id ?? 0);
    let w = 0;
    if (vid > 0 && ctx.varW.has(`${pid}:${vid}`)) w = ctx.varW.get(`${pid}:${vid}`)!;
    else if (ctx.prodW.has(pid)) w = ctx.prodW.get(pid)!;
    if (w > 0 && qty > 0) { total += toGrams(w, ctx.unit) * qty; any = true; }
  }
  return any ? Math.round(total) : null;
}

function wooItemsForOrder(o: Record<string, unknown>) {
  const items: Array<Record<string, unknown>> = [];
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    const qty   = Number(li.quantity ?? 1);
    // Woo line `total` is already net of discount and EXCLUSIVE of tax;
    // `subtotal` is the pre-discount value (also ex-tax). So the ex-VAT discount
    // is subtotal - total, and net_sales = total.
    const total = Number(li.total ?? 0);
    const subtotal = li.subtotal != null ? Number(li.subtotal) : total;
    const taxAmount = Number(li.total_tax ?? 0);
    items.push({
      sku:          li.sku ?? null,
      product_name: (li.name as string) ?? 'Unknown',
      quantity:     qty,
      unit_price:   qty > 0 ? total / qty : total,
      line_total:   total,
      tax_amount:   taxAmount,
      net_sales:    total,
      gross_ex_vat: subtotal,
      discount_ex_vat: Math.max(0, subtotal - total),
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

// Fetches the full WooCommerce product catalogue.
async function wooFetchProducts(storeUrl: string, key: string, secret: string) {
  const out: Array<{ sku: string | null; product_name: string; external_id: string; rrp_ex_vat: number | null; store_status: string | null }> = [];
  let page = 1;
  while (true) {
    const url = `${wooHost(storeUrl)}/wp-json/wc/v3/products?per_page=100&page=${page}&status=publish`;
    const res = await fetch(url, { headers: wooHeaders(key, secret) });
    if (res.status !== 200) {
      const text = await res.text().catch(() => '');
      throw new Error(`WooCommerce products ${res.status}: ${text.slice(0, 200)}`);
    }
    const batch = await res.json() as Array<Record<string, unknown>>;
    for (const p of batch) {
      const regular = Number((p.regular_price as string) || (p.price as string) || 0);
      // Only published products are fetched; catalog_visibility 'hidden' means not shown for sale.
      const storeStatus = (p.catalog_visibility === 'hidden') ? 'hidden' : ((p.status as string) || 'publish');
      out.push({ sku: (p.sku as string) || null, product_name: (p.name as string) ?? 'Unknown', external_id: String(p.id), rrp_ex_vat: rrpExVat(regular), store_status: storeStatus });
    }
    const totalPages = parseInt(res.headers.get('X-WP-TotalPages') || '1', 10);
    if (page >= totalPages || batch.length === 0) break;
    page++;
  }
  return out;
}

// ── Common: upsert orders + items into Pulse DB ───────────────────────────────
// Itemised coupon/promo detail for an order: [{ code, type, amount_ex_vat }].
// Shopify: discount_applications carry the code/title + type; the actual money is
// in each line's discount_allocations (indexed back to the application). We sum
// allocations per application and VAT-strip when the store prices tax-inclusive.
function shopifyDiscounts(o: Record<string, unknown>): Array<Record<string, unknown>> {
  const apps = (o.discount_applications ?? []) as Array<Record<string, unknown>>;
  if (!apps.length) return [];
  const taxesIncluded = o.taxes_included === true;
  const amounts = new Array(apps.length).fill(0);
  for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
    for (const d of ((li.discount_allocations ?? []) as Array<Record<string, unknown>>)) {
      const idx = Number(d.discount_application_index ?? -1);
      if (idx >= 0 && idx < amounts.length) amounts[idx] += Number(d.amount ?? 0);
    }
  }
  // Approximate ex-VAT stripping using the order's overall net ratio.
  const subtotal = Number(o.subtotal_price ?? o.total_line_items_price ?? 0);
  const totalTax = Number(o.total_tax ?? 0);
  const factor = taxesIncluded && subtotal > 0 ? Math.max(0, (subtotal - totalTax) / subtotal) : 1;
  const out: Array<Record<string, unknown>> = [];
  apps.forEach(function (a, i) {
    const amt = amounts[i] * factor;
    if (amt > 0.005) {
      out.push({
        code: (a.code as string) || (a.title as string) || 'discount',
        type: (a.value_type as string) || (a.type as string) || 'discount',
        amount_ex_vat: Math.round(amt * 100) / 100,
      });
    }
  });
  return out;
}

// Woo: coupon_lines carry code + discount (ex-tax).
function wooDiscounts(o: Record<string, unknown>): Array<Record<string, unknown>> {
  const lines = (o.coupon_lines ?? []) as Array<Record<string, unknown>>;
  const out: Array<Record<string, unknown>> = [];
  for (const c of lines) {
    const amt = Number(c.discount ?? 0);
    if (amt > 0.005) {
      out.push({
        code: (c.code as string) || 'coupon',
        type: 'coupon',
        amount_ex_vat: Math.round(amt * 100) / 100,
      });
    }
  }
  return out;
}

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
    taxes_included:  o.taxes_included === true,
    discounts:       shopifyDiscounts(o),
    ...shopifyShippingFields(o),
    raw_data:       { source: 'shopify', has_gift_card_payment: hasGiftCard, order_id: o.id },
  };
}

function wooNormaliseOrder(storeId: string, o: Record<string, unknown>, weightCtx?: WooWeightCtx) {
  const billing = (o.billing ?? {}) as Record<string, unknown>;
  const shipFields = wooShippingFields(o);
  // Woo carries no aggregate order weight; derive it from product weights.
  if (weightCtx) shipFields.total_weight_grams = wooOrderWeightGrams(o, weightCtx);
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
    taxes_included:  o.prices_include_tax === true,
    discounts:       wooDiscounts(o),
    ...shipFields,
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
    // Defence-in-depth: also require status=active so terminated users
    // can't call this with a stale session.
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role, status')
      .eq('auth_user_id', user.id)
      .single();
    if (!appUser || appUser.status !== 'active') return err('Forbidden — finance roles only', 403);

    const { data: roleRow } = await adminClient
      .from('roles')
      .select('has_finance_access, is_pulse_admin')
      .eq('key', appUser.role)
      .maybeSingle();

    const userId = appUser.id as string;
    const body   = await req.json() as Record<string, unknown>;
    const action = body.action as string;

    // Finance features (Xero push) and 3PL store connect/sync are both allowed
    // for finance roles or Pulse admins. The read-only shipping cost report is
    // available to any active staff member (already verified above).
    const READ_ONLY_ACTIONS = ['shipping_cost_report'];
    if (!READ_ONLY_ACTIONS.includes(action)
        && !roleRow?.has_finance_access && !roleRow?.is_pulse_admin) {
      return err('Forbidden — finance or admin roles only', 403);
    }

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
        three_pl_client_id:   (body.three_pl_client_id as string) || null,
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
      setIf('three_pl_client_id', 'three_pl_client_id');
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
        try {
          var shopToken = await resolveShopifyToken(store);
        } catch (te) {
          result = { ok: false, error: te instanceof Error ? te.message : String(te) };
          await updateStoreStatus(adminClient, id, { connection_status: 'error', error_message: result.error, updated_at: new Date().toISOString() });
          return err(result.error || 'Token error', 400);
        }
        result = await shopifyTestConnection(store.store_url as string, shopToken);
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
          var shopToken = await resolveShopifyToken(store);
          rawOrders  = await shopifyFetchOrders(store.store_url as string, shopToken, since);
          normalised = rawOrders.map((o) => ({
            order: shopifyNormaliseOrder(id, o),
            items: shopifyItemsForOrder(o),
          }));
        } else if (store.platform === 'woocommerce') {
          const url = store.store_url as string, k = store.api_key as string, sec = store.api_secret as string;
          rawOrders  = await wooFetchOrders(url, k, sec, since);
          // Resolve real parcel weights: gather product/variation ids across all
          // orders, fetch their weights once, then sum per order.
          const prodIds: number[] = [];
          const varPairs: Array<[number, number]> = [];
          for (const o of rawOrders) {
            for (const li of ((o.line_items ?? []) as Array<Record<string, unknown>>)) {
              const pid = Number(li.product_id ?? 0);
              const vid = Number(li.variation_id ?? 0);
              if (pid > 0) prodIds.push(pid);
              if (pid > 0 && vid > 0) varPairs.push([pid, vid]);
            }
          }
          const unit  = await wooWeightUnit(url, k, sec);
          const prodW = await wooProductWeights(url, k, sec, prodIds);
          const varW  = await wooVariationWeights(url, k, sec, varPairs);
          const weightCtx: WooWeightCtx = { unit, prodW, varW };
          normalised = rawOrders.map((o) => ({
            order: wooNormaliseOrder(id, o, weightCtx),
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

    // ── store_sync_products ─────────────────────────────────────────────────
    // Pulls the full product catalogue for a 3PL client's store into
    // three_pl_client_products. Never overwrites purchase_price (our price).
    if (action === 'store_sync_products') {
      const id = (body.id as string) || '';
      if (!id) return err('Missing store id', 400);
      const store = await loadStore(adminClient, id);
      if (!store) return err('Store not found', 404);
      const clientId = (store.three_pl_client_id as string | null) || null;
      if (!clientId) return err('Store is not linked to a 3PL client', 400);

      try {
        let products: Array<{ sku: string | null; product_name: string; external_id: string; rrp_ex_vat: number | null; store_status: string | null }>;
        if (store.platform === 'shopify') {
          var shopToken = await resolveShopifyToken(store);
          products = await shopifyFetchProducts(store.store_url as string, shopToken);
        } else if (store.platform === 'woocommerce') {
          products = await wooFetchProducts(store.store_url as string, store.api_key as string, store.api_secret as string);
        } else {
          return err(`Unsupported platform: ${store.platform}`, 400);
        }

        // Existing catalogue for this client — preserve purchase_price + match rows.
        const { data: existing } = await adminClient
          .from('three_pl_client_products')
          .select('id, sku, product_name')
          .eq('three_pl_client_id', clientId);
        const bySku  = new Map<string, string>();
        const byName = new Map<string, string>();
        for (const r of (existing ?? [])) {
          if (r.sku) bySku.set(String(r.sku), r.id as string);
          byName.set(String(r.product_name).toLowerCase(), r.id as string);
        }

        const now = new Date().toISOString();
        const seen = new Set<string>();
        const toInsert: Array<Record<string, unknown>> = [];
        let updated = 0;
        for (const p of products) {
          const key = p.sku ? `sku:${p.sku}` : `name:${(p.product_name || '').toLowerCase()}`;
          if (seen.has(key)) continue;
          seen.add(key);
          const existingId = p.sku
            ? bySku.get(String(p.sku))
            : byName.get(String(p.product_name || '').toLowerCase());
          // A product is "for sale" (listed) when its store status is active/publish/null.
          const listed = p.store_status == null || p.store_status === 'active' || p.store_status === 'publish';
          if (existingId) {
            // Refresh the store status, but preserve the user's manual `included` choice.
            await adminClient.from('three_pl_client_products').update({
              product_name: p.product_name,
              external_id:  p.external_id,
              rrp_ex_vat:   p.rrp_ex_vat,
              store_status: p.store_status,
              active:       true,
              last_seen_at: now,
              updated_at:   now,
            }).eq('id', existingId);
            updated++;
          } else {
            // First time we've seen it: default `included` from the store status.
            toInsert.push({
              three_pl_client_id: clientId,
              sku:                p.sku,
              product_name:       p.product_name,
              external_id:        p.external_id,
              rrp_ex_vat:         p.rrp_ex_vat,
              store_status:       p.store_status,
              included:           listed,
              active:             true,
              last_seen_at:       now,
            });
          }
        }
        if (toInsert.length) {
          const { error: insErr } = await adminClient.from('three_pl_client_products').insert(toInsert);
          if (insErr) throw new Error(`product insert: ${insErr.message}`);
        }
        return json({ ok: true, fetched: products.length, inserted: toInsert.length, updated });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error('[ecommerce-sync] product sync error:', msg);
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

    // ── ups_test ────────────────────────────────────────────────────────────
    // Verifies UPS OAuth credentials by fetching a client-credentials token.
    if (action === 'ups_test') {
      const t = await getUpsToken();
      return t.ok ? json({ ok: true }) : err(t.error || 'UPS token failed', 400);
    }

    // ── fulfild_test ────────────────────────────────────────────────────────
    // Verifies the read-only pulse_order_shipping feed is reachable. Optionally
    // pass { external_ids: string[] } to fetch specific orders.
    if (action === 'fulfild_test') {
      const dbUrl = Deno.env.get('FULFILD_DB_URL');
      if (!dbUrl) return err('FULFILD_DB_URL not set', 400);
      const wanted = Array.isArray(body.external_ids) ? (body.external_ids as unknown[]).map(String) : [];
      // deno-lint-ignore no-explicit-any
      let sql: any = null;
      try {
        const postgres = (await import('https://esm.sh/postgres@3.4.5')).default;
        sql = postgres(dbUrl, { prepare: false, ssl: 'require', max: 1, idle_timeout: 5, connect_timeout: 10 });
        const countRows = await sql`select count(*)::int as n from pulse_order_shipping`;
        const sample = wanted.length
          ? await sql`select external_order_id, platform, carrier, service, weight_kg, cost, currency from pulse_order_shipping where external_order_id = any(${wanted})`
          : await sql`select external_order_id, platform, carrier, service, weight_kg, cost, currency from pulse_order_shipping order by created_at desc nulls last limit 5`;
        return json({ ok: true, total_rows: countRows[0]?.n ?? 0, sample });
      } catch (e) {
        return err(`Fulfild connection failed: ${e instanceof Error ? e.message : String(e)}`, 400);
      } finally {
        if (sql) { try { await sql.end({ timeout: 5 }); } catch { /* ignore */ } }
      }
    }

    // ── shipping_cost_report ────────────────────────────────────────────────
    // For a 3PL client + date range, lists every order that has a shipping line,
    // detects the carrier from the shipping-method title (configurable keyword
    // rules), and works out the cost: DPD = flat Ireland rate from settings;
    // UPS = live negotiated rate from the UPS Rating API (cached on the order).
    if (action === 'shipping_cost_report') {
      const clientId = (body.three_pl_client_id as string) || '';
      const start    = (body.start as string) || '';
      const end      = (body.end as string) || '';
      const refresh  = body.refresh === true;
      if (!clientId || !start || !end) return err('Missing client or date range', 400);

      // Config
      const { data: cfgRow } = await adminClient
        .from('app_settings').select('value').eq('key', 'shipping_config').maybeSingle();
      // app_settings.value is jsonb: supabase-js returns it already parsed. Tolerate
      // the legacy double-encoded (string) form too.
      let cfg: Record<string, unknown> = {};
      try {
        const rawCfg = cfgRow?.value;
        cfg = (typeof rawCfg === 'string' ? JSON.parse(rawCfg) : (rawCfg || {})) as Record<string, unknown>;
      } catch { cfg = {}; }
      const dpdRate = cfg.dpd_ie_flat_rate != null ? Number(cfg.dpd_ie_flat_rate) : null;
      const rules   = Array.isArray(cfg.carrier_rules) ? cfg.carrier_rules as Array<{ keyword?: string; carrier?: string }> : [];

      // Stores for this client
      const { data: stores } = await adminClient
        .from('ecommerce_stores').select('id, platform').eq('three_pl_client_id', clientId);
      const storeIds = (stores ?? []).map((s: { id: string }) => s.id);
      const storePlatform = new Map<string, string>();
      for (const s of (stores ?? [])) storePlatform.set(s.id as string, ((s.platform as string) || '').toLowerCase());
      if (!storeIds.length) {
        return json({ rows: [], totals: {}, grand_total: 0, currency: 'EUR', dpd_rate: dpdRate, note: 'No stores linked to this client.' });
      }

      // Orders in range
      const { data: ordersData } = await adminClient
        .from('ecommerce_orders')
        .select('id, store_id, external_id, order_number, customer_name, ordered_at, currency, ship_name, ship_company, ship_address1, ship_address2, ship_country, ship_postal, ship_city, ship_state, ship_residential, ship_service_code, ship_service_name, total_weight_grams, ups_cost, ups_negotiated')
        .in('store_id', storeIds)
        .gte('ordered_at', `${start}T00:00:00Z`)
        .lt('ordered_at',  `${nextDayYmd(end)}T00:00:00Z`)
        .order('ordered_at', { ascending: true })
        .limit(100000);
      const orders = (ordersData ?? []) as Array<Record<string, unknown>>;

      // Shipping line items for those orders
      const orderIds = orders.map((o) => o.id as string);
      const shipByOrder = new Map<string, Array<Record<string, unknown>>>();
      if (orderIds.length) {
        const { data: shipItems } = await adminClient
          .from('ecommerce_order_items')
          .select('order_id, product_name, line_total')
          .eq('item_type', 'shipping')
          .in('order_id', orderIds);
        for (const it of (shipItems ?? [])) {
          const arr = shipByOrder.get(it.order_id as string) ?? [];
          arr.push(it);
          shipByOrder.set(it.order_id as string, arr);
        }
      }

      const detect = (title: string): string => {
        const t = (title || '').toLowerCase();
        for (const r of rules) {
          const kw = (r.keyword || '').toLowerCase();
          if (kw && t.includes(kw)) return (r.carrier || '').toLowerCase() || 'unmatched';
        }
        return 'unmatched';
      };

      // Fulfild is the primary cost source: pull actual booked cost for these
      // orders in one batch (no-op when FULFILD_DB_URL is unset).
      const fulfild = await fetchFulfildCosts(orders.map((o) => String(o.external_id)));

      let upsToken: string | null = null;
      let upsTokenErr: string | null = null;
      const rows: Array<Record<string, unknown>> = [];
      const totals: Record<string, { count: number; cost: number }> = {};
      let grand = 0;
      let currency = 'EUR';

      for (const o of orders) {
        const ships = shipByOrder.get(o.id as string) ?? [];
        if (!ships.length) continue; // no shipping line -> cannot classify
        const title = ships.map((s) => s.product_name).filter(Boolean).join(' / ');
        const customerPaid = ships.reduce((s, x) => s + Number(x.line_total ?? 0), 0);
        const platform = storePlatform.get(o.store_id as string) || '';
        const fRow = fulfild.get(`${platform}:${o.external_id}`) || fulfild.get(String(o.external_id));

        let carrier = detect(title);
        let cost: number | null = null;
        let note: string | null = null;
        let source: string | null = null;
        let service: string | null = (o.ship_service_name as string) || null;
        // For UPS quotes: whether the rate returned was account-negotiated
        // (discount applied) or UPS published/list. null = not a UPS quote / unknown.
        let upsNegotiated: boolean | null = null;
        // For UPS quotes: the weight used and where it came from — Fulfild's real
        // booked label weight ('fulfild'), the WooCommerce snapshot ('store'), or
        // the default ('default'). null = not a fresh UPS quote.
        let upsWeightKg: number | null = null;
        let upsWeightSource: string | null = null;
        // For UPS quotes: where the service code came from — Fulfild's booked
        // service ('fulfild'), the store shipping-method mapping ('store'), or
        // the default service ('default'). null = not a fresh UPS quote.
        let upsServiceSource: string | null = null;

        // Fulfild is authoritative for *which* carrier/service was actually
        // used to book the label — trust it over title-keyword matching.
        if (fRow) {
          const fc = normalizeCarrier(fRow.carrier);
          if (fc && fc !== 'unmatched') carrier = fc;
          if (fRow.service) service = fRow.service;
        }

        // Fulfild's persisted cost (Shiptheory booking rate) is only meaningful
        // when it's a priced (> 0) booked rate. In the current setup it resolves
        // from the unpriced service catalogue (0.00) and does NOT reflect our
        // negotiated UPS discount, so treat 0/null as "not priced" and fall back
        // to the DPD flat rate / live negotiated UPS quote instead.
        if (fRow && fRow.cost != null && fRow.cost > 0) {
          // Actual priced booked cost from Fulfild — authoritative for any carrier.
          cost = fRow.cost;
          currency = fRow.currency || currency;
          source = 'fulfild';
          await adminClient.from('ecommerce_orders')
            .update({ carrier_cost: cost, carrier_cost_source: 'fulfild', detected_carrier: carrier }).eq('id', o.id as string);
        } else if (carrier === 'dpd') {
          cost = dpdRate;
          source = 'dpd_flat';
          if (dpdRate == null) note = 'DPD flat rate not set in settings';
        } else if (carrier === 'ups') {
          source = 'ups_quote';
          if (o.ups_cost != null && !refresh) {
            cost = Number(o.ups_cost);
            upsNegotiated = o.ups_negotiated == null ? null : Boolean(o.ups_negotiated);
          } else if (upsTokenErr) {
            note = upsTokenErr;
          } else {
            if (!upsToken) {
              const t = await getUpsToken();
              if (t.ok) upsToken = t.token!;
              else { upsTokenErr = t.error || 'UPS token failed'; }
            }
            if (upsTokenErr) {
              note = upsTokenErr;
            } else if (!o.ship_country) {
              note = 'No destination address on order (re-sync store to backfill)';
            } else {
              // Prefer the real booked parcel weight from Fulfild; fall back to the
              // WooCommerce snapshot, then the default. Woo product-weight edits no
              // longer need to propagate to already-shipped orders.
              const fKg   = fRow && fRow.weight_kg != null && Number(fRow.weight_kg) > 0 ? Number(fRow.weight_kg) : null;
              const grams = o.total_weight_grams != null ? Number(o.total_weight_grams) : 0;
              const wKg   = fKg != null ? fKg
                          : (grams > 0 ? Math.round((grams / 1000) * 100) / 100 : UPS_DEFAULT_WEIGHT_KG);
              upsWeightKg     = Math.round(Math.max(0.1, wKg) * 100) / 100;
              upsWeightSource = fKg != null ? 'fulfild' : (grams > 0 ? 'store' : 'default');
              const dest: UpsAddress = {
                name: o.ship_name as string, company: o.ship_company as string,
                address1: o.ship_address1 as string, address2: o.ship_address2 as string,
                city: o.ship_city as string, state: o.ship_state as string,
                postal: o.ship_postal as string, country: o.ship_country as string,
                residential: o.ship_residential as boolean,
              };
              // Prefer the actual UPS service booked in Fulfild; fall back to the
              // service resolved from the store shipping-method title, then default.
              // "UPS Zone 4"-style store labels are merchant zones, not real UPS
              // services, so Fulfild's booked service is far more reliable.
              let svcCode: string;
              if (fRow && fRow.service && normalizeCarrier(fRow.carrier) === 'ups') {
                svcCode = resolveUpsServiceCode(fRow.service);
                upsServiceSource = 'fulfild';
              } else if (o.ship_service_code) {
                svcCode = o.ship_service_code as string;
                upsServiceSource = 'store';
              } else {
                svcCode = UPS_DEFAULT_SERVICE;
                upsServiceSource = 'default';
              }
              const r = await upsRate(upsToken!, dest, Math.max(0.1, wKg), svcCode);
              if (r.ok) {
                cost = r.cost!;
                currency = r.currency || currency;
                upsNegotiated = r.negotiated == null ? null : Boolean(r.negotiated);
                await adminClient.from('ecommerce_orders')
                  .update({ ups_cost: cost, carrier_cost: cost, carrier_cost_source: 'ups_quote', detected_carrier: 'ups', ups_negotiated: upsNegotiated }).eq('id', o.id as string);
              } else {
                note = r.error || 'UPS rate failed';
              }
            }
          }
        }

        if (!totals[carrier]) totals[carrier] = { count: 0, cost: 0 };
        totals[carrier].count++;
        if (cost != null) { totals[carrier].cost += cost; grand += cost; }

        rows.push({
          order_number:   o.order_number,
          ordered_at:     o.ordered_at,
          customer_name:  o.customer_name,
          carrier,
          shipping_method: title,
          service,
          destination:    [o.ship_city, o.ship_country].filter(Boolean).join(', ') || null,
          customer_paid:  customerPaid,
          cost,
          cost_source:    source,
          ups_negotiated: source === 'ups_quote' ? upsNegotiated : null,
          weight_kg:      source === 'ups_quote' ? upsWeightKg : null,
          weight_source:  source === 'ups_quote' ? upsWeightSource : null,
          service_source: source === 'ups_quote' ? upsServiceSource : null,
          note,
        });
      }

      return json({ rows, totals, grand_total: grand, currency, dpd_rate: dpdRate });
    }

    return err('Unknown action: ' + action, 400);

  } catch (e) {
    console.error('[ecommerce-sync] unhandled error:', e);
    return err(String(e), 500);
  }
});
