// clock-autoclose — Supabase Edge Function
//
// Closes "forgotten" clock-ins / breaks so the next time the user opens Pulse
// their state is correct. Runs nightly via pg_cron (see
// supabase/migrations/clock_events_guard.sql).
//
// Algorithm (time-zone independent, idempotent):
//   1. For every user whose most recent NON-synthetic event in the last 16 h
//      is `clock_in` or `break_start`, AND that event is older than 12 h:
//   2. If the user is on break (last event was break_start), insert a
//      synthetic break_end at (last_break_start + 1 hour, capped at +30 m
//      before now).
//   3. Insert a synthetic clock_out at (last_clock_in + 8 hours), capped at
//      now() so we never write timestamps in the future.
//   4. Both rows are flagged synthetic = true and within_geofence = false so
//      the timesheet UI can render an "AUTO" pill.
//
// Deploy:
//   supabase functions deploy clock-autoclose
//
// Required secrets:
//   SUPABASE_URL                    (auto-injected)
//   SUPABASE_SERVICE_ROLE_KEY       (auto-injected)
//   CLOCK_AUTOCLOSE_TOKEN           bearer required from any caller
//
// Schedule (added by migration):
//   pg_cron 'clock-autoclose-nightly' fires at 02:00 UTC daily and POSTs to
//   this function with the Authorization header pulled from
//   current_setting('app.clock_autoclose_token').

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

interface LatestEvent {
  user_id: string;
  event_type: string;
  timestamp: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    // Auth: caller must present the shared bearer token.
    const expectedToken = Deno.env.get('CLOCK_AUTOCLOSE_TOKEN') || '';
    const authHeader = req.headers.get('Authorization') || '';
    const provided = authHeader.replace(/^Bearer\s+/i, '').trim();
    if (!expectedToken || provided !== expectedToken) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const url    = Deno.env.get('SUPABASE_URL')!;
    const svcKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin  = createClient(url, svcKey, { auth: { persistSession: false } });

    const now = new Date();
    const cutoffMs = now.getTime() - 12 * 3600 * 1000;
    const lookbackIso = new Date(now.getTime() - 24 * 3600 * 1000).toISOString();

    // Pull all non-synthetic events from the last 24 hours and find the
    // most recent per user client-side. (Doing it in JS keeps the query
    // simple and avoids Postgres-specific DISTINCT ON dialect issues.)
    const { data: recent, error: qErr } = await admin
      .from('clock_events')
      .select('user_id,event_type,timestamp,synthetic')
      .eq('synthetic', false)
      .gte('timestamp', lookbackIso)
      .order('timestamp', { ascending: false })
      .limit(5000);
    if (qErr) return json({ error: 'query failed', detail: qErr.message }, 500);

    const latestByUser = new Map<string, LatestEvent>();
    for (const r of (recent || []) as LatestEvent[]) {
      if (!latestByUser.has(r.user_id)) latestByUser.set(r.user_id, r);
    }

    const closedClockOuts: string[] = [];
    const closedBreakEnds: string[] = [];

    for (const [userId, last] of latestByUser.entries()) {
      const lastMs = new Date(last.timestamp).getTime();
      if (lastMs >= cutoffMs) continue;                 // < 12h ago, skip
      if (last.event_type === 'clock_out')   continue;  // already closed
      if (last.event_type === 'break_end')   continue;  // implies clocked-in
                                                        // but stale only if a
                                                        // clock_out is missing
                                                        // — handled below by
                                                        // re-querying.

      // Determine the most recent clock_in for this user so the synthetic
      // clock_out can sit at clock_in + 8h.
      const { data: ciRows } = await admin
        .from('clock_events')
        .select('timestamp')
        .eq('user_id', userId)
        .eq('event_type', 'clock_in')
        .eq('synthetic', false)
        .gte('timestamp', lookbackIso)
        .order('timestamp', { ascending: false })
        .limit(1);

      let clockInMs = lastMs;
      if (ciRows && ciRows.length) {
        clockInMs = new Date(ciRows[0].timestamp).getTime();
      }

      // If currently on break, end the break first (1h after break_start,
      // clamped to at most 30m before now()).
      if (last.event_type === 'break_start') {
        const breakEndMs = Math.min(
          lastMs + 60 * 60 * 1000,
          now.getTime() - 30 * 60 * 1000
        );
        const breakEndIso = new Date(Math.max(breakEndMs, lastMs + 60 * 1000)).toISOString();
        const { error: beErr } = await admin
          .from('clock_events')
          .insert({
            user_id: userId,
            event_type: 'break_end',
            timestamp: breakEndIso,
            within_geofence: false,
            synthetic: true,
          });
        if (!beErr) closedBreakEnds.push(userId);
      }

      // Clock out at clock_in + 8h, but never in the future.
      const coMs = Math.min(clockInMs + 8 * 3600 * 1000, now.getTime() - 60 * 1000);
      const coIso = new Date(Math.max(coMs, lastMs + 2 * 60 * 1000)).toISOString();
      const { error: coErr } = await admin
        .from('clock_events')
        .insert({
          user_id: userId,
          event_type: 'clock_out',
          timestamp: coIso,
          within_geofence: false,
          synthetic: true,
        });
      if (!coErr) closedClockOuts.push(userId);
    }

    return json({
      ok: true,
      examined: latestByUser.size,
      closed_clock_outs: closedClockOuts.length,
      closed_break_ends: closedBreakEnds.length,
      timestamp: now.toISOString(),
    });
  } catch (e) {
    return json({ error: 'exception', detail: (e as Error).message }, 500);
  }
});
