// org-chart — Supabase Edge Function
//
// Handles writes for the Org Chart page. Reads go through PostgREST directly
// (RLS allows SELECT on app_users to all staff); the manager-reassignment
// write is gated here so we can enforce is_exec (MD/OD) and prevent cycles —
// app_users UPDATE is otherwise open to any staff under RLS.
//
// Keeps hr_profiles.reports_to in sync with app_users.reports_to_id so the HR
// module (reviews, leave approvals) and the org chart never drift apart.
//
// Deploy: supabase functions deploy org-chart
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

interface UserRow { id: string; reports_to_id: string | null; }

// Walk the reporting tree down from `rootId`. Returns true if `candidateId`
// sits anywhere in that subtree — i.e. making it the new manager of `rootId`
// would create a cycle.
function isDescendant(rows: UserRow[], rootId: string, candidateId: string): boolean {
  const children = new Map<string, string[]>();
  for (const r of rows) {
    if (r.reports_to_id) {
      const arr = children.get(r.reports_to_id) ?? [];
      arr.push(r.id);
      children.set(r.reports_to_id, arr);
    }
  }
  const stack = [...(children.get(rootId) ?? [])];
  const seen = new Set<string>();
  while (stack.length) {
    const cur = stack.pop()!;
    if (cur === candidateId) return true;
    if (seen.has(cur)) continue;
    seen.add(cur);
    for (const kid of children.get(cur) ?? []) stack.push(kid);
  }
  return false;
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

    // Resolve the caller and require an active exec (is_exec) — mirrors the
    // roles-admin gate. Defence in depth: RLS would let any staff PATCH
    // app_users, so the exec check MUST live here.
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role, status')
      .eq('auth_user_id', user.id)
      .single();
    if (!appUser || appUser.status !== 'active') return err('Forbidden', 403);

    const { data: callerRole } = await adminClient
      .from('roles')
      .select('is_exec')
      .eq('key', appUser.role)
      .maybeSingle();
    if (!callerRole?.is_exec) {
      return err('Forbidden — executives only', 403);
    }

    const body   = await req.json() as Record<string, unknown>;
    const action = body.action as string;

    // ── set_manager ────────────────────────────────────────────
    if (action === 'set_manager') {
      const userId    = (body.user_id as string) || '';
      const managerId = (body.manager_id as string | null) ?? null;
      if (!userId) return err('user_id is required', 400);
      if (managerId && managerId === userId) {
        return err('A person cannot report to themselves.', 400);
      }

      // Load the flat tree once for existence + cycle checks.
      const { data: allRows, error: readErr } = await adminClient
        .from('app_users')
        .select('id, reports_to_id');
      if (readErr) return err(readErr.message, 500);
      const rows = (allRows ?? []) as UserRow[];

      if (!rows.some(r => r.id === userId)) return err('User not found.', 404);
      if (managerId) {
        if (!rows.some(r => r.id === managerId)) return err('Manager not found.', 404);
        if (isDescendant(rows, userId, managerId)) {
          return err('That manager reports to this person — it would create a loop.', 409);
        }
      }

      const { error: updErr } = await adminClient
        .from('app_users')
        .update({ reports_to_id: managerId })
        .eq('id', userId);
      if (updErr) return err(updErr.message, 500);

      // Keep hr_profiles.reports_to aligned when a profile exists. Non-fatal:
      // the chart's source of truth is app_users, so we don't fail the request
      // if the HR row is missing or the write is a no-op.
      const { data: prof } = await adminClient
        .from('hr_profiles')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();
      if (prof) {
        await adminClient
          .from('hr_profiles')
          .update({ reports_to: managerId })
          .eq('user_id', userId);
      }

      return json({ ok: true, user_id: userId, manager_id: managerId });
    }

    return err(`Unknown action: ${action}`, 400);
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    return err(message, 500);
  }
});
