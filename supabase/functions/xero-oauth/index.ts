// xero-oauth — Supabase Edge Function
// Handles all Xero OAuth and API proxy actions server-side so the browser
// never sees client_secret, access_token, or refresh_token.
//
// Deploy: supabase functions deploy xero-oauth
// Uses SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from the runtime env.
// xero_client_id / xero_client_secret are stored in app_settings table.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const CREDS_ROLES   = ['managing_director', 'operations_director', 'financial_controller'];
const FINANCE_ROLES = [...CREDS_ROLES, 'business_analyst', 'ecommerce_manager'];

const XERO_TOKEN_URL  = 'https://identity.xero.com/connect/token';
const XERO_REVOKE_URL = 'https://identity.xero.com/connect/revocation';
const XERO_AUTH_URL   = 'https://login.xero.com/identity/connect/authorize';
const XERO_API        = 'https://api.xero.com';

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function err(message: string, status = 400): Response {
  return json({ error: message }, status);
}

// ── helpers ───────────────────────────────────────────────────────────────────

async function getXeroCreds(adminClient: ReturnType<typeof createClient>) {
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

function basicAuth(clientId: string, clientSecret: string) {
  return 'Basic ' + btoa(`${clientId}:${clientSecret}`);
}

async function exchangeToken(
  grantType: string,
  params: Record<string, string>,
  clientId: string,
  clientSecret: string,
) {
  const body = new URLSearchParams({ grant_type: grantType, ...params });
  const url = XERO_TOKEN_URL;
  console.log('[xero-oauth] request: POST', url);
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: basicAuth(clientId, clientSecret),
    },
    body: body.toString(),
  });
  const responseBody = await res.json();
  console.log('[xero-oauth] response:', res.status, JSON.stringify(responseBody));
  return { status: res.status, data: responseBody };
}

async function getXeroTenants(accessToken: string) {
  const url = `${XERO_API}/connections`;
  console.log('[xero-oauth] request: GET', url);
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const data = await res.json();
  console.log('[xero-oauth] response:', res.status, JSON.stringify(data));
  return { status: res.status, data };
}

async function refreshConnectionIfNeeded(
  adminClient: ReturnType<typeof createClient>,
  clientId: string,
  clientSecret: string,
): Promise<{ ok: boolean; accessToken?: string; tenantId?: string; error?: string }> {
  // Read current token state
  const { data: conn } = await adminClient
    .from('xero_connection')
    .select('id, access_token, refresh_token, token_expiry, tenant_id')
    .eq('is_active', true)
    .maybeSingle();

  if (!conn) return { ok: false, error: 'No active Xero connection' };

  const expiry = new Date(conn.token_expiry).getTime();
  const fiveMin = 5 * 60 * 1000;
  if (expiry > Date.now() + fiveMin) {
    // Token still fresh — no refresh needed
    return { ok: true, accessToken: conn.access_token, tenantId: conn.tenant_id };
  }

  // Exchange refresh token with Xero
  const { status, data } = await exchangeToken('refresh_token', { refresh_token: conn.refresh_token }, clientId, clientSecret);

  if (status !== 200 || data.error === 'invalid_grant' || data.error) {
    // Revoked or invalid — deactivate the connection so the UI shows reconnect prompt
    await adminClient
      .from('xero_connection')
      .update({ is_active: false, disconnected_at: new Date().toISOString() })
      .eq('is_active', true);
    return { ok: false, error: 'reconnect_required' };
  }

  const newExpiry = new Date(Date.now() + (data.expires_in as number) * 1000).toISOString();

  // xero_do_refresh: conditional update — only writes if token still looks expired,
  // preventing a double-write race where two simultaneous callers both exchange tokens.
  // Returns true if this caller won the write, false if another already refreshed.
  const { data: wrote } = await adminClient.rpc('xero_do_refresh', {
    p_access_token:  data.access_token,
    p_refresh_token: data.refresh_token,
    p_token_expiry:  newExpiry,
  });

  if (!wrote) {
    // Another concurrent caller already wrote fresh tokens — re-read and return theirs
    const { data: fresh } = await adminClient
      .from('xero_connection')
      .select('access_token, tenant_id')
      .eq('is_active', true)
      .maybeSingle();
    if (!fresh) return { ok: false, error: 'No active Xero connection after refresh' };
    return { ok: true, accessToken: fresh.access_token, tenantId: fresh.tenant_id };
  }

  return { ok: true, accessToken: data.access_token, tenantId: conn.tenant_id };
}

async function xeroGet(
  path: string,
  accessToken: string,
  tenantId: string,
  params?: string,
) {
  const url = `${XERO_API}${path}${params ? '?' + params : ''}`;
  console.log('[xero-oauth] request: GET', url);
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Xero-tenant-id': tenantId,
      'Accept': 'application/json',
    },
  });
  let data: unknown;
  const ct = res.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) {
    data = await res.json();
  } else {
    const text = await res.text().catch(() => '(unreadable)');
    console.warn('[xero-oauth] non-JSON response body:', text.slice(0, 300));
    data = { error: `Non-JSON response (${res.status}): ${text.slice(0, 200)}` };
  }
  console.log('[xero-oauth] response:', res.status, JSON.stringify(data).slice(0, 500));
  return { status: res.status, data };
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

    // Verify caller's JWT
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return err('Unauthorized', 401);

    // Load role from app_users
    const adminClient = createClient(supabaseUrl, serviceKey);
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role')
      .eq('auth_user_id', user.id)
      .single();

    if (!appUser || !FINANCE_ROLES.includes(appUser.role)) {
      return err('Forbidden — finance roles only', 403);
    }

    const role    = appUser.role as string;
    const userId  = appUser.id as string;
    const body    = await req.json() as Record<string, unknown>;
    const action  = body.action as string;

    // ── credentials_status ──────────────────────────────────────────────────
    if (action === 'credentials_status') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      return json({ has_client_id: !!clientId, has_client_secret: !!clientSecret });
    }

    // ── save_credentials ────────────────────────────────────────────────────
    if (action === 'save_credentials') {
      if (!CREDS_ROLES.includes(role)) return err('Forbidden', 403);
      const updates: { key: string; value: string }[] = [];
      if (body.client_id    && typeof body.client_id    === 'string') updates.push({ key: 'xero_client_id',     value: body.client_id.trim()     });
      if (body.client_secret && typeof body.client_secret === 'string') updates.push({ key: 'xero_client_secret', value: body.client_secret.trim() });
      for (const row of updates) {
        await adminClient
          .from('app_settings')
          .upsert({ key: row.key, value: row.value }, { onConflict: 'key' });
      }
      return json({ ok: true });
    }

    // ── authorize_url ────────────────────────────────────────────────────────
    if (action === 'authorize_url') {
      const { clientId } = await getXeroCreds(adminClient);
      if (!clientId) return err('Xero Client ID not configured', 400);
      const origin       = (body.origin as string) || '';
      const state        = (body.state  as string) || '';
      const redirectUri  = `${origin}/xero-callback`;
      const scope        = 'openid profile email accounting.invoices accounting.payments accounting.contacts accounting.settings accounting.reports.profitandloss.read accounting.reports.aged.read offline_access';
      const params = new URLSearchParams({
        response_type: 'code',
        client_id:     clientId,
        redirect_uri:  redirectUri,
        scope,
        state,
      });
      return json({ url: `${XERO_AUTH_URL}?${params.toString()}` });
    }

    // ── callback ─────────────────────────────────────────────────────────────
    if (action === 'callback') {
      if (role === 'ecommerce_manager') return err('Forbidden', 403);
      const code        = body.code         as string;
      const redirectUri = body.redirect_uri as string;
      if (!code || !redirectUri) return err('Missing code or redirect_uri', 400);

      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);

      const { status: tokenStatus, data: tokenData } = await exchangeToken(
        'authorization_code',
        { code, redirect_uri: redirectUri },
        clientId,
        clientSecret,
      );
      if (tokenStatus !== 200) return err(tokenData.error_description || tokenData.error || 'Token exchange failed', 400);

      const { status: tenantStatus, data: tenantsData } = await getXeroTenants(tokenData.access_token);
      if (tenantStatus !== 200 || !Array.isArray(tenantsData) || tenantsData.length === 0) {
        return err('Could not retrieve Xero tenant', 400);
      }

      const tenant = tenantsData[0];
      const newTenantId   = tenant.tenantId   as string;
      const newTenantName = tenant.tenantName as string;
      const tokenExpiry   = new Date(Date.now() + (tokenData.expires_in as number) * 1000).toISOString();

      // xero_do_connect: single Postgres transaction — deactivates previous
      // connections, inserts the new active row, and clears stale client
      // mappings if the tenant changed. Avoids the gap between two separate calls.
      const { data: connectResult, error: connectErr } = await adminClient.rpc('xero_do_connect', {
        p_tenant_id:     newTenantId,
        p_tenant_name:   newTenantName,
        p_access_token:  tokenData.access_token,
        p_refresh_token: tokenData.refresh_token,
        p_token_expiry:  tokenExpiry,
        p_connected_by:  userId,
      });

      if (connectErr) {
        console.error('[xero-oauth] xero_do_connect RPC error:', connectErr);
        return err('Failed to save connection: ' + connectErr.message, 500);
      }

      const tenantChanged   = !!(connectResult as Record<string, unknown>)?.tenant_changed;
      const previousTenant  = (connectResult as Record<string, unknown>)?.previous_tenant as string | undefined;

      return json({
        ok:               true,
        tenant_name:      newTenantName,
        tenant_changed:   tenantChanged,
        previous_tenant:  tenantChanged ? previousTenant : undefined,
      });
    }

    // ── refresh ───────────────────────────────────────────────────────────────
    if (action === 'refresh') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const result = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!result.ok) return json({ error: result.error }, result.error === 'reconnect_required' ? 200 : 400);
      return json({ ok: true });
    }

    // ── disconnect ────────────────────────────────────────────────────────────
    // Does THREE things to ensure a clean disconnect that forces re-consent on
    // the next Connect (so newly-added scopes actually take effect):
    //   1. Marks our local xero_connection row inactive (UI stops showing connected)
    //   2. Calls Xero's /connections/{id} DELETE — removes the app authorization
    //      from the Xero org entirely. Without this, Xero will silently re-issue
    //      tokens on reconnect without showing the consent screen, and the
    //      previously-consented scopes will be reused.
    //   3. Revokes the refresh token — invalidates the token grant.
    if (action === 'disconnect') {
      const { data: conn } = await adminClient
        .from('xero_connection')
        .select('access_token, refresh_token, tenant_id')
        .eq('is_active', true)
        .maybeSingle();

      // Mark inactive locally first so the UI reflects immediately even if the
      // remote calls below are slow.
      await adminClient
        .from('xero_connection')
        .update({ is_active: false, disconnected_at: new Date().toISOString() })
        .eq('is_active', true);

      const { clientId, clientSecret } = await getXeroCreds(adminClient);

      // 2) Remove the Xero-side connection record so a future authorize call
      //    forces the user to consent again (essential when we've added new
      //    scopes like accounting.reports.profitandloss.read).
      if (conn?.access_token && conn?.tenant_id) {
        try {
          console.log('[xero-oauth] request: GET https://api.xero.com/connections');
          const listRes = await fetch('https://api.xero.com/connections', {
            headers: {
              Authorization: `Bearer ${conn.access_token}`,
              Accept:        'application/json',
            },
          });
          console.log('[xero-oauth] response:', listRes.status, '(list connections)');
          if (listRes.ok) {
            const connections = await listRes.json() as Array<{ id: string; tenantId: string }>;
            const match = connections.find((c) => c.tenantId === conn.tenant_id);
            if (match) {
              console.log('[xero-oauth] request: DELETE https://api.xero.com/connections/' + match.id);
              const delRes = await fetch(`https://api.xero.com/connections/${match.id}`, {
                method: 'DELETE',
                headers: { Authorization: `Bearer ${conn.access_token}` },
              });
              console.log('[xero-oauth] response:', delRes.status, '(delete connection)');
            } else {
              console.log('[xero-oauth] no matching Xero connection for tenant', conn.tenant_id);
            }
          }
        } catch (e) {
          console.warn('[xero-oauth] connection delete failed (non-fatal):', e);
        }
      }

      // 3) Revoke the refresh token so all derived access tokens become invalid.
      if (conn?.refresh_token && clientId && clientSecret) {
        try {
          console.log('[xero-oauth] request: POST', XERO_REVOKE_URL);
          const rRes = await fetch(XERO_REVOKE_URL, {
            method: 'POST',
            headers: {
              'Content-Type':  'application/x-www-form-urlencoded',
              Authorization:   basicAuth(clientId, clientSecret),
            },
            body: new URLSearchParams({ token: conn.refresh_token }).toString(),
          });
          console.log('[xero-oauth] response:', rRes.status, '(token revocation)');
        } catch (e) {
          console.warn('[xero-oauth] token revocation failed (non-fatal):', e);
        }
      }

      return json({ ok: true });
    }

    // ── test_connection ───────────────────────────────────────────────────────
    if (action === 'test_connection') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const { status, data } = await xeroGet('/api.xro/2.0/Organisation', refreshResult.accessToken!, refreshResult.tenantId!);
      if (status !== 200) return err('Xero API error: ' + (data?.Type || status), 400);
      const org = data?.Organisations?.[0];
      return json({ ok: true, organisation_name: org?.Name ?? 'Unknown' });
    }

    // ── list_contacts ─────────────────────────────────────────────────────────
    if (action === 'list_contacts') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      // pageSize=1000 (Xero's max) fetches all contacts in 1 call for most accounts.
      // summaryOnly=true returns only ContactID + Name — tiny payload, fast.
      // ContactStatus filter applied server-side to avoid fetching archived contacts.
      const allContacts: unknown[] = [];
      let page = 1;
      const PAGE_SIZE = 1000;
      const t0 = Date.now();
      while (true) {
        const params = `pageSize=${PAGE_SIZE}&page=${page}&summaryOnly=true&ContactStatus=ACTIVE`;
        console.log(`[xero-oauth] list_contacts page=${page} elapsed=${Date.now()-t0}ms`);
        const { status, data } = await xeroGet('/api.xro/2.0/Contacts', refreshResult.accessToken!, refreshResult.tenantId!, params);
        if (status === 429) return err('Xero rate limit hit — please wait 60 seconds and try again', 429);
        if (status !== 200) return err(`Xero Contacts API error ${status}: ${JSON.stringify(data).slice(0,300)}`, 400);
        const page_contacts = (data?.Contacts ?? []) as Array<Record<string, unknown>>;
        console.log(`[xero-oauth] list_contacts page=${page} got=${page_contacts.length} elapsed=${Date.now()-t0}ms`);
        allContacts.push(...page_contacts);
        if (page_contacts.length < PAGE_SIZE) break;
        page++;
      }
      console.log(`[xero-oauth] list_contacts done total=${allContacts.length} elapsed=${Date.now()-t0}ms`);

      const simplified = (allContacts as Array<Record<string, unknown>>).map((c) => ({
        ContactID:    c.ContactID,
        Name:         c.Name,
        EmailAddress: c.EmailAddress ?? null,
      }));
      return json({ contacts: simplified });
    }

    // ── search_contacts ───────────────────────────────────────────────────────
    if (action === 'search_contacts') {
      const query = ((body.query as string) || '').trim();
      if (!query || query.length < 2) return json({ contacts: [] });
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const params = `searchTerm=${encodeURIComponent(query)}&summaryOnly=true&pageSize=20`;
      console.log(`[xero-oauth] search_contacts query="${query}"`);
      const { status, data } = await xeroGet('/api.xro/2.0/Contacts', refreshResult.accessToken!, refreshResult.tenantId!, params);
      if (status === 429) return err('Xero rate limit — please wait a moment and try again', 429);
      if (status !== 200) return err(`Xero Contacts API error ${status}`, 400);
      const contacts = ((data?.Contacts ?? []) as Array<Record<string, unknown>>)
        .filter((c) => c.ContactStatus === 'ACTIVE')
        .map((c) => ({ ContactID: c.ContactID, Name: c.Name, EmailAddress: c.EmailAddress ?? null }));
      console.log(`[xero-oauth] search_contacts returned ${contacts.length} results`);
      return json({ contacts });
    }

    // ── get_contacts_by_ids ───────────────────────────────────────────────────
    if (action === 'get_contacts_by_ids') {
      const ids = ((body.ids as string[]) || []).filter(Boolean).slice(0, 100);
      if (!ids.length) return json({ contacts: [] });
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const params = `IDs=${ids.join(',')}&summaryOnly=true`;
      console.log(`[xero-oauth] get_contacts_by_ids count=${ids.length}`);
      const { status, data } = await xeroGet('/api.xro/2.0/Contacts', refreshResult.accessToken!, refreshResult.tenantId!, params);
      if (status !== 200) return err(`Xero Contacts API error ${status}`, 400);
      const contacts = ((data?.Contacts ?? []) as Array<Record<string, unknown>>)
        .map((c) => ({ ContactID: c.ContactID, Name: c.Name, EmailAddress: c.EmailAddress ?? null }));
      console.log(`[xero-oauth] get_contacts_by_ids returned ${contacts.length} contacts`);
      return json({ contacts });
    }

    // ── list_invoices ─────────────────────────────────────────────────────────
    // Server-side filtering by preset so we only fetch what the user asked for,
    // dramatically reducing payload + rate-limit risk vs. pulling YTD by default.
    //
    // Presets (one is required):
    //   overdue       — AUTHORISED only, wide date window, filter overdue client-side here
    //   last_30       — invoices issued in last 30 days, all statuses
    //   last_90       — invoices issued in last 90 days, all statuses
    //   ytd           — invoices issued since Jan 1, all statuses
    //   custom        — caller provides date_from / date_to (YYYY-MM-DD)
    //
    // No summaryOnly: we need Contact.EmailAddress for chase emails. Volume is
    // controlled by the preset choice.
    if (action === 'list_invoices') {
      const preset   = ((body.preset as string) || '').trim();
      const dateFromIn = ((body.date_from as string) || '').trim();
      const dateToIn   = ((body.date_to   as string) || '').trim();
      if (!preset) return err('Missing preset parameter', 400);

      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const now      = new Date();
      const isoDate  = (d: Date) => d.toISOString().split('T')[0];
      const daysAgo  = (n: number) => { const d = new Date(now); d.setDate(d.getDate() - n); return d; };

      let dateFrom = '';
      let dateTo   = '';
      let statuses = 'AUTHORISED,PAID';
      let postFilterOverdue = false;

      if (preset === 'overdue') {
        // Wide net so we catch invoices issued long ago that are still due.
        // We then filter overdue client-side here in the function.
        dateFrom = '2020-01-01';
        statuses = 'AUTHORISED';
        postFilterOverdue = true;
      } else if (preset === 'last_30') {
        dateFrom = isoDate(daysAgo(30));
      } else if (preset === 'last_90') {
        dateFrom = isoDate(daysAgo(90));
      } else if (preset === 'ytd') {
        dateFrom = `${now.getFullYear()}-01-01`;
      } else if (preset === 'custom') {
        if (!dateFromIn) return err('custom preset requires date_from', 400);
        dateFrom = dateFromIn;
        if (dateToIn) dateTo = dateToIn;
      } else {
        return err(`Unknown preset: ${preset}`, 400);
      }

      const PAGE_SIZE = 1000;
      const allInvoices: Array<Record<string, unknown>> = [];
      let page = 1;
      const t0 = Date.now();
      while (true) {
        const parts: string[] = [
          `Statuses=${statuses}`,
          `DateFrom=${dateFrom}`,
          `page=${page}`,
          `pageSize=${PAGE_SIZE}`,
        ];
        if (dateTo) parts.push(`DateTo=${dateTo}`);
        const params = parts.join('&');
        console.log(`[xero-oauth] list_invoices preset=${preset} page=${page} elapsed=${Date.now() - t0}ms`);
        const { status, data } = await xeroGet('/api.xro/2.0/Invoices', refreshResult.accessToken!, refreshResult.tenantId!, params);
        if (status === 429) {
          // Surface which limit was hit if Xero told us
          return err('Xero rate limit hit — please wait 60 seconds and try again', 429);
        }
        if (status !== 200) return err(`Xero Invoices API error ${status}: ${JSON.stringify(data).slice(0,300)}`, 400);

        const invoices = (data?.Invoices ?? []) as Array<Record<string, unknown>>;
        const accrec = invoices.filter((i) => i.Type === 'ACCREC');
        allInvoices.push(...accrec);
        console.log(`[xero-oauth] list_invoices page=${page} got=${invoices.length} accrec=${accrec.length}`);
        if (invoices.length < PAGE_SIZE) break;
        page++;
      }
      console.log(`[xero-oauth] list_invoices done total=${allInvoices.length} elapsed=${Date.now() - t0}ms`);

      const today = isoDate(now);
      const simplified = allInvoices
        .filter((i) => {
          if (!postFilterOverdue) return true;
          // Overdue = past DueDate AND still has balance
          return (i.DueDate as string) < today && Number(i.AmountDue ?? 0) > 0;
        })
        .map((i) => {
          const contact = (i.Contact ?? {}) as Record<string, unknown>;
          return {
            InvoiceID:      i.InvoiceID,
            InvoiceNumber:  i.InvoiceNumber,
            Reference:      i.Reference ?? null,
            Date:           i.Date,
            DueDate:        i.DueDate,
            Status:         i.Status,
            AmountDue:      i.AmountDue ?? 0,
            AmountPaid:     i.AmountPaid ?? 0,
            Total:          i.Total ?? 0,
            CurrencyCode:   i.CurrencyCode ?? 'EUR',
            Contact: {
              ContactID:    contact.ContactID,
              Name:         contact.Name,
              EmailAddress: contact.EmailAddress ?? null,
            },
          };
        });
      return json({ invoices: simplified, preset, date_from: dateFrom, date_to: dateTo || null, count: simplified.length });
    }

    // ── overview_metrics ──────────────────────────────────────────────────────
    // Returns pre-aggregated finance KPIs without pulling every invoice. Uses
    // Xero's Reports endpoints: P&L for YTD/last month/monthly chart, and Aged
    // Receivables for outstanding + overdue totals.
    //
    // Output shape:
    //   {
    //     ytd_revenue:       number,
    //     last_month_revenue: number,
    //     monthly: { '2026-01': 1234, '2026-02': 2345, ... },     // for chart
    //     outstanding_total: number,
    //     overdue_total:     number,
    //     overdue_count:     number,
    //     generated_at:      iso string
    //   }
    if (action === 'overview_metrics') {
      const EF_VERSION = '2026-05-17-ytd-fix';
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const now      = new Date();
      const year     = now.getFullYear();
      const month    = now.getMonth(); // 0-11
      const today    = now.toISOString().split('T')[0];
      const yearStart = `${year}-01-01`;
      const yearEnd   = `${year}-12-31`;

      // Robust string→number parser. Xero sometimes returns "1,234.56" or
      // "(1234.56)" (parens = negative). Returns 0 on parse failure.
      const parseNum = (raw: unknown): number => {
        if (raw == null) return 0;
        let s = String(raw).trim();
        if (!s) return 0;
        const neg = s.startsWith('(') && s.endsWith(')');
        if (neg) s = s.slice(1, -1);
        s = s.replace(/,/g, '').replace(/\s/g, '');
        const n = Number(s);
        if (!Number.isFinite(n)) return 0;
        return neg ? -n : n;
      };

      // ── Run all 3 Xero calls in parallel ──────────────────────────────
      // Token is shared (already refreshed above); each call is independent.
      const acc = refreshResult.accessToken!;
      const ten = refreshResult.tenantId!;
      const [ytdRes, monthlyRes, arRes] = await Promise.allSettled([
        xeroGet('/api.xro/2.0/Reports/ProfitAndLoss', acc, ten, `fromDate=${yearStart}&toDate=${today}`),
        xeroGet('/api.xro/2.0/Reports/ProfitAndLoss', acc, ten, `toDate=${yearEnd}&periods=11&timeframe=MONTH`),
        xeroGet('/api.xro/2.0/Reports/AgedReceivablesByContact', acc, ten, `date=${today}`),
      ]);

      // ── 1) YTD figure — dedicated single-period P&L call ─────────────
      // Single-period P&L returns exactly 2 cell columns per row: [label, value].
      // We let Xero do the maths — no client-side summing of monthly cells.
      let ytdRevenue = 0;
      let plYtdSectionTitleMatched: string | null = null;
      let plYtdMatchedVia: 'A_section' | 'B_summary_label' | 'C_fuzzy' | 'none' = 'none';
      let plYtdSummaryLabel: string | null = null;
      let plYtdValueRaw: string | null = null;
      let plYtdSectionAccountLines: Array<{ label: string; value: number }> = [];
      let plSectionTitles: string[] = [];
      let plYtdError: string | null = null;

      if (ytdRes.status === 'fulfilled') {
        const { status: s, data: d } = ytdRes.value;
        if (s === 200) {
          const rpt  = ((d?.Reports ?? []) as Array<Record<string, unknown>>)[0];
          const rows = ((rpt?.Rows ?? []) as Array<Record<string, unknown>>);

          // Collect top-level section titles for diagnostic visibility
          plSectionTitles = rows
            .filter((r) => r.RowType === 'Section')
            .map((r) => String(r.Title ?? ''))
            .filter(Boolean);

          // Section title matcher (case-insensitive)
          const SECTION_RE = /^(income|trading income|sales|revenue|turnover|operating income)$/i;
          // SummaryRow label matcher
          const SUMMARY_RE = /^total\s+(income|sales|revenue|turnover|trading income|operating income)$/i;

          // Helper to extract row's account label + value (value = Cells[1])
          const rowLabelValue = (r: Record<string, unknown>): { label: string; value: number } => {
            const cells = ((r.Cells ?? []) as Array<Record<string, unknown>>);
            return {
              label: String(cells[0]?.Value ?? '').trim(),
              value: parseNum(cells[1]?.Value),
            };
          };

          // Priority A: top-level Section with matching Title → direct-child SummaryRow
          let pickedSummary: Record<string, unknown> | null = null;
          for (const r of rows) {
            if (r.RowType !== 'Section') continue;
            const title = String(r.Title ?? '');
            if (!SECTION_RE.test(title)) continue;
            const childRows = ((r.Rows ?? []) as Array<Record<string, unknown>>);
            const summary = childRows.find((cr) => cr.RowType === 'SummaryRow');
            if (summary) {
              plYtdSectionTitleMatched = title;
              plYtdMatchedVia = 'A_section';
              pickedSummary = summary;
              // Capture every leaf Row (account line) inside this section for diagnostic
              plYtdSectionAccountLines = childRows
                .filter((cr) => cr.RowType === 'Row')
                .map(rowLabelValue);
              break;
            }
          }

          // Priority B: scan ALL SummaryRows in the report (top-level + nested) for matching label
          if (!pickedSummary) {
            const allSummaries: Array<{ row: Record<string, unknown>; sectionTitle: string | null }> = [];
            const collect = (rs: Array<Record<string, unknown>>, parentTitle: string | null) => {
              for (const r of rs) {
                if (r.RowType === 'SummaryRow') allSummaries.push({ row: r, sectionTitle: parentTitle });
                if (Array.isArray(r.Rows)) collect(r.Rows as Array<Record<string, unknown>>, String(r.Title ?? parentTitle ?? ''));
              }
            };
            collect(rows, null);
            const hit = allSummaries.find(({ row }) => {
              const label = String(((row.Cells ?? []) as Array<Record<string, unknown>>)[0]?.Value ?? '').trim();
              return SUMMARY_RE.test(label);
            });
            if (hit) {
              pickedSummary = hit.row;
              plYtdMatchedVia = 'B_summary_label';
              plYtdSectionTitleMatched = hit.sectionTitle;
            }
          }

          // Priority C: fuzzy — any SummaryRow whose label starts with "Total Income"
          if (!pickedSummary) {
            const collectAll = (rs: Array<Record<string, unknown>>): Array<Record<string, unknown>> => {
              const out: Array<Record<string, unknown>> = [];
              for (const r of rs) {
                if (r.RowType === 'SummaryRow') out.push(r);
                if (Array.isArray(r.Rows)) out.push(...collectAll(r.Rows as Array<Record<string, unknown>>));
              }
              return out;
            };
            const all = collectAll(rows);
            const hit = all.find((r) => {
              const label = String(((r.Cells ?? []) as Array<Record<string, unknown>>)[0]?.Value ?? '').trim();
              return /^total\s+income/i.test(label);
            });
            if (hit) {
              pickedSummary = hit;
              plYtdMatchedVia = 'C_fuzzy';
            }
          }

          if (pickedSummary) {
            const cells = ((pickedSummary.Cells ?? []) as Array<Record<string, unknown>>);
            plYtdSummaryLabel = String(cells[0]?.Value ?? '').trim();
            plYtdValueRaw     = cells[1]?.Value == null ? null : String(cells[1].Value);
            ytdRevenue        = parseNum(cells[1]?.Value);
          } else {
            plYtdError = 'No matching Income SummaryRow found';
          }
        } else {
          plYtdError = `Xero P&L (YTD) returned ${s}: ${JSON.stringify(d).slice(0, 200)}`;
        }
      } else {
        plYtdError = `Xero P&L (YTD) call failed: ${String(ytdRes.reason).slice(0, 200)}`;
      }

      // ── 2) Monthly chart + last-month KPI ─────────────────────────────
      // Uses the periods=11&timeframe=MONTH call. We DO NOT compute YTD from
      // this — it's used purely for the monthly chart and last-month KPI.
      const monthly: Record<string, number> = {};
      for (let i = 0; i < 12; i++) monthly[`${year}-${String(i + 1).padStart(2, '0')}`] = 0;

      let monthlyHeaders: string[] = [];
      let monthlyColumnMap: Array<string | null> = [];
      let monthlySummaryCells: Array<string | null> = [];
      let monthlyError: string | null = null;

      if (monthlyRes.status === 'fulfilled') {
        const { status: s, data: d } = monthlyRes.value;
        if (s === 200) {
          const rpt    = ((d?.Reports ?? []) as Array<Record<string, unknown>>)[0];
          const mRows  = ((rpt?.Rows ?? []) as Array<Record<string, unknown>>);
          const hdrRow = mRows.find((r) => r.RowType === 'Header');
          const hdrCells = ((hdrRow?.Cells ?? []) as Array<Record<string, unknown>>);
          monthlyHeaders = hdrCells.map((c) => String(c.Value ?? ''));

          const MONTH_MAP: Record<string, string> = {
            jan: '01', january: '01', feb: '02', february: '02',
            mar: '03', march:   '03', apr: '04', april:    '04',
            may: '05',                jun: '06', june:     '06',
            jul: '07', july:    '07', aug: '08', august:   '08',
            sep: '09', sept:    '09', september: '09',
            oct: '10', october: '10', nov: '11', november: '11',
            dec: '12', december:'12',
          };
          monthlyColumnMap = hdrCells.map((c, i) => {
            if (i === 0) return null;
            const raw = String(c.Value ?? '').trim();
            if (!raw || /total/i.test(raw)) return null;
            const m = raw.match(/(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t)?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s*[-\s]\s*(\d{2}|\d{4})/i);
            if (!m) return null;
            const mm = MONTH_MAP[m[1].toLowerCase()];
            if (!mm) return null;
            const yy = m[2].length === 2 ? `20${m[2]}` : m[2];
            return `${yy}-${mm}`;
          });

          // Find Income section's direct-child SummaryRow (mirror the Priority A logic)
          const SECTION_RE = /^(income|trading income|sales|revenue|turnover|operating income)$/i;
          const incomeSec = mRows.find((r) =>
            r.RowType === 'Section' && SECTION_RE.test(String(r.Title ?? ''))
          );
          const incomeChildren = ((incomeSec?.Rows ?? []) as Array<Record<string, unknown>>);
          const summaryRow = incomeChildren.find((r) => r.RowType === 'SummaryRow');
          const summaryCells = ((summaryRow?.Cells ?? []) as Array<Record<string, unknown>>);
          monthlySummaryCells = summaryCells.map((c) => c.Value == null ? null : String(c.Value));

          summaryCells.forEach((c, i) => {
            const key = monthlyColumnMap[i];
            if (!key) return;
            monthly[key] = parseNum(c.Value);
          });
        } else {
          monthlyError = `Xero P&L (monthly) returned ${s}: ${JSON.stringify(d).slice(0, 200)}`;
        }
      } else {
        monthlyError = `Xero P&L (monthly) call failed: ${String(monthlyRes.reason).slice(0, 200)}`;
      }

      // Last month: previous calendar month
      const lastMonthIdx     = month; // e.g. May (month=4) → "04" = April
      const lastMonthKey     = lastMonthIdx >= 1
        ? `${year}-${String(lastMonthIdx).padStart(2, '0')}`
        : null;
      const lastMonthRevenue = lastMonthKey ? (monthly[lastMonthKey] ?? 0) : 0;
      const lastMonthLabel   = lastMonthKey
        ? new Date(year, lastMonthIdx - 1, 1).toLocaleDateString('en-IE', { month: 'long', year: 'numeric' })
        : null;

      // ── 3) Aged Receivables — outstanding + overdue ─────────────────────
      let outstandingTotal = 0;
      let overdueTotal     = 0;
      let overdueCount     = 0;
      let arError: string | null = null;

      if (arRes.status === 'fulfilled') {
        const { status: s, data: d } = arRes.value;
        if (s === 200) {
          const arReport = ((d?.Reports ?? []) as Array<Record<string, unknown>>)[0];
          const arRows   = ((arReport?.Rows ?? []) as Array<Record<string, unknown>>);
          // Total row: SummaryRow with cells [Label, Current, 1-30, 31-60, 61-90, Older, Total]
          const walk = (rs: Array<Record<string, unknown>>) => {
            for (const r of rs) {
              if (r.RowType === 'SummaryRow') {
                const cells = ((r.Cells ?? []) as Array<Record<string, unknown>>);
                if (cells.length >= 7) {
                  outstandingTotal = parseNum(cells[6]?.Value);
                  overdueTotal =
                      parseNum(cells[2]?.Value)
                    + parseNum(cells[3]?.Value)
                    + parseNum(cells[4]?.Value)
                    + parseNum(cells[5]?.Value);
                }
              }
              if (r.RowType === 'Row') {
                const cells = ((r.Cells ?? []) as Array<Record<string, unknown>>);
                if (cells.length >= 7) {
                  const buckets =
                      parseNum(cells[2]?.Value)
                    + parseNum(cells[3]?.Value)
                    + parseNum(cells[4]?.Value)
                    + parseNum(cells[5]?.Value);
                  if (buckets > 0) overdueCount++;
                }
              }
              if (Array.isArray(r.Rows)) walk(r.Rows as Array<Record<string, unknown>>);
            }
          };
          walk(arRows);
        } else {
          arError = `Xero AR returned ${s}`;
        }
      } else {
        arError = `Xero AR call failed: ${String(arRes.reason).slice(0, 200)}`;
      }

      console.log('[xero-oauth] overview_metrics:', JSON.stringify({
        ef_version: EF_VERSION,
        ytdRevenue, plYtdMatchedVia, plYtdSummaryLabel, plYtdValueRaw,
        plYtdSectionTitleMatched, plSectionTitles, plYtdError,
        monthlyHeaders, monthlyColumnMap, monthlySummaryCells, monthlyError,
        outstandingTotal, overdueTotal, overdueCount, arError,
      }).slice(0, 2000));

      return json({
        ytd_revenue:        ytdRevenue,
        last_month_revenue: lastMonthRevenue,
        last_month_label:   lastMonthLabel,
        monthly,
        outstanding_total: outstandingTotal,
        overdue_total:     overdueTotal,
        overdue_count:     overdueCount,
        generated_at:      now.toISOString(),
        _diagnostic: {
          ef_version: EF_VERSION,
          pl_ytd: {
            matched_via:          plYtdMatchedVia,
            section_title:        plYtdSectionTitleMatched,
            summary_label:        plYtdSummaryLabel,
            value_raw:            plYtdValueRaw,
            value_parsed:         ytdRevenue,
            section_titles_found: plSectionTitles,
            section_account_lines: plYtdSectionAccountLines,
            error:                plYtdError,
          },
          pl_monthly: {
            headers:       monthlyHeaders,
            column_map:    monthlyColumnMap,
            summary_cells: monthlySummaryCells,
            error:         monthlyError,
          },
          ar: { error: arError },
        },
      });
    }

    // ── find_or_create_contact ────────────────────────────────────────────────
    // Exact email match using OData == operator. If not found, creates a new
    // contact with the given name + email. Used by future server-side flows
    // (the ecommerce-sync edge function implements its own equivalent).
    if (action === 'find_or_create_contact') {
      const email = ((body.email as string) || '').trim();
      const name  = ((body.name  as string) || '').trim();
      if (!email) return err('email is required', 400);
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      // OData equality is == (single = is a syntax error in Xero's query language)
      const whereClause = `EmailAddress=="${email.replace(/"/g, '\\"')}"`;
      const findParams  = `where=${encodeURIComponent(whereClause)}&summaryOnly=true`;
      const { status: findStatus, data: findData } = await xeroGet(
        '/api.xro/2.0/Contacts',
        refreshResult.accessToken!,
        refreshResult.tenantId!,
        findParams,
      );
      if (findStatus !== 200) return err(`Xero contact lookup failed: ${findStatus}`, 400);
      const existing = ((findData?.Contacts ?? []) as Array<Record<string, unknown>>)[0];
      if (existing?.ContactID) {
        return json({ contact_id: existing.ContactID, created: false });
      }

      // Create
      const createUrl = `${XERO_API}/api.xro/2.0/Contacts`;
      console.log('[xero-oauth] request: POST', createUrl);
      const createRes = await fetch(createUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${refreshResult.accessToken}`,
          'Xero-tenant-id': refreshResult.tenantId!,
          'Content-Type':   'application/json',
          'Accept':         'application/json',
        },
        body: JSON.stringify({ Contacts: [{ Name: name || email, EmailAddress: email }] }),
      });
      const createData = await createRes.json().catch(() => ({}));
      console.log('[xero-oauth] response:', createRes.status, JSON.stringify(createData).slice(0, 300));
      if (createRes.status !== 200) return err(`Xero contact create failed: ${createRes.status}`, 400);
      const created = ((createData?.Contacts ?? []) as Array<Record<string, unknown>>)[0];
      return json({ contact_id: created?.ContactID, created: true });
    }

    // ── list_accounts ─────────────────────────────────────────────────────────
    if (action === 'list_accounts') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const params = `where=Status%3D%3D%22ACTIVE%22`;
      const { status, data } = await xeroGet('/api.xro/2.0/Accounts', refreshResult.accessToken!, refreshResult.tenantId!, params);
      if (status !== 200) return err('Xero API error', 400);

      const accounts = ((data?.Accounts ?? []) as Array<Record<string, unknown>>).map((a) => ({
        Code:    a.Code,
        Name:    a.Name,
        Type:    a.Type,
        TaxType: a.TaxType,
      }));
      return json({ accounts });
    }

    return err('Unknown action: ' + action, 400);

  } catch (e) {
    console.error('[xero-oauth] unhandled error:', e);
    return err(String(e), 500);
  }
});
