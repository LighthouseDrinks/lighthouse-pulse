// Daily external-calibration reminders for the Quality & Compliance role.
//
// Auth: Authorization bearer must be the service role, or x-cron-secret must
// match the SHA-256 of the vault secret qms_cal_cron_secret (row in
// qms_cal_cron_check). Cron has no user session. verify_jwt is off because
// the cron caller is not a user JWT.
//
// Body: { "dry_run": true } returns the items that would be emailed and does
// not send or write the reminder log.
//
// Bands, using the most recently saved calibration's next due date:
//   15–30 days  d30 once
//   8–14 days   d14 once
//   0–7 days    d7 once
//   overdue     once per Dublin calendar day

const PROJECT_URL = 'https://anhawgzgxoywophqbmji.supabase.co';
const RESEND_URL = 'https://api.resend.com/emails';
const APP_URL = 'https://pulse.lighthousedrinks.com/#qms-calibration-external';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

type Equip = {
  id: string;
  name: string;
  serial_no: string | null;
  contractor: string | null;
};
type Cal = {
  equipment_id: string;
  next_due_on: string | null;
  created_at: string;
};
type Reminder = {
  equipment_id: string;
  due_on: string;
  kind: string;
  sent_on: string;
};
type Notice = {
  equipment_id: string;
  name: string;
  serial_no: string | null;
  contractor: string | null;
  due_on: string;
  days: number;
  kind: string;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function todayDublin(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Dublin',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function daysUntil(due: string, today: string): number {
  const [ty, tm, td] = today.split('-').map(Number);
  const [dy, dm, dd] = due.slice(0, 10).split('-').map(Number);
  return Math.round((Date.UTC(dy, dm - 1, dd) - Date.UTC(ty, tm - 1, td)) / 86400000);
}

function band(days: number): string | null {
  if (days < 0) return 'overdue';
  if (days <= 7) return 'd7';
  if (days <= 14) return 'd14';
  if (days <= 30) return 'd30';
  return null;
}

function esc(s: unknown): string {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function fmtUk(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split('-');
  return `${d}/${m}/${y}`;
}

function statusLabel(n: Notice): string {
  if (n.days < 0) {
    const nDays = Math.abs(n.days);
    return nDays === 1 ? 'Overdue by 1 day' : `Overdue by ${nDays} days`;
  }
  if (n.days === 0) return 'Due today';
  if (n.days === 1) return 'Due in 1 day';
  return `Due in ${n.days} days`;
}

async function rest(serviceKey: string, path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${PROJECT_URL}${path}`, {
    ...init,
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
}

async function cronSecretOk(serviceKey: string, secret: string): Promise<boolean> {
  if (!secret) return false;
  const res = await rest(serviceKey, '/rest/v1/qms_cal_cron_check?id=eq.1&select=secret_hash');
  if (!res.ok) return false;
  const rows = await res.json();
  const expected = Array.isArray(rows) && rows[0] ? String(rows[0].secret_hash || '') : '';
  if (!expected) return false;
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret));
  const hex = Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  return hex === expected;
}

async function resolveEmail(serviceKey: string): Promise<{ apiKey: string; from: string }> {
  let apiKey = (Deno.env.get('RESEND_API_KEY') || '').trim();
  let fromEmail = 'pulse@lighthousedrinks.com';
  try {
    const res = await rest(serviceKey, '/rest/v1/app_settings?key=eq.system&select=value');
    if (res.ok) {
      const rows = await res.json();
      const raw = Array.isArray(rows) && rows[0] ? rows[0].value : null;
      let v: Record<string, unknown> = {};
      if (typeof raw === 'string') {
        try { v = JSON.parse(raw); } catch (_) { v = {}; }
      } else if (raw && typeof raw === 'object') {
        v = raw as Record<string, unknown>;
      }
      if (!apiKey && v.resend_key) apiKey = String(v.resend_key).trim();
      if (v.from_email) fromEmail = String(v.from_email).trim();
    }
  } catch (_) { /* env key still applies */ }
  return { apiKey, from: `Pulse by Lighthouse Drinks <${fromEmail}>` };
}

function emailHtml(notices: Notice[]): string {
  const rows = notices.map((n) => {
    const overdue = n.days < 0;
    const colour = overdue ? '#c92f2f' : '#8a6a12';
    const serial = n.serial_no ? ` <span style="color:#7a93a8;font-weight:500;">${esc(n.serial_no)}</span>` : '';
    return '<tr>'
      + `<td style="padding:10px 12px;border-bottom:1px solid #eee;color:#0d1b2a;font-weight:700;">${esc(n.name)}${serial}</td>`
      + `<td style="padding:10px 12px;border-bottom:1px solid #eee;color:#0d1b2a;">${esc(fmtUk(n.due_on))}</td>`
      + `<td style="padding:10px 12px;border-bottom:1px solid #eee;color:${colour};font-weight:700;">${esc(statusLabel(n))}</td>`
      + '</tr>';
  }).join('');
  return '<div style="font-family:sans-serif;max-width:640px;margin:0 auto;padding:28px 24px;background:#f9f9f9;">'
    + '<div style="background:#0d1b2a;padding:22px;border-radius:8px;text-align:center;margin-bottom:20px;">'
    + '<h1 style="color:#c9a84c;font-size:18px;margin:0;">Lighthouse Drinks</h1>'
    + '<p style="color:#7a93a8;font-size:11px;margin:4px 0 0;letter-spacing:0.12em;text-transform:uppercase;">Pulse · External calibration</p>'
    + '</div>'
    + '<p style="color:#0d1b2a;font-size:15px;font-weight:700;margin:0 0 8px;">Calibration dates need attention.</p>'
    + '<p style="color:#555;font-size:13px;line-height:1.5;margin:0 0 16px;">These items are inside 30 days of their next due date, or are already overdue.</p>'
    + '<table style="width:100%;border-collapse:collapse;background:#fff;border-radius:4px;">'
    + '<tr>'
    + '<th style="text-align:left;padding:8px 12px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:#7a93a8;">Equipment</th>'
    + '<th style="text-align:left;padding:8px 12px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:#7a93a8;">Next due</th>'
    + '<th style="text-align:left;padding:8px 12px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:#7a93a8;">Status</th>'
    + '</tr>'
    + rows
    + '</table>'
    + `<p style="margin:18px 0 0;"><a href="${APP_URL}" style="color:#0d1b2a;font-weight:700;">Open Calibration Logs, External</a></p>`
    + '<p style="color:#888;font-size:11px;margin-top:18px;">This is an automated notification from Pulse by Lighthouse Drinks.</p>'
    + '</div>';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || Deno.env.get('SERVICE_ROLE_KEY') || '';
  if (!serviceKey) return json({ error: 'Not configured' }, 500);

  const bearer = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  const cronSecret = (req.headers.get('x-cron-secret') || '').trim();
  const allowed = (bearer && bearer === serviceKey) || await cronSecretOk(serviceKey, cronSecret);
  if (!allowed) return json({ error: 'Unauthorized' }, 401);

  let dryRun = false;
  try {
    const body = await req.json();
    dryRun = !!(body && body.dry_run === true);
  } catch (_) {
    dryRun = false;
  }

  const today = todayDublin();

  const equipRes = await rest(serviceKey, '/rest/v1/qms_external_equipment?select=id,name,serial_no,contractor&order=sort_order.asc');
  if (!equipRes.ok) return json({ error: 'Could not load equipment' }, 500);
  const equipment = await equipRes.json() as Equip[];

  const calRes = await rest(serviceKey, '/rest/v1/qms_external_calibrations?select=equipment_id,next_due_on,created_at&order=created_at.desc');
  if (!calRes.ok) return json({ error: 'Could not load calibrations' }, 500);
  const calibrations = await calRes.json() as Cal[];

  const current = new Map<string, Cal>();
  for (const cal of calibrations) {
    if (!current.has(cal.equipment_id)) current.set(cal.equipment_id, cal);
  }

  const logRes = await rest(serviceKey, '/rest/v1/qms_external_reminder_log?select=equipment_id,due_on,kind,sent_on');
  if (!logRes.ok) return json({ error: 'Could not load reminder log' }, 500);
  const sent = await logRes.json() as Reminder[];

  const notices: Notice[] = [];
  for (const eq of equipment) {
    const cal = current.get(eq.id);
    if (!cal || !cal.next_due_on) continue;
    const due = cal.next_due_on.slice(0, 10);
    const days = daysUntil(due, today);
    const kind = band(days);
    if (!kind) continue;
    const already = sent.some((row) => {
      if (row.equipment_id !== eq.id || row.due_on.slice(0, 10) !== due || row.kind !== kind) return false;
      if (kind === 'overdue') return row.sent_on.slice(0, 10) === today;
      return true;
    });
    if (already) continue;
    notices.push({
      equipment_id: eq.id,
      name: eq.name,
      serial_no: eq.serial_no,
      contractor: eq.contractor,
      due_on: due,
      days,
      kind,
    });
  }

  if (!notices.length) {
    return json({ ok: true, dry_run: dryRun, sent: false, today, count: 0, items: [] });
  }

  if (dryRun) {
    return json({
      ok: true,
      dry_run: true,
      sent: false,
      today,
      count: notices.length,
      items: notices.map((n) => ({ name: n.name, serial_no: n.serial_no, due_on: n.due_on, days: n.days, kind: n.kind })),
    });
  }

  const usersRes = await rest(serviceKey, '/rest/v1/app_users?status=eq.active&role=eq.quality_compliance&select=email');
  if (!usersRes.ok) return json({ error: 'Could not load recipients' }, 500);
  const recipients = ((await usersRes.json()) as { email: string | null }[])
    .map((u) => (u.email || '').trim())
    .filter(Boolean);
  if (!recipients.length) return json({ error: 'No Quality & Compliance email on file', today, count: notices.length }, 200);

  const { apiKey, from } = await resolveEmail(serviceKey);
  if (!apiKey) return json({ error: 'No Resend API key configured' }, 500);

  const overdueCount = notices.filter((n) => n.days < 0).length;
  const subject = overdueCount
    ? `External calibration — ${notices.length} due, ${overdueCount} overdue`
    : `External calibration — ${notices.length} due within 30 days`;

  const sendRes = await fetch(RESEND_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from,
      to: recipients,
      subject,
      html: emailHtml(notices),
    }),
  });
  const sendBody = await sendRes.json().catch(() => ({}));
  if (!sendRes.ok) {
    return json({ error: 'Email failed', detail: sendBody }, 502);
  }

  const logRows = notices.map((n) => ({
    equipment_id: n.equipment_id,
    due_on: n.due_on,
    kind: n.kind,
    sent_on: today,
  }));
  const ins = await rest(serviceKey, '/rest/v1/qms_external_reminder_log', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify(logRows),
  });
  if (!ins.ok) {
    const errText = await ins.text();
    return json({ ok: true, sent: true, logged: false, today, count: notices.length, error: errText }, 200);
  }

  return json({ ok: true, sent: true, logged: true, today, count: notices.length });
});
