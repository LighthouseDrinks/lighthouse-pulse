// meeting-rooms — Supabase Edge Function (Pulse on Pulse / Meetings Hub)
//
// One-way Google Calendar feed for the two meeting-room resource calendars
// (CBW Main Office + CBW Warehouse 4). Reads bookings via a service account
// with domain-wide delegation (calendar.readonly), normalises them, upserts
// `meetings` + `meeting_attendees` (service role) so RLS data exists before
// anyone edits, and returns a view filtered by the caller's attendance.
//
// SECURITY (P0) — deliberately NOT the swift-function pattern:
//   * verify_jwt is enabled at deploy time AND the caller's JWT is verified
//     here; only active staff (app_users.status='active') get data.
//   * No secrets are ever accepted from the request — Google creds come only
//     from env (GOOGLE_SA_CLIENT_EMAIL, GOOGLE_SA_PRIVATE_KEY,
//     GOOGLE_IMPERSONATE_SUBJECT, ROOM1_CAL_ID, ROOM2_CAL_ID).
//   * Non-attendees receive title + time + room only (no agenda/attendees);
//     full per-meeting content is additionally protected by RLS.
//
// Deploy: supabase functions deploy meeting-rooms
//
// Request (GET or POST): { timeMin?: ISO, timeMax?: ISO }
//   Defaults to [now-1d, now+14d].
// Response: { ok, degraded?, message?, rooms, events: [...], me, is_admin }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ── CORS: reflect the caller's Origin (the real gate is the JWT) ─────
function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') || '*';
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Vary': 'Origin',
  };
}
function json(req: Request, data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
  });
}

// ── Google service-account auth (RS256 JWT → access token) ───────────
function b64url(input: string): string {
  return btoa(input).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlBytes(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

// Module-scope token cache (warm container reuse).
let _googleToken: { token: string; exp: number } | null = null;

async function getGoogleToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_googleToken && _googleToken.exp - 60 > now) return _googleToken.token;

  const clientEmail = Deno.env.get('GOOGLE_SA_CLIENT_EMAIL');
  let privateKey = Deno.env.get('GOOGLE_SA_PRIVATE_KEY');
  const subject = Deno.env.get('GOOGLE_IMPERSONATE_SUBJECT');
  if (!clientEmail || !privateKey || !subject) {
    throw new Error('Google service-account secrets are not configured');
  }
  // Secrets pasted via the dashboard may contain literal "\n".
  privateKey = privateKey.replace(/\\n/g, '\n');

  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: clientEmail,
    sub: subject,
    scope: 'https://www.googleapis.com/auth/calendar.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(privateKey),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${b64urlBytes(new Uint8Array(sig))}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) {
    throw new Error(`Google token error: ${JSON.stringify(data)}`);
  }
  _googleToken = { token: data.access_token, exp: now + (data.expires_in || 3600) };
  return _googleToken.token;
}

interface NormAttendee {
  email: string;
  display_name: string | null;
  response_status: string | null;
  is_organizer: boolean;
}
interface NormEvent {
  google_event_id: string;
  google_recurring_id: string | null;
  title: string;
  starts_at: string | null;
  ends_at: string | null;
  location: string | null;
  room_cal_id: string;
  room_label: string;
  status: string;
  attendees: NormAttendee[];
}

async function listRoom(token: string, calId: string, roomLabel: string, timeMin: string, timeMax: string): Promise<NormEvent[]> {
  const url = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calId)}/events`);
  url.searchParams.set('singleEvents', 'true');
  url.searchParams.set('orderBy', 'startTime');
  url.searchParams.set('timeMin', timeMin);
  url.searchParams.set('timeMax', timeMax);
  url.searchParams.set('maxResults', '250');
  url.searchParams.set('showDeleted', 'false');

  const res = await fetch(url.toString(), { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  if (!res.ok) throw new Error(`Calendar list error (${roomLabel}): ${JSON.stringify(data)}`);

  return (data.items || []).map((ev: Record<string, any>): NormEvent => {
    const attendees: NormAttendee[] = (ev.attendees || [])
      .filter((a: any) => a.email && !a.resource) // drop the room resource itself
      .map((a: any) => ({
        email: String(a.email).toLowerCase().trim(),
        display_name: a.displayName || null,
        response_status: a.responseStatus || null,
        is_organizer: !!a.organizer,
      }));
    // Ensure the organiser is represented as an attendee for access purposes.
    const orgEmail = ev.organizer?.email ? String(ev.organizer.email).toLowerCase().trim() : null;
    if (orgEmail && !orgEmail.endsWith('resource.calendar.google.com') && !attendees.some((a) => a.email === orgEmail)) {
      attendees.push({ email: orgEmail, display_name: ev.organizer?.displayName || null, response_status: 'accepted', is_organizer: true });
    }
    return {
      google_event_id: ev.id,
      google_recurring_id: ev.recurringEventId || null,
      title: ev.summary || '(no title)',
      starts_at: ev.start?.dateTime || (ev.start?.date ? `${ev.start.date}T00:00:00Z` : null),
      ends_at: ev.end?.dateTime || (ev.end?.date ? `${ev.end.date}T00:00:00Z` : null),
      location: ev.location || roomLabel,
      room_cal_id: calId,
      room_label: roomLabel,
      status: ev.status === 'cancelled' ? 'cancelled' : 'confirmed',
      attendees,
    };
  });
}

// Module-scope feed cache keyed by range (TTL keeps Google calls + upserts down).
const FEED_TTL_MS = 90_000;
const _feedCache = new Map<string, { at: number; events: NormEvent[]; idByEvent: Record<string, string> }>();

async function syncFeed(admin: ReturnType<typeof createClient>, timeMin: string, timeMax: string): Promise<{ events: NormEvent[]; idByEvent: Record<string, string> }> {
  const cacheKey = `${timeMin}|${timeMax}`;
  const cached = _feedCache.get(cacheKey);
  if (cached && Date.now() - cached.at < FEED_TTL_MS) {
    return { events: cached.events, idByEvent: cached.idByEvent };
  }

  const room1 = Deno.env.get('ROOM1_CAL_ID');
  const room2 = Deno.env.get('ROOM2_CAL_ID');
  if (!room1 || !room2) throw new Error('Room calendar IDs are not configured');

  const token = await getGoogleToken();
  const [a, b] = await Promise.all([
    listRoom(token, room1, 'CBW Main Office Meeting Room', timeMin, timeMax),
    listRoom(token, room2, 'CBW Warehouse 4 Meeting Room', timeMin, timeMax),
  ]);
  const events = [...a, ...b];

  // Upsert meetings, capture DB ids, then refresh attendees.
  const idByEvent: Record<string, string> = {};
  if (events.length) {
    const meetingRows = events.map((e) => ({
      google_event_id: e.google_event_id,
      google_recurring_id: e.google_recurring_id,
      title: e.title,
      starts_at: e.starts_at,
      ends_at: e.ends_at,
      location: e.location,
      room_cal_id: e.room_cal_id,
      status: e.status,
      attendees_count: e.attendees.length,
      updated_at: new Date().toISOString(),
    }));
    const { data: upserted, error: upErr } = await admin
      .from('meetings')
      .upsert(meetingRows, { onConflict: 'google_event_id' })
      .select('id, google_event_id');
    if (upErr) throw new Error(`meetings upsert: ${upErr.message}`);
    for (const row of upserted || []) idByEvent[(row as any).google_event_id] = (row as any).id;

    // Refresh attendees: delete + reinsert per synced meeting for consistency.
    const ids = Object.values(idByEvent);
    if (ids.length) {
      await admin.from('meeting_attendees').delete().in('meeting_id', ids);
      const attRows: Record<string, unknown>[] = [];
      for (const e of events) {
        const mid = idByEvent[e.google_event_id];
        if (!mid) continue;
        for (const a of e.attendees) {
          attRows.push({
            meeting_id: mid,
            email: a.email,
            display_name: a.display_name,
            response_status: a.response_status,
            is_organizer: a.is_organizer,
          });
        }
      }
      if (attRows.length) {
        const { error: attErr } = await admin.from('meeting_attendees').insert(attRows);
        if (attErr) throw new Error(`attendees insert: ${attErr.message}`);
      }
    }
  }

  _feedCache.set(cacheKey, { at: Date.now(), events, idByEvent });
  return { events, idByEvent };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json(req, { ok: false, error: 'Unauthorized' }, 401);

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

    // Verify caller.
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return json(req, { ok: false, error: 'Unauthorized' }, 401);

    const admin = createClient(supabaseUrl, serviceKey);

    // Authorise: active staff only. Also resolve admin override.
    const { data: appUser } = await admin
      .from('app_users')
      .select('id, role, status, email')
      .eq('auth_user_id', user.id)
      .single();
    if (!appUser || appUser.status !== 'active') return json(req, { ok: false, error: 'Forbidden' }, 403);

    const callerEmail = String(appUser.email || user.email || '').toLowerCase().trim();

    let isAdmin = false;
    if (appUser.role) {
      const { data: roleRow } = await admin
        .from('roles')
        .select('is_pulse_admin, is_exec, permissions')
        .eq('key', appUser.role)
        .maybeSingle();
      const perms = (roleRow?.permissions || {}) as Record<string, unknown>;
      isAdmin = !!roleRow?.is_pulse_admin || !!roleRow?.is_exec || perms['meetings_admin'] == 1 || perms['meetings_admin'] === true;
    }

    // Parse range.
    let body: Record<string, unknown> = {};
    if (req.method === 'POST') { try { body = await req.json(); } catch { /* ignore */ } }
    const qs = new URL(req.url).searchParams;
    const now = new Date();
    const defMin = new Date(now.getTime() - 24 * 3600 * 1000).toISOString();
    const defMax = new Date(now.getTime() + 14 * 24 * 3600 * 1000).toISOString();
    const timeMin = String(body.timeMin || qs.get('timeMin') || defMin);
    const timeMax = String(body.timeMax || qs.get('timeMax') || defMax);

    const rooms = [
      { cal_id: Deno.env.get('ROOM1_CAL_ID') || '', label: 'CBW Main Office Meeting Room' },
      { cal_id: Deno.env.get('ROOM2_CAL_ID') || '', label: 'CBW Warehouse 4 Meeting Room' },
    ];

    let feed: { events: NormEvent[]; idByEvent: Record<string, string> };
    try {
      feed = await syncFeed(admin, timeMin, timeMax);
    } catch (e) {
      // Graceful degradation — the page still renders without the calendar.
      const message = e instanceof Error ? e.message : 'feed error';
      console.error('[meeting-rooms] feed error:', message);
      return json(req, { ok: true, degraded: true, message, rooms, events: [], me: callerEmail, is_admin: isAdmin });
    }

    // Filter visibility per caller.
    const events = feed.events.map((e) => {
      const attendee = e.attendees.some((a) => a.email === callerEmail);
      const visible = isAdmin || attendee;
      const base = {
        meeting_id: feed.idByEvent[e.google_event_id] || null,
        google_event_id: e.google_event_id,
        google_recurring_id: e.google_recurring_id,
        title: e.title,
        starts_at: e.starts_at,
        ends_at: e.ends_at,
        room_cal_id: e.room_cal_id,
        room_label: e.room_label,
        status: e.status,
        attendees_count: e.attendees.length,
        visible,
        is_attendee: attendee,
      };
      if (!visible) return base;
      return { ...base, location: e.location, attendees: e.attendees };
    });

    return json(req, { ok: true, rooms, events, me: callerEmail, is_admin: isAdmin });
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    console.error('[meeting-rooms] error:', message);
    return json(req, { ok: false, error: message }, 500);
  }
});
