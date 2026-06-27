// swift-function — email relay (Resend) + admin user deletion.
//
// Hardening (Phase 1, findings C-5):
//   * delete_user now requires a valid JWT belonging to a STAFF user
//     (verified via /auth/v1/user + app_users role lookup). Previously it
//     ran with no auth, so anyone could delete any auth user.
//   * The email path prefers RESEND_API_KEY from the function environment
//     and only falls back to a request-supplied key for backward compat.
//     Set RESEND_API_KEY as a function secret so the key never has to be
//     held client-side (it also makes portal email notifications work
//     without exposing the key to client sessions).
//
// NOTE: the email path is intentionally still callable without a user JWT
// because the public magic-link approval pages send notifications as the
// anon role. Requiring auth there would break those flows. Once
// RESEND_API_KEY is set in the environment, no secret is accepted from the
// browser regardless of caller.

const PROJECT_URL = 'https://anhawgzgxoywophqbmji.supabase.co';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'POST'
};

function json(bodyObj: unknown, status = 200) {
  return new Response(JSON.stringify(bodyObj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS }
  });
}

// Resolve the caller's auth user from the Authorization bearer token.
// Returns the user object (with .id) or null if the token is missing/invalid.
async function getCaller(req: Request, serviceKey: string) {
  const auth = req.headers.get('Authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  // Reject obvious non-JWTs (e.g. the publishable/anon key) cheaply.
  if (!token || token.split('.').length !== 3) return null;
  try {
    const r = await fetch(`${PROJECT_URL}/auth/v1/user`, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${token}` }
    });
    if (!r.ok) return null;
    return await r.json();
  } catch (_) {
    return null;
  }
}

async function callerIsStaff(userId: string, serviceKey: string): Promise<boolean> {
  try {
    const r = await fetch(
      `${PROJECT_URL}/rest/v1/app_users?auth_user_id=eq.${userId}&select=role,status`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } }
    );
    if (!r.ok) return false;
    const rows = await r.json();
    const row = Array.isArray(rows) ? rows[0] : null;
    return !!row && row.status === 'active' && row.role && row.role !== 'client';
  } catch (_) {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const body = await req.json();
  const serviceKey = Deno.env.get('SERVICE_ROLE_KEY') || '';

  // ── Delete auth user (staff only) ─────────────────────────────────
  if (body.action === 'delete_user') {
    if (!serviceKey) return json({ error: 'Not configured' }, 500);
    const caller = await getCaller(req, serviceKey);
    if (!caller?.id) return json({ error: 'Unauthorized' }, 401);
    if (!(await callerIsStaff(caller.id, serviceKey))) {
      return json({ error: 'Forbidden' }, 403);
    }
    const userId = body.user_id;
    if (!userId) return json({ error: 'Missing params' }, 400);
    const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${userId}`, {
      method: 'DELETE',
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` }
    });
    return json({ ok: res.ok, status: res.status }, res.ok ? 200 : 400);
  }

  // ── Send email ────────────────────────────────────────────────────
  const { to, subject, html, from, resendKey, attachments, cc, bcc, reply_to } = body;
  // Prefer the server-held key; only fall back to a client-supplied key
  // when the environment key is not configured.
  const effectiveKey = Deno.env.get('RESEND_API_KEY') || resendKey;
  if (!effectiveKey) return json({ error: 'No Resend API key configured' }, 400);

  const payload: Record<string, unknown> = { to, subject, html, from };
  if (cc) payload.cc = cc;
  if (bcc) payload.bcc = bcc;
  if (reply_to) payload.reply_to = reply_to;
  if (Array.isArray(attachments) && attachments.length) {
    payload.attachments = attachments.map((a) => ({
      filename: a.filename,
      content: a.content,
      content_type: a.content_type || a.type
    }));
  }
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${effectiveKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const data = await res.json();
  return json(data, res.status);
});
