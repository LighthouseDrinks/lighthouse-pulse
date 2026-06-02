// roles-admin — Supabase Edge Function
//
// Manages writes to the `roles` table for the Settings → Roles UI.
// Reads go through PostgREST directly (RLS allows SELECT to all
// authenticated users); writes are gated here so we can enforce
// is_pulse_admin and the safety rails (cannot delete a role with
// users; cannot delete is_system without confirmation).
//
// Deploy: supabase functions deploy roles-admin
// No external secrets required (uses the runtime SUPABASE_SERVICE_ROLE_KEY).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function err(message: string, status = 400, extra: Record<string, unknown> = {}): Response {
  return json({ error: message, ...extra }, status);
}

// snake_case validation: lowercase letters/digits/underscores, must
// start with a letter, 2..64 chars. Mirrors the front-end validator.
const KEY_RE = /^[a-z][a-z0-9_]{1,63}$/;

// Tier-flag column names. Anything else in the `tier_flags` payload
// is silently dropped — protects against a stale UI shipping unknown
// keys to the DB.
const TIER_FLAGS = new Set([
  'is_pulse_admin', 'is_exec', 'is_hr_admin', 'is_client_editor',
  'is_broadcast_initiator', 'has_finance_access', 'has_finance_creds',
  'has_stock_view', 'notify_on_client_submission', 'is_manager',
]);

const SB_GROUP_VALUES = new Set(['all', 'management', 'production', 'ecom']);

interface RolePayload {
  key?: string;
  label?: string;
  short_label?: string;
  sort_order?: number;
  tier_flags?: Record<string, boolean>;
  sb_groups?: string[];
  permissions?: Record<string, number | boolean>;
}

function sanitisePayload(p: RolePayload, isCreate: boolean): {
  ok: true; row: Record<string, unknown>;
} | { ok: false; reason: string } {
  const row: Record<string, unknown> = {};
  if (isCreate) {
    if (typeof p.key !== 'string' || !KEY_RE.test(p.key)) {
      return { ok: false, reason: 'Invalid key. Use snake_case, 2–64 chars, starting with a letter.' };
    }
    row.key = p.key;
  }
  if (typeof p.label === 'string') {
    const trimmed = p.label.trim();
    if (!trimmed) return { ok: false, reason: 'Label is required.' };
    row.label = trimmed;
  } else if (isCreate) {
    return { ok: false, reason: 'Label is required.' };
  }
  if (typeof p.short_label === 'string') {
    const trimmed = p.short_label.trim();
    if (!trimmed) return { ok: false, reason: 'Short label is required.' };
    if (trimmed.length > 16) return { ok: false, reason: 'Short label must be 16 characters or fewer.' };
    row.short_label = trimmed;
  } else if (isCreate) {
    return { ok: false, reason: 'Short label is required.' };
  }
  if (typeof p.sort_order === 'number' && Number.isFinite(p.sort_order)) {
    row.sort_order = Math.round(p.sort_order);
  }
  if (p.tier_flags && typeof p.tier_flags === 'object') {
    for (const [k, v] of Object.entries(p.tier_flags)) {
      if (TIER_FLAGS.has(k)) row[k] = !!v;
    }
  }
  if (Array.isArray(p.sb_groups)) {
    const cleaned = p.sb_groups.filter(g => typeof g === 'string' && SB_GROUP_VALUES.has(g));
    // Always include 'all' so broadcast-to-all addresses every role.
    if (!cleaned.includes('all')) cleaned.push('all');
    row.sb_groups = cleaned;
  }
  if (p.permissions && typeof p.permissions === 'object') {
    // Coerce to 0/1 ints to match the existing matrix payload shape.
    const coerced: Record<string, number> = {};
    for (const [k, v] of Object.entries(p.permissions)) {
      coerced[k] = v ? 1 : 0;
    }
    row.permissions = coerced;
  }
  return { ok: true, row };
}

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

    // Resolve the caller's role via app_users → roles, and require
    // is_pulse_admin. We deliberately re-check on every request even
    // though RLS would also reject non-admins (defence in depth, and
    // cleaner error messages than a 403 with no body). Also require
    // status='active' so terminated admins can't call this function.
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role, status')
      .eq('auth_user_id', user.id)
      .single();
    if (!appUser || appUser.status !== 'active') return err('Forbidden', 403);

    const { data: callerRole } = await adminClient
      .from('roles')
      .select('is_pulse_admin')
      .eq('key', appUser.role)
      .maybeSingle();
    if (!callerRole?.is_pulse_admin) {
      return err('Forbidden — Pulse admins only', 403);
    }

    const body   = await req.json() as Record<string, unknown>;
    const action = body.action as string;

    // ── create ────────────────────────────────────────────────
    if (action === 'create') {
      const payload = (body.role || {}) as RolePayload;
      const sanitised = sanitisePayload(payload, true);
      if (!sanitised.ok) return err(sanitised.reason, 400);

      // Reject duplicate keys with a friendly error rather than the
      // generic Postgres unique-violation surface.
      const { data: existing } = await adminClient
        .from('roles')
        .select('key')
        .eq('key', payload.key as string)
        .maybeSingle();
      if (existing) {
        return err('A role with that key already exists.', 409);
      }

      // New roles are never is_system — that flag is reserved for the
      // 12 seeded ones. Cannot be promoted via this endpoint.
      sanitised.row.is_system = false;

      const { data: inserted, error: insErr } = await adminClient
        .from('roles')
        .insert(sanitised.row)
        .select()
        .single();
      if (insErr) return err(insErr.message, 500);
      return json({ ok: true, role: inserted });
    }

    // ── update ────────────────────────────────────────────────
    if (action === 'update') {
      const key = (body.key as string) || '';
      if (!key) return err('key is required', 400);
      const payload = (body.role || {}) as RolePayload;
      const sanitised = sanitisePayload(payload, false);
      if (!sanitised.ok) return err(sanitised.reason, 400);

      // Never allow flipping is_system from this endpoint.
      delete (sanitised.row as Record<string, unknown>).is_system;
      delete (sanitised.row as Record<string, unknown>).key;

      const { data: updated, error: updErr } = await adminClient
        .from('roles')
        .update(sanitised.row)
        .eq('key', key)
        .select()
        .maybeSingle();
      if (updErr) return err(updErr.message, 500);
      if (!updated) return err('Role not found.', 404);
      return json({ ok: true, role: updated });
    }

    // ── delete ────────────────────────────────────────────────
    if (action === 'delete') {
      const key = (body.key as string) || '';
      const confirmKey = (body.confirm_key as string) || '';
      if (!key) return err('key is required', 400);

      const { data: target } = await adminClient
        .from('roles')
        .select('key, is_system')
        .eq('key', key)
        .maybeSingle();
      if (!target) return err('Role not found.', 404);

      // Block deleting a role that has users assigned. The FK would
      // also block (ON DELETE RESTRICT), but a structured response
      // lets the UI render a "reassign N users first" message.
      const { count: userCount } = await adminClient
        .from('app_users')
        .select('id', { count: 'exact', head: true })
        .eq('role', key);
      if ((userCount ?? 0) > 0) {
        return err(
          `Cannot delete: ${userCount} user${userCount === 1 ? '' : 's'} assigned to this role. Reassign first.`,
          409,
          { user_count: userCount },
        );
      }

      // For is_system roles, require the caller to type the key as a
      // confirmation. Belt-and-braces — the UI also gates this.
      if (target.is_system && confirmKey !== key) {
        return err('Confirm by typing the role key.', 400, { requires_confirm: true });
      }

      const { error: delErr } = await adminClient
        .from('roles')
        .delete()
        .eq('key', key);
      if (delErr) return err(delErr.message, 500);
      return json({ ok: true });
    }

    return err(`Unknown action: ${action}`, 400);
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    return err(message, 500);
  }
});
