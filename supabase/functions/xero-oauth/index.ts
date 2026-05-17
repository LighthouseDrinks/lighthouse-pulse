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

// Xero returns DueDate/Date in legacy WCF format /Date(1234567890000+0000)/ on most
// endpoints. Newer endpoints sometimes return ISO. Parse both defensively so callers
// never have to think about it. Returns null for missing/unparseable values.
function parseXeroDate(raw: unknown): Date | null {
  if (raw == null) return null;
  const s = String(raw);
  if (!s) return null;
  const m = /\/Date\((-?\d+)([+-]\d{4})?\)\//.exec(s);
  if (m) return new Date(parseInt(m[1], 10));
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : d;
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
      let postFilterOverdue     = false;
      let postFilterOutstanding = false;

      if (preset === 'overdue') {
        // Wide net so we catch invoices issued long ago that are still due.
        // We then filter overdue client-side here in the function.
        dateFrom = '2020-01-01';
        statuses = 'AUTHORISED';
        postFilterOverdue = true;
      } else if (preset === 'outstanding') {
        // Every still-owed AUTHORISED invoice, regardless of due date.
        // Mirrors the Owed-to-You headline on the Overview tab.
        dateFrom = '2020-01-01';
        statuses = 'AUTHORISED';
        postFilterOutstanding = true;
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
      const todayDate = new Date(today + 'T00:00:00');
      const simplified = allInvoices
        .filter((i) => {
          if (postFilterOutstanding) return Number(i.AmountDue ?? 0) > 0;
          if (postFilterOverdue) {
            // Overdue = past DueDate AND still has balance.
            // parseXeroDate handles both WCF (/Date(...)/) and ISO; the previous
            // string-compare against a WCF-formatted DueDate was always false in a
            // misleading way (saved only by the AmountDue>0 guard).
            const due = parseXeroDate(i.DueDate);
            if (!due) return false;
            return due < todayDate && Number(i.AmountDue ?? 0) > 0;
          }
          return true;
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
      const EF_VERSION = '2026-05-17-aging-buckets-v4';
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      // ── Helpers ──────────────────────────────────────────────────────
      // Robust string→number parser. Xero returns "1,234.56" or "(1234.56)" (parens = negative).
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
      // parseXeroDate is now a module-level helper (defined above) so list_invoices
      // and any future action can share it.
      const pad2 = (n: number) => String(n).padStart(2, '0');
      const fmtDate = (d: Date) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
      const firstOfMonth = (y: number, m: number) => new Date(y, m, 1);
      const lastOfMonth  = (y: number, m: number) => new Date(y, m + 1, 0); // day 0 of next month
      const clampDateToMonth = (y: number, m: number, d: number) => {
        const last = lastOfMonth(y, m).getDate();
        return new Date(y, m, Math.min(d, last));
      };
      const yoyPct = (cur: number, prior: number): number | null => {
        if (!prior || prior === 0) return null;
        return Math.round((cur - prior) / prior * 1000) / 10;
      };
      // Shared semaphore so all Xero calls (P&L + per-page invoices) respect
      // Xero's per-tenant 5-concurrent ceiling. withSlot wraps any async fn.
      const XERO_CONCURRENCY = 5;
      let _slotsInUse = 0;
      const _slotWaiters: Array<() => void> = [];
      const _acquire = (): Promise<void> => new Promise((resolve) => {
        if (_slotsInUse < XERO_CONCURRENCY) { _slotsInUse++; resolve(); return; }
        _slotWaiters.push(() => { _slotsInUse++; resolve(); });
      });
      const _release = () => {
        _slotsInUse--;
        const next = _slotWaiters.shift();
        if (next) next();
      };
      const withSlot = async <T>(fn: () => Promise<T>): Promise<T> => {
        await _acquire();
        try { return await fn(); } finally { _release(); }
      };

      // Section/Summary matcher reused for all 4 single-period P&L parses
      const SECTION_RE = /^(income|trading income|sales|revenue|turnover|operating income)$/i;
      const SUMMARY_RE = /^total\s+(income|sales|revenue|turnover|trading income|operating income)$/i;
      type IncomeMatch = {
        summary: Record<string, unknown> | null;
        matchedVia: 'A_section' | 'B_summary_label' | 'C_fuzzy' | 'none';
        sectionTitle: string | null;
        sectionAccountLines: Array<{ label: string; value: number }>;
        sectionTitlesFound: string[];
      };
      const findIncomeSummary = (rows: Array<Record<string, unknown>>): IncomeMatch => {
        const sectionTitlesFound = rows
          .filter((r) => r.RowType === 'Section')
          .map((r) => String(r.Title ?? ''))
          .filter(Boolean);
        let sectionAccountLines: Array<{ label: string; value: number }> = [];
        // Priority A
        for (const r of rows) {
          if (r.RowType !== 'Section') continue;
          const title = String(r.Title ?? '');
          if (!SECTION_RE.test(title)) continue;
          const childRows = ((r.Rows ?? []) as Array<Record<string, unknown>>);
          const summary = childRows.find((cr) => cr.RowType === 'SummaryRow');
          if (summary) {
            sectionAccountLines = childRows
              .filter((cr) => cr.RowType === 'Row')
              .map((cr) => {
                const cells = ((cr.Cells ?? []) as Array<Record<string, unknown>>);
                return { label: String(cells[0]?.Value ?? '').trim(), value: parseNum(cells[1]?.Value) };
              });
            return { summary, matchedVia: 'A_section', sectionTitle: title, sectionAccountLines, sectionTitlesFound };
          }
        }
        // Priority B
        const collect = (rs: Array<Record<string, unknown>>, parentTitle: string | null): Array<{ row: Record<string, unknown>; sectionTitle: string | null }> => {
          const out: Array<{ row: Record<string, unknown>; sectionTitle: string | null }> = [];
          for (const r of rs) {
            if (r.RowType === 'SummaryRow') out.push({ row: r, sectionTitle: parentTitle });
            if (Array.isArray(r.Rows)) out.push(...collect(r.Rows as Array<Record<string, unknown>>, String(r.Title ?? parentTitle ?? '')));
          }
          return out;
        };
        const summaries = collect(rows, null);
        const hitB = summaries.find(({ row }) => {
          const label = String(((row.Cells ?? []) as Array<Record<string, unknown>>)[0]?.Value ?? '').trim();
          return SUMMARY_RE.test(label);
        });
        if (hitB) return { summary: hitB.row, matchedVia: 'B_summary_label', sectionTitle: hitB.sectionTitle, sectionAccountLines, sectionTitlesFound };
        // Priority C
        const hitC = summaries.find(({ row }) => {
          const label = String(((row.Cells ?? []) as Array<Record<string, unknown>>)[0]?.Value ?? '').trim();
          return /^total\s+income/i.test(label);
        });
        if (hitC) return { summary: hitC.row, matchedVia: 'C_fuzzy', sectionTitle: hitC.sectionTitle, sectionAccountLines, sectionTitlesFound };
        return { summary: null, matchedVia: 'none', sectionTitle: null, sectionAccountLines, sectionTitlesFound };
      };

      // Parse a single-period P&L call result → { value, diagnostic }
      type SinglePLParse = {
        value: number;
        raw: string | null;
        matched_via: string;
        section_title: string | null;
        summary_label: string | null;
        section_titles_found: string[];
        section_account_lines: Array<{ label: string; value: number }>;
        error: string | null;
      };
      const parseSinglePL = (
        res: PromiseSettledResult<{ status: number; data: Record<string, unknown> }>,
        label: string,
      ): SinglePLParse => {
        if (res.status !== 'fulfilled') {
          return { value: 0, raw: null, matched_via: 'none', section_title: null, summary_label: null, section_titles_found: [], section_account_lines: [], error: `${label} call failed: ${String(res.reason).slice(0, 200)}` };
        }
        const { status, data } = res.value;
        if (status !== 200) {
          return { value: 0, raw: null, matched_via: 'none', section_title: null, summary_label: null, section_titles_found: [], section_account_lines: [], error: `${label} returned ${status}: ${JSON.stringify(data).slice(0, 200)}` };
        }
        const rpt = ((data?.Reports ?? []) as Array<Record<string, unknown>>)[0];
        const rows = ((rpt?.Rows ?? []) as Array<Record<string, unknown>>);
        const m = findIncomeSummary(rows);
        if (!m.summary) {
          return { value: 0, raw: null, matched_via: 'none', section_title: null, summary_label: null, section_titles_found: m.sectionTitlesFound, section_account_lines: [], error: 'No matching Income SummaryRow found' };
        }
        const cells = ((m.summary.Cells ?? []) as Array<Record<string, unknown>>);
        const summary_label = String(cells[0]?.Value ?? '').trim();
        const raw = cells[1]?.Value == null ? null : String(cells[1].Value);
        const value = parseNum(cells[1]?.Value);
        return { value, raw, matched_via: m.matchedVia, section_title: m.sectionTitle, summary_label, section_titles_found: m.sectionTitlesFound, section_account_lines: m.sectionAccountLines, error: null };
      };

      // ── Date setup ────────────────────────────────────────────────────
      const now      = new Date();
      const year     = now.getFullYear();
      const monthIdx = now.getMonth(); // 0-11
      const today    = fmtDate(now);
      const yearStart = `${year}-01-01`;
      const yearEnd   = `${year}-12-31`;

      // Last month — handles January (→ December of previous year)
      const lastMonthY  = monthIdx === 0 ? year - 1 : year;
      const lastMonthMi = monthIdx === 0 ? 11       : monthIdx - 1;
      const lastMonthStart      = firstOfMonth(lastMonthY, lastMonthMi);
      const lastMonthEnd        = lastOfMonth(lastMonthY, lastMonthMi);
      const lastMonthStartPrior = firstOfMonth(lastMonthY - 1, lastMonthMi);
      const lastMonthEndPrior   = lastOfMonth(lastMonthY - 1, lastMonthMi); // auto-handles Feb 28/29
      // YTD prior end — clamped (handles today = Feb 29 → Feb 28 in non-leap year)
      const ytdPriorEnd = clampDateToMonth(year - 1, monthIdx, now.getDate());

      const acc = refreshResult.accessToken!;
      const ten = refreshResult.tenantId!;
      const callPL = (params: string) => withSlot(() => xeroGet('/api.xro/2.0/Reports/ProfitAndLoss', acc, ten, params));

      // ── Paginated invoices fetcher (Type=ACCREC, AUTHORISED only, shared pool) ─
      // Matches Xero's "Awaiting Payment" definition exactly. SUBMITTED drafts are
      // pulled separately so we can show them as an amber side-note (instead of
      // silently hiding money that someone forgot to send).
      type InvoiceSummary = {
        AmountDue?: number;
        DueDate?: string;
        InvoiceID?: string;
        Status?: string;
        InvoiceNumber?: string;
        Type?: string;
      };
      type InvoicesFetchResult = { invoices: InvoiceSummary[]; pages_fetched: number; capped: boolean; error: string | null };
      const fetchAllOutstandingInvoices = async (): Promise<InvoicesFetchResult> => {
        const all: InvoiceSummary[] = [];
        const MAX_PAGES = 200;
        let page = 1;
        // ACCREC == sales invoices (money owed TO us). Exclude ACCPAY (supplier bills).
        const where = encodeURIComponent('Type=="ACCREC"');
        while (page <= MAX_PAGES) {
          const params = `where=${where}&Statuses=AUTHORISED&summaryOnly=true&page=${page}`;
          const { status, data } = await withSlot(() => xeroGet('/api.xro/2.0/Invoices', acc, ten, params));
          if (status !== 200) {
            return { invoices: all, pages_fetched: page - 1, capped: false, error: `Invoices page ${page} returned ${status}: ${JSON.stringify(data).slice(0, 200)}` };
          }
          const list = ((data?.Invoices ?? []) as InvoiceSummary[]);
          all.push(...list);
          if (list.length < 100) {
            return { invoices: all, pages_fetched: page, capped: false, error: null };
          }
          page++;
        }
        return { invoices: all, pages_fetched: MAX_PAGES, capped: true, error: `Reached MAX_PAGES cap (${MAX_PAGES} pages = ${MAX_PAGES * 100} invoices) — totals may be understated` };
      };

      // Separate SUBMITTED (awaiting-approval) summary. Cheap because SUBMITTED
      // volume is always small for any healthy Xero. Surfaced as an amber side-note,
      // never included in headline Owed-to-You.
      type SubmittedSummary = { count: number; total: number; error: string | null };
      const fetchSubmittedSummary = async (): Promise<SubmittedSummary> => {
        const where = encodeURIComponent('Type=="ACCREC"');
        const params = `where=${where}&Statuses=SUBMITTED&summaryOnly=true&page=1`;
        const { status, data } = await withSlot(() => xeroGet('/api.xro/2.0/Invoices', acc, ten, params));
        if (status !== 200) return { count: 0, total: 0, error: `SUBMITTED summary returned ${status}` };
        const list = ((data?.Invoices ?? []) as InvoiceSummary[]);
        let count = 0, total = 0;
        for (const inv of list) {
          const due = parseNum(inv.AmountDue);
          if (due > 0) { count++; total += due; }
        }
        return { count, total, error: null };
      };

      // ── Build job list: 4 fixed P&L + per-month P&L (past + current only) ──
      // For May (monthIdx=4): 4 fixed + 5 per-month (Jan, Feb, Mar, Apr, May) = 9 P&L jobs.
      // Future months are skipped entirely (no point asking Xero for zeros).
      type MonthlyJob = { key: string; from: string; to: string };
      const monthlyJobs: MonthlyJob[] = [];
      for (let i = 0; i <= monthIdx; i++) {
        const start = firstOfMonth(year, i);
        const end   = lastOfMonth(year, i);
        monthlyJobs.push({ key: `${year}-${pad2(i + 1)}`, from: fmtDate(start), to: fmtDate(end) });
      }

      // Kick off everything in parallel — shared withSlot semaphore caps to 5 concurrent.
      const ytdP             = callPL(`fromDate=${yearStart}&toDate=${today}`);
      const ytdPriorP        = callPL(`fromDate=${year - 1}-01-01&toDate=${fmtDate(ytdPriorEnd)}`);
      const lastMonthCurP    = callPL(`fromDate=${fmtDate(lastMonthStart)}&toDate=${fmtDate(lastMonthEnd)}`);
      const lastMonthPriorP  = callPL(`fromDate=${fmtDate(lastMonthStartPrior)}&toDate=${fmtDate(lastMonthEndPrior)}`);
      const monthlyPs        = monthlyJobs.map((j) => callPL(`fromDate=${j.from}&toDate=${j.to}`));
      const invoicesP        = fetchAllOutstandingInvoices();
      const submittedP       = fetchSubmittedSummary();

      const [
        ytdRes,
        ytdPriorRes,
        lastMonthCurRes,
        lastMonthPriorRes,
        invoicesResSettled,
        submittedResSettled,
        ...monthlyResults
      ] = await Promise.allSettled([
        ytdP, ytdPriorP, lastMonthCurP, lastMonthPriorP, invoicesP, submittedP, ...monthlyPs,
      ]);

      // ── Parse the 4 fixed single-period P&L results ─────────────────
      const ytdParse           = parseSinglePL(ytdRes as PromiseSettledResult<{status:number;data:Record<string,unknown>}>,           'YTD');
      const ytdPriorParse      = parseSinglePL(ytdPriorRes as PromiseSettledResult<{status:number;data:Record<string,unknown>}>,      'YTD prior');
      const lastMonthParse     = parseSinglePL(lastMonthCurRes as PromiseSettledResult<{status:number;data:Record<string,unknown>}>,  'Last month current');
      const lastMonthPriorParse= parseSinglePL(lastMonthPriorRes as PromiseSettledResult<{status:number;data:Record<string,unknown>}>,'Last month prior');

      const ytdRevenue            = ytdParse.value;
      const ytdRevenuePrior       = ytdPriorParse.value;
      const lastMonthRevenue      = lastMonthParse.value;
      const lastMonthRevenuePrior = lastMonthPriorParse.value;
      const ytdYoyPct             = yoyPct(ytdRevenue, ytdRevenuePrior);
      const lastMonthYoyPct       = yoyPct(lastMonthRevenue, lastMonthRevenuePrior);

      const lastMonthLabel      = new Date(lastMonthY,     lastMonthMi, 1).toLocaleDateString('en-IE', { month: 'long', year: 'numeric' });
      const lastMonthLabelPrior = new Date(lastMonthY - 1, lastMonthMi, 1).toLocaleDateString('en-IE', { month: 'long', year: 'numeric' });

      // ── Parse per-month P&L results — same matcher as YTD, so guaranteed to reconcile ──
      const monthly: Record<string, number> = {};
      for (let i = 0; i < 12; i++) monthly[`${year}-${pad2(i + 1)}`] = 0;
      const perMonthDiag: Array<{ key: string; value: number }> = [];
      const monthlyErrors: Array<{ key: string; error: string }> = [];

      monthlyResults.forEach((res, i) => {
        const job = monthlyJobs[i];
        const parsed = parseSinglePL(res as PromiseSettledResult<{status:number;data:Record<string,unknown>}>, `Monthly ${job.key}`);
        monthly[job.key] = parsed.value;
        perMonthDiag.push({ key: job.key, value: parsed.value });
        if (parsed.error) monthlyErrors.push({ key: job.key, error: parsed.error });
      });

      // Sanity: sum(monthly past+current) should ≈ ytd_revenue. High confidence within 2%.
      const monthlySum = Object.values(monthly).reduce((s, v) => s + v, 0);
      let monthlyChartConfidence: 'high' | 'low' = 'high';
      if (ytdRevenue > 0) {
        const drift = Math.abs(monthlySum - ytdRevenue) / ytdRevenue;
        if (drift > 0.02) monthlyChartConfidence = 'low';
      } else if (monthlySum > 0) {
        // monthly has data but YTD doesn't — suspicious
        monthlyChartConfidence = 'low';
      }

      // ── Outstanding / Overdue / Aging buckets — single pass ──────────
      // All in one loop so overdue_total / overdue_count are DERIVED from buckets
      // (single source of truth — they can never disagree with the aging strip).
      type Bucket = { total: number; count: number };
      const aging: Record<'current'|'bucket_1_30'|'bucket_31_60'|'bucket_61_90'|'bucket_90_plus', Bucket> = {
        current:        { total: 0, count: 0 },
        bucket_1_30:    { total: 0, count: 0 },
        bucket_31_60:   { total: 0, count: 0 },
        bucket_61_90:   { total: 0, count: 0 },
        bucket_90_plus: { total: 0, count: 0 },
      };
      let outstandingTotal = 0;
      let invoicesError: string | null = null;
      let invoicesFetched = 0;
      let invoicesPagesFetched = 0;
      let invoicesCapped = false;
      const overdueSample: Array<{ id?: string; number?: string; due_iso?: string; amount: number; bucket: string }> = [];

      if (invoicesResSettled.status === 'fulfilled') {
        const r = invoicesResSettled.value as InvoicesFetchResult;
        invoicesError = r.error;
        invoicesFetched = r.invoices.length;
        invoicesPagesFetched = r.pages_fetched;
        invoicesCapped = r.capped;
        const todayDate = new Date(today + 'T00:00:00');
        const DAY_MS = 86_400_000;
        for (const inv of r.invoices) {
          const due = parseNum(inv.AmountDue);
          if (due <= 0) continue;
          outstandingTotal += due;
          const dueDate = parseXeroDate(inv.DueDate);
          if (!dueDate) {
            // No due date → treat as current (Xero allows null DueDate on early invoices).
            aging.current.total += due;
            aging.current.count += 1;
            continue;
          }
          const days = Math.floor((todayDate.getTime() - dueDate.getTime()) / DAY_MS);
          let key: keyof typeof aging;
          if      (days <= 0)  key = 'current';
          else if (days <= 30) key = 'bucket_1_30';
          else if (days <= 60) key = 'bucket_31_60';
          else if (days <= 90) key = 'bucket_61_90';
          else                 key = 'bucket_90_plus';
          aging[key].total += due;
          aging[key].count += 1;
          if (key !== 'current' && overdueSample.length < 3) {
            overdueSample.push({
              id: inv.InvoiceID,
              number: inv.InvoiceNumber,
              due_iso: dueDate.toISOString().split('T')[0],
              amount: due,
              bucket: key,
            });
          }
        }
      } else {
        invoicesError = `Invoices fetch failed: ${String(invoicesResSettled.reason).slice(0, 200)}`;
      }

      // Derive overdue from buckets — guarantees aging strip + KPI cards agree.
      const overdueTotal = aging.bucket_1_30.total + aging.bucket_31_60.total + aging.bucket_61_90.total + aging.bucket_90_plus.total;
      const overdueCount = aging.bucket_1_30.count + aging.bucket_31_60.count + aging.bucket_61_90.count + aging.bucket_90_plus.count;

      // SUBMITTED summary (drafts awaiting approval — not part of headline Owed)
      let submittedCount = 0;
      let submittedTotal = 0;
      let submittedError: string | null = null;
      if (submittedResSettled.status === 'fulfilled') {
        const s = submittedResSettled.value as SubmittedSummary;
        submittedCount = s.count;
        submittedTotal = s.total;
        submittedError = s.error;
      } else {
        submittedError = `SUBMITTED fetch failed: ${String(submittedResSettled.reason).slice(0, 200)}`;
      }

      console.log('[xero-oauth] overview_metrics:', JSON.stringify({
        ef_version: EF_VERSION,
        ytdRevenue, ytdRevenuePrior, ytdYoyPct,
        lastMonthRevenue, lastMonthRevenuePrior, lastMonthYoyPct,
        monthlySum, monthlyChartConfidence, monthlyJobsRun: monthlyJobs.length,
        outstandingTotal, overdueTotal, overdueCount, invoicesFetched, invoicesPagesFetched, invoicesCapped, invoicesError,
      }).slice(0, 2000));

      return json({
        ytd_revenue:              ytdRevenue,
        ytd_revenue_prior:        ytdRevenuePrior,
        ytd_yoy_pct:              ytdYoyPct,
        last_month_revenue:       lastMonthRevenue,
        last_month_revenue_prior: lastMonthRevenuePrior,
        last_month_yoy_pct:       lastMonthYoyPct,
        last_month_label:         lastMonthLabel,
        last_month_label_prior:   lastMonthLabelPrior,
        monthly,
        monthly_chart_confidence: monthlyChartConfidence,
        outstanding_total:        outstandingTotal,
        overdue_total:            overdueTotal,
        overdue_count:            overdueCount,
        aging,                    // NEW: 5 aging buckets, each { total, count }
        submitted_count:          submittedCount,
        submitted_total:          submittedTotal,
        invoices_capped:          invoicesCapped,
        generated_at:             now.toISOString(),
        _diagnostic: {
          ef_version: EF_VERSION,
          pl_ytd:              ytdParse,
          pl_ytd_prior:        ytdPriorParse,
          pl_last_month:       lastMonthParse,
          pl_last_month_prior: lastMonthPriorParse,
          pl_monthly: {
            per_month:         perMonthDiag,
            sum:               monthlySum,
            chart_confidence:  monthlyChartConfidence,
            errors:            monthlyErrors.length ? monthlyErrors : null,
          },
          invoices_summary: {
            type_filter:       'ACCREC',
            statuses_included: 'AUTHORISED',
            count_fetched:     invoicesFetched,
            pages_fetched:     invoicesPagesFetched,
            capped:            invoicesCapped,
            outstanding_total: outstandingTotal,
            overdue_total:     overdueTotal,
            overdue_count:     overdueCount,
            submitted_count:   submittedCount,
            submitted_total:   submittedTotal,
            submitted_error:   submittedError,
            aging,
            overdue_sample:    overdueSample,
            error:             invoicesError,
          },
        },
      });
    }

    // ── overview_top_customer ─────────────────────────────────────────────────
    // Slow, paginated fetch of all customer invoices issued YTD, aggregated by
    // contact to find the customer who's billed the most this year. Runs as a
    // SEPARATE action so the main overview_metrics call returns instantly and
    // the UI can render with last-known cached value while this catches up.
    // Hard-capped at 200 pages (20,000 invoices) to prevent runaway.
    if (action === 'overview_top_customer') {
      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error });

      const tStart = Date.now();
      const now = new Date();
      const year = now.getFullYear();
      const acc  = refreshResult.accessToken!;
      const ten  = refreshResult.tenantId!;

      type ContactRef = { ContactID?: string; Name?: string };
      type InvoiceSummary = { Type?: string; Status?: string; Contact?: ContactRef; Total?: number; Date?: string };

      const MAX_PAGES = 200;
      const where = encodeURIComponent(`Type=="ACCREC" AND Date >= DateTime(${year},01,01)`);
      const totalsByContact = new Map<string, { name: string; total: number; invoice_count: number }>();
      let pagesFetched = 0;
      let invoicesSeen = 0;
      let capped = false;
      let error: string | null = null;
      let grossTotal = 0;

      for (let page = 1; page <= MAX_PAGES; page++) {
        const params = `where=${where}&summaryOnly=true&page=${page}`;
        const { status, data } = await xeroGet('/api.xro/2.0/Invoices', acc, ten, params);
        pagesFetched = page;
        if (status !== 200) {
          error = `Page ${page} returned ${status}: ${JSON.stringify(data).slice(0, 200)}`;
          break;
        }
        const list = ((data?.Invoices ?? []) as InvoiceSummary[]);
        invoicesSeen += list.length;
        for (const inv of list) {
          if (inv.Status === 'VOIDED' || inv.Status === 'DELETED') continue;
          const total = typeof inv.Total === 'number' ? inv.Total : Number(inv.Total) || 0;
          if (!isFinite(total) || total <= 0) continue;
          const cid  = inv.Contact?.ContactID;
          const name = (inv.Contact?.Name ?? '').trim();
          if (!cid) continue;
          grossTotal += total;
          const existing = totalsByContact.get(cid);
          if (existing) {
            existing.total += total;
            existing.invoice_count += 1;
            if (!existing.name && name) existing.name = name;
          } else {
            totalsByContact.set(cid, { name: name || '(unnamed contact)', total, invoice_count: 1 });
          }
        }
        if (list.length < 100) break;
        if (page === MAX_PAGES) capped = true;
      }

      const ranked = Array.from(totalsByContact.entries())
        .map(([contact_id, v]) => ({ contact_id, name: v.name, total: Math.round(v.total * 100) / 100, invoice_count: v.invoice_count }))
        .sort((a, b) => b.total - a.total);

      const fetch_ms = Date.now() - tStart;

      console.log('[xero-oauth] overview_top_customer:', JSON.stringify({
        pages_fetched: pagesFetched,
        invoices_seen: invoicesSeen,
        contacts:      totalsByContact.size,
        capped, fetch_ms, error,
        top:           ranked[0] ?? null,
      }).slice(0, 1000));

      return json({
        top_customer:         ranked[0] ?? null,
        ytd_revenue_estimate: Math.round(grossTotal * 100) / 100,
        top_5_for_diag:       ranked.slice(0, 5),
        meta: {
          pages_fetched: pagesFetched,
          invoices_seen: invoicesSeen,
          contacts:      totalsByContact.size,
          capped,
          fetch_ms,
          error,
        },
        generated_at: now.toISOString(),
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

    // ── push_job_invoice ──────────────────────────────────────────────────────
    // Pushes a production-job invoice to Xero as a DRAFT and records the
    // as-billed snapshot to job_invoice_lines + jobs.xero_invoice_id.
    //
    // Safety stack (read top-to-bottom):
    //   1. Role gate (FINANCE_ROLES only — covered by the handler-level gate)
    //   2. SELECT ... FOR UPDATE on jobs.xero_invoice_id — early-returns
    //      { already_pushed: true } if a prior push already succeeded. Kills
    //      both retry-after-orphan and double-click race in one shot.
    //   3. Idempotency-Key: pulse-{job_id} header on the Xero POST — defence
    //      in depth: even if step 2 is somehow bypassed, Xero de-duplicates
    //      identical-key requests for 24h.
    //   4. job_invoice_record_push RPC — wraps line snapshot + jobs update
    //      in a single transaction so we can't end up with snapshot but no
    //      jobs.xero_invoice_id (or vice versa).
    //   5. partial_persist flag — if RPC fails AFTER Xero accepted, surface
    //      the InvoiceID to the UI + log structured payload for recovery.
    if (action === 'push_job_invoice') {
      const EF_VERSION = '2026-05-17-jobs-to-invoice-v1';

      type IncomingLine = {
        description?: string;
        quantity?: number | string;
        unit_price?: number | string;
        account_code?: string;
        tax_type?: string;
        line_type?: string;
        xero_account_key?: string;
      };
      const jobId            = String(body.job_id      ?? '').trim();
      const contactId        = String(body.contact_id  ?? '').trim();
      const reference        = String(body.reference   ?? '').trim();
      const dateIn           = String(body.date        ?? '').trim();
      const paymentTermsDays = Number(body.payment_terms_days ?? 30) || 30;
      const linesIn          = Array.isArray(body.lines) ? (body.lines as IncomingLine[]) : [];

      if (!jobId)     return err('job_id is required', 400);
      if (!contactId) return err('contact_id is required', 400);
      if (!linesIn.length) return err('At least one line item is required', 400);

      // Step 2: double-push guard — read existing xero_invoice_id under
      // a row lock so concurrent calls can't both push. The "FOR UPDATE"
      // semantics live inside the dedicated RPC below; here we do a plain
      // select first because the most common path is a fast bail-out.
      const { data: existingJob, error: jobReadErr } = await adminClient
        .from('jobs')
        .select('id, xero_invoice_id, xero_invoice_number')
        .eq('id', jobId)
        .maybeSingle();
      if (jobReadErr || !existingJob) return err('Job not found', 404);
      if (existingJob.xero_invoice_id) {
        const deep = `https://go.xero.com/AccountsReceivable/Edit.aspx?invoiceID=${existingJob.xero_invoice_id}`;
        return json({
          already_pushed:  true,
          invoice_id:      existingJob.xero_invoice_id,
          invoice_number:  existingJob.xero_invoice_number ?? null,
          deep_link:       deep,
        });
      }

      // Validate every line has the bare minimum to be sent.
      const cleanedLines = linesIn
        .map((l, i): { idx: number; description: string; quantity: number; unit_price: number; account_code: string; tax_type: string; line_type: string; xero_account_key: string } | null => {
          const q  = Number(l.quantity);
          const up = Number(l.unit_price);
          if (!Number.isFinite(q) || !Number.isFinite(up)) return null;
          if (q * up <= 0) return null; // skip zero lines silently
          const ac = String(l.account_code ?? '').trim();
          if (!ac) {
            // Bubble up via outer reduce by throwing — caught below.
            throw new Error(`Line ${i + 1} is missing an account code`);
          }
          return {
            idx:              i,
            description:      String(l.description ?? '').trim() || '(no description)',
            quantity:         q,
            unit_price:       up,
            account_code:     ac,
            tax_type:         String(l.tax_type ?? '').trim(),
            line_type:        String(l.line_type ?? '').trim(),
            xero_account_key: String(l.xero_account_key ?? '').trim(),
          };
        })
        .filter((x): x is NonNullable<typeof x> => x !== null);

      if (!cleanedLines.length) {
        return err('All line items are zero — nothing to invoice', 400);
      }

      const { clientId, clientSecret } = await getXeroCreds(adminClient);
      if (!clientId || !clientSecret) return err('Xero credentials not configured', 400);
      const refreshResult = await refreshConnectionIfNeeded(adminClient, clientId, clientSecret);
      if (!refreshResult.ok) return json({ error: refreshResult.error || 'reconnect_required' }, 400);

      // Compute Date / DueDate
      const today = new Date();
      const isoDate = (d: Date) => d.toISOString().split('T')[0];
      const date = dateIn || isoDate(today);
      const dueDateObj = new Date(date + 'T00:00:00');
      dueDateObj.setDate(dueDateObj.getDate() + paymentTermsDays);
      const dueDate = isoDate(dueDateObj);

      // Build Xero payload
      const xeroPayload = {
        Invoices: [{
          Type:         'ACCREC',
          Status:       'DRAFT',
          Contact:      { ContactID: contactId },
          Date:         date,
          DueDate:      dueDate,
          Reference:    reference || `Job ${jobId}`,
          CurrencyCode: 'EUR',
          LineItems:    cleanedLines.map((l) => ({
            Description: l.description,
            Quantity:    l.quantity,
            UnitAmount:  l.unit_price,
            AccountCode: l.account_code,
            TaxType:     l.tax_type || undefined,
          })),
        }],
      };

      // Step 3: Idempotency-Key — Xero dedupes identical-keyed requests for 24h.
      const idempKey = `pulse-${jobId}`;
      const postUrl = `${XERO_API}/api.xro/2.0/Invoices`;
      console.log(`[xero-oauth] push_job_invoice POST ${postUrl} job=${jobId} lines=${cleanedLines.length} idempKey=${idempKey} ef=${EF_VERSION}`);
      const xeroRes = await fetch(postUrl, {
        method: 'POST',
        headers: {
          Authorization:     `Bearer ${refreshResult.accessToken}`,
          'Xero-tenant-id':  refreshResult.tenantId!,
          'Content-Type':    'application/json',
          'Accept':          'application/json',
          'Idempotency-Key': idempKey,
        },
        body: JSON.stringify(xeroPayload),
      });
      let xeroBody: Record<string, unknown> = {};
      try { xeroBody = await xeroRes.json(); } catch { xeroBody = {}; }
      console.log(`[xero-oauth] push_job_invoice response status=${xeroRes.status} body=${JSON.stringify(xeroBody).slice(0, 600)}`);

      if (xeroRes.status !== 200) {
        // Pull the first validation message out of Xero's nested shape.
        let xeroMsg = '';
        const elements = (xeroBody as { Elements?: Array<Record<string, unknown>> })?.Elements;
        if (Array.isArray(elements) && elements.length) {
          const ve = (elements[0] as { ValidationErrors?: Array<{ Message?: string }> })?.ValidationErrors;
          if (Array.isArray(ve) && ve.length) xeroMsg = ve.map((v) => v?.Message ?? '').filter(Boolean).join('; ');
        }
        if (!xeroMsg) {
          xeroMsg = String((xeroBody as { Message?: string })?.Message ?? `Xero returned ${xeroRes.status}`);
        }
        return json({ error: `Xero rejected the invoice: ${xeroMsg}` }, 400);
      }

      const createdInvoice = ((xeroBody as { Invoices?: Array<Record<string, unknown>> })?.Invoices ?? [])[0] ?? {};
      const invoiceId     = String(createdInvoice.InvoiceID     ?? '');
      const invoiceNumber = String(createdInvoice.InvoiceNumber ?? '');
      const deepLink      = invoiceId ? `https://go.xero.com/AccountsReceivable/Edit.aspx?invoiceID=${invoiceId}` : '';

      if (!invoiceId) {
        console.error('[xero-oauth] push_job_invoice: Xero returned 200 but no InvoiceID', JSON.stringify(xeroBody).slice(0, 400));
        return err('Xero accepted the request but returned no InvoiceID', 500);
      }

      // Step 4: snapshot + jobs update via RPC (atomic).
      const rpcPayload = cleanedLines.map((l, idx) => ({
        line_type:         l.line_type,
        description:       l.description,
        quantity:          l.quantity,
        unit_price:        l.unit_price,
        xero_account_key:  l.xero_account_key,
        xero_account_code: l.account_code,
        xero_tax_type:     l.tax_type,
        position:          idx,
      }));
      const { error: rpcErr } = await adminClient.rpc('job_invoice_record_push', {
        p_job_id:         jobId,
        p_invoice_id:     invoiceId,
        p_invoice_number: invoiceNumber,
        p_lines:          rpcPayload,
      });

      if (rpcErr) {
        // Step 5: partial-persist path. Xero accepted but we couldn't record it.
        // Structured log so the operator can recover from EF logs.
        console.error('[xero-oauth] pulse_push_partial_failure', JSON.stringify({
          event:          'pulse_push_partial_failure',
          job_id:         jobId,
          invoice_id:     invoiceId,
          invoice_number: invoiceNumber,
          rpc_error:      rpcErr.message,
          lines:          rpcPayload,
        }));
        return json({
          ok:               true,
          partial_persist:  true,
          invoice_id:       invoiceId,
          invoice_number:   invoiceNumber,
          deep_link:        deepLink,
          warning:          `Xero accepted invoice ${invoiceNumber || invoiceId} but Pulse could not record it (${rpcErr.message}). Paste InvoiceID ${invoiceId} onto the job manually.`,
        });
      }

      return json({
        ok:             true,
        invoice_id:     invoiceId,
        invoice_number: invoiceNumber,
        deep_link:      deepLink,
      });
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
