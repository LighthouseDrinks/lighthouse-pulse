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
    },
  });
  const data = await res.json();
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
      const scope        = 'openid profile email accounting.transactions accounting.contacts accounting.settings offline_access';
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
    if (action === 'disconnect') {
      // Get access token for revocation (best-effort)
      const { data: conn } = await adminClient
        .from('xero_connection')
        .select('access_token, refresh_token')
        .eq('is_active', true)
        .maybeSingle();

      await adminClient
        .from('xero_connection')
        .update({ is_active: false, disconnected_at: new Date().toISOString() })
        .eq('is_active', true);

      // Best-effort revocation — ignore errors
      if (conn?.refresh_token) {
        const { clientId, clientSecret } = await getXeroCreds(adminClient);
        if (clientId && clientSecret) {
          const revokeUrl = XERO_REVOKE_URL;
          console.log('[xero-oauth] request: POST', revokeUrl);
          const rRes = await fetch(revokeUrl, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              Authorization: basicAuth(clientId, clientSecret),
            },
            body: new URLSearchParams({ token: conn.refresh_token }).toString(),
          }).catch(() => null);
          console.log('[xero-oauth] response:', rRes?.status ?? 'error', '(revocation, best-effort)');
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

      const allContacts: unknown[] = [];
      let page = 1;
      while (true) {
        const params = `where=ContactStatus%3D%3D%22ACTIVE%22&pageSize=100&page=${page}`;
        const { status, data } = await xeroGet('/api.xro/2.0/Contacts', refreshResult.accessToken!, refreshResult.tenantId!, params);
        if (status !== 200) return err('Xero API error', 400);
        const contacts = data?.Contacts ?? [];
        allContacts.push(...contacts);
        if (contacts.length < 100) break;
        page++;
      }

      const simplified = (allContacts as Array<Record<string, unknown>>).map((c) => ({
        ContactID:    c.ContactID,
        Name:         c.Name,
        EmailAddress: c.EmailAddress,
      }));
      return json({ contacts: simplified });
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
