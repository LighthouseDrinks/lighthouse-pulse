// timecard — Supabase Edge Function
//
// Backs the employee-facing magic-link correction page (timecard.html).
// The employee is NOT logged in, so the request token is the credential;
// this function validates it with the service role.
//
//   action: 'get'    → returns the employee's flagged days for the week,
//                      pre-filled with whatever clock times we captured
//                      (Europe/Dublin wall time).
//   action: 'submit' → stores the employee's corrected times as a PENDING
//                      request. It does NOT touch clock_events — a manager
//                      approves it in the Weekly Attendance report, which
//                      is when clock_events is actually written.
//
// Deploy: supabase functions deploy timecard --no-verify-jwt
// (Unauthenticated staff must be able to call it; the token is the gate.)
// Uses runtime SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — no new secrets.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
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

const TZ = 'Europe/Dublin';
const TOLERANCE_MS = 15 * 60 * 1000;
const BREAK_REQUIRED_AFTER_MS = 6 * 60 * 60 * 1000;

const MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const DOW = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

function dubParts(ts: string | number | Date): Record<string, number> {
  const d = ts instanceof Date ? ts : new Date(ts);
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(d);
  const o: Record<string, number> = {};
  for (const p of parts) if (p.type !== 'literal') o[p.type] = parseInt(p.value, 10);
  if (o.hour === 24) o.hour = 0;
  return o;
}
function dubOffsetMin(utcMs: number): number {
  const o = dubParts(new Date(utcMs));
  const asUtc = Date.UTC(o.year, o.month - 1, o.day, o.hour, o.minute, o.second);
  return Math.round((asUtc - utcMs) / 60000);
}
// Wall-clock (Dublin) date+time → UTC ISO instant.
function dubWallToIso(dateStr: string, timeStr: string): string {
  const p = dateStr.split('-').map(Number);
  const t = (timeStr || '00:00').split(':').map(Number);
  const asIfUtc = Date.UTC(p[0], p[1] - 1, p[2], t[0] || 0, t[1] || 0, t[2] || 0);
  const off = dubOffsetMin(asIfUtc);
  return new Date(asIfUtc - off * 60000).toISOString();
}
function dayKey(ts: string): string {
  const o = dubParts(ts);
  return `${o.year}-${String(o.month).padStart(2,'0')}-${String(o.day).padStart(2,'0')}`;
}
function wallHHMM(ts: string): string {
  const o = dubParts(ts);
  return `${String(o.hour).padStart(2,'0')}:${String(o.minute).padStart(2,'0')}`;
}
function addDaysYmd(ymd: string, n: number): string {
  const p = ymd.split('-').map(Number);
  const d = new Date(Date.UTC(p[0], p[1] - 1, p[2]));
  d.setUTCDate(d.getUTCDate() + n);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}-${String(d.getUTCDate()).padStart(2,'0')}`;
}
function dayLabel(ymd: string): string {
  const p = ymd.split('-').map(Number);
  const d = new Date(Date.UTC(p[0], p[1] - 1, p[2]));
  return `${DOW[d.getUTCDay()]} ${p[2]} ${MON[p[1]-1]}`;
}
function shiftMs(st?: string, et?: string): number {
  if (!st || !et) return 0;
  const a = st.split(':').map(Number), b = et.split(':').map(Number);
  let s = a[0]*60 + (a[1]||0), e = b[0]*60 + (b[1]||0);
  if (e < s) e += 1440;
  return Math.max(0, (e - s) * 60000);
}

interface ClockEvent { event_type: string; timestamp: string; }
interface DayRec { ci: ClockEvent | null; co: ClockEvent | null; br: { s: ClockEvent | null; e: ClockEvent | null }[]; }

// Reduce clock_events into per-Dublin-day sessions (mirrors the report).
function buildRecs(evts: ClockEvent[]): Record<string, DayRec> {
  const days: Record<string, DayRec> = {};
  [...evts].sort((a, b) => +new Date(a.timestamp) - +new Date(b.timestamp)).forEach((e) => {
    const d = dayKey(e.timestamp);
    if (!days[d]) days[d] = { ci: null, co: null, br: [] };
    const r = days[d];
    if (e.event_type === 'clock_in') { if (!r.ci) r.ci = e; }
    else if (e.event_type === 'clock_out') { r.co = e; }
    else if (e.event_type === 'break_start') { r.br.push({ s: e, e: null }); }
    else if (e.event_type === 'break_end') {
      if (r.br.length && !r.br[r.br.length - 1].e) r.br[r.br.length - 1].e = e;
      else r.br.push({ s: null, e });
    }
  });
  return days;
}
function breakMs(rec: DayRec | undefined): number {
  if (!rec) return 0;
  let t = 0;
  rec.br.forEach((b) => {
    if (!b.s) return;
    const be = b.e ? new Date(b.e.timestamp) : new Date();
    t += Math.max(0, +be - +new Date(b.s!.timestamp));
  });
  return t;
}
function grossMs(rec: DayRec | undefined): number {
  if (!rec || !rec.ci) return 0;
  const end = rec.co ? new Date(rec.co.timestamp) : new Date();
  return Math.max(0, +end - +new Date(rec.ci.timestamp));
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return err('Method not allowed', 405);

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(supabaseUrl, serviceKey);

    const body = await req.json() as Record<string, unknown>;
    const action = body.action as string;
    const token  = (body.token as string || '').trim();
    if (!token) return err('Missing token', 400);

    const { data: reqRow } = await admin
      .from('timecard_requests')
      .select('*')
      .eq('token', token)
      .maybeSingle();

    if (!reqRow) return err('This link is not valid.', 404, { code: 'invalid' });
    if (reqRow.status === 'approved') return err('These hours have already been confirmed by your manager.', 410, { code: 'approved' });
    if (reqRow.status === 'rejected') return err('This request was closed by your manager.', 410, { code: 'rejected' });
    if (reqRow.status === 'expired')  return err('This link has expired. Please ask your manager to resend it.', 410, { code: 'expired' });
    if (new Date(reqRow.expires_at) < new Date()) {
      return err('This link has expired. Please ask your manager to resend it.', 410, { code: 'expired' });
    }

    const monday = reqRow.week_start as string;          // YYYY-MM-DD
    const startIso = dubWallToIso(monday, '00:00');
    const endIso   = dubWallToIso(addDaysYmd(monday, 7), '00:00');
    const sunday   = addDaysYmd(monday, 6);
    const weekYmds: string[] = [];
    for (let i = 0; i < 7; i++) weekYmds.push(addDaysYmd(monday, i));
    const todayKey = dayKey(new Date().toISOString());

    // ── get: compute flagged days with prefilled times ──────────
    if (action === 'get') {
      const { data: evts } = await admin
        .from('clock_events')
        .select('event_type,timestamp')
        .eq('user_id', reqRow.user_id)
        .gte('timestamp', startIso)
        .lt('timestamp', endIso)
        .order('timestamp', { ascending: true });

      let shifts: { shift_date: string; start_time: string; end_time: string }[] = [];
      if (reqRow.app_user_id) {
        const { data: sh } = await admin
          .from('roster_shifts')
          .select('shift_date,start_time,end_time')
          .eq('user_id', reqRow.app_user_id)
          .gte('shift_date', monday)
          .lte('shift_date', sunday);
        shifts = sh || [];
      }
      const rosterMap: Record<string, number> = {};
      const rosterTimes: Record<string, { start: string; end: string }> = {};
      shifts.forEach((s) => {
        rosterMap[s.shift_date] = (rosterMap[s.shift_date] || 0) + shiftMs(s.start_time, s.end_time);
        if (!rosterTimes[s.shift_date]) rosterTimes[s.shift_date] = { start: (s.start_time||'').slice(0,5), end: (s.end_time||'').slice(0,5) };
      });

      const recs = buildRecs((evts || []) as ClockEvent[]);
      const days: unknown[] = [];

      weekYmds.forEach((ymd) => {
        const rec = recs[ymd];
        const rosterMs = rosterMap[ymd] || 0;
        const hasCi = !!(rec && rec.ci);
        const hasCo = !!(rec && rec.co);
        const isPast = ymd < todayKey;
        const onSite = grossMs(rec);
        const brk = breakMs(rec);

        const issues: string[] = [];
        if (rosterMs > 0 && !hasCi) issues.push('No clock-in recorded');
        if (hasCi && !hasCo && isPast) issues.push('No clock-out recorded');
        if (onSite > BREAK_REQUIRED_AFTER_MS && brk === 0) issues.push('No break recorded');
        if (hasCi && hasCo && rosterMs > 0 && Math.abs(onSite - rosterMs) > TOLERANCE_MS) {
          issues.push('Hours do not match your rostered shift');
        }
        if (!issues.length) return; // only flagged days

        days.push({
          date: ymd,
          label: dayLabel(ymd),
          issues,
          clockIn:  hasCi ? wallHHMM(rec!.ci!.timestamp) : '',
          clockOut: hasCo ? wallHHMM(rec!.co!.timestamp) : '',
          breaks: (rec ? rec.br : [])
            .filter((b) => b.s || b.e)
            .map((b) => ({ start: b.s ? wallHHMM(b.s.timestamp) : '', end: b.e ? wallHHMM(b.e.timestamp) : '' })),
          rosterStart: rosterTimes[ymd]?.start || '',
          rosterEnd:   rosterTimes[ymd]?.end || '',
        });
      });

      return json({
        ok: true,
        employeeName: reqRow.employee_name || 'there',
        weekStart: monday,
        weekLabel: `${dayLabel(monday)} – ${dayLabel(sunday)}`,
        alreadySubmitted: reqRow.status === 'submitted',
        days,
      });
    }

    // ── submit: store pending correction (no clock_events write) ──
    if (action === 'submit') {
      const days = body.days;
      if (!Array.isArray(days)) return err('Missing days', 400);

      // Light validation: HH:MM strings only, drop anything malformed.
      const re = /^([01]\d|2[0-3]):[0-5]\d$/;
      const clean = (days as Record<string, unknown>[]).map((d) => ({
        date: String(d.date || ''),
        clockIn:  re.test(String(d.clockIn || ''))  ? String(d.clockIn)  : '',
        clockOut: re.test(String(d.clockOut || '')) ? String(d.clockOut) : '',
        breaks: Array.isArray(d.breaks)
          ? (d.breaks as Record<string, unknown>[])
              .map((b) => ({
                start: re.test(String(b.start || '')) ? String(b.start) : '',
                end:   re.test(String(b.end || ''))   ? String(b.end)   : '',
              }))
              .filter((b) => b.start || b.end)
          : [],
      })).filter((d) => weekYmds.includes(d.date));

      const { error: updErr } = await admin
        .from('timecard_requests')
        .update({ submitted_payload: { days: clean }, status: 'submitted', submitted_at: new Date().toISOString() })
        .eq('token', token);
      if (updErr) return err(updErr.message, 500);

      return json({ ok: true });
    }

    return err(`Unknown action: ${action}`, 400);
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    return err(message, 500);
  }
});
