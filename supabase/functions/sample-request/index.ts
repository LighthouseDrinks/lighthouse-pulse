// sample-request — Supabase Edge Function
//
// Backs the public / portal "Request a Sample" form. The requester is usually
// NOT a logged-in staff member (a prospect via the public link, or a portal
// client), so this function runs with the service role and does all the
// privileged work server-side:
//
//   GET  (or action:'brands')  -> returns our active own-brands for quick-pick.
//   POST (action:'submit')     -> inserts a samples row (+ components), creates
//                                 the Quality & Compliance coordinator task and
//                                 a CRM notification, and emails a confirmation
//                                 to the requester plus an alert to the coordinator.
//
// Deploy: supabase functions deploy sample-request --no-verify-jwt
// (Unauthenticated requesters must be able to call it; input is validated here.)
// Uses runtime SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY. Email uses the shared
// RESEND_API_KEY function secret; if it's absent the request still succeeds and
// email is skipped.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

const RESEND_URL       = 'https://api.resend.com/emails';
const FROM_IDENTITY     = 'Lighthouse Drinks <noreply@lighthousedrinks.com>';
const COORDINATOR_ROLE  = 'quality_compliance';

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function err(message: string, status = 400): Response {
  return json({ error: message }, status);
}
function esc(s: unknown): string {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

interface CompIn { product_name?: string; percentage?: unknown; vol_in_sample?: string; abv?: unknown; }

// Allocate the next SMP-xxx id, retrying on a PK collision.
async function nextSampleId(admin: ReturnType<typeof createClient>): Promise<string> {
  const { data } = await admin.from('samples').select('id').order('id', { ascending: false }).limit(100);
  let max = 0;
  for (const r of (data ?? []) as { id: string }[]) {
    const n = parseInt((r.id || '').replace(/[^0-9]/g, '') || '0', 10);
    if (n > max) max = n;
  }
  return 'SMP-' + ('000' + (max + 1)).slice(-3);
}

async function nextFinishedLogNo(admin: ReturnType<typeof createClient>): Promise<number> {
  const { data } = await admin.from('samples')
    .select('finished_log_no').not('finished_log_no', 'is', null)
    .order('finished_log_no', { ascending: false }).limit(100);
  let max = 0;
  for (const r of (data ?? []) as { finished_log_no: unknown }[]) {
    const n = parseInt(String(r.finished_log_no ?? '0').replace(/[^0-9]/g, '') || '0', 10);
    if (n > max) max = n;
  }
  return max + 1;
}

async function sendEmail(to: string, subject: string, html: string): Promise<void> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey || !to) return;
  try {
    await fetch(RESEND_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_IDENTITY, to: [to], subject, html }),
    });
  } catch (_) { /* email is best-effort; never block the submission */ }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(supabaseUrl, serviceKey);

    // ── brands (GET or action:'brands') ─────────────────────────────────────
    const url = new URL(req.url);
    let action = url.searchParams.get('action') || '';
    let body: Record<string, unknown> = {};
    if (req.method === 'POST') {
      body = await req.json().catch(() => ({})) as Record<string, unknown>;
      action = (body.action as string) || action || 'submit';
    } else {
      action = action || 'brands';
    }

    if (action === 'brands') {
      const { data } = await admin.from('sample_brands')
        .select('id,name,liquid_type,default_abv')
        .eq('is_active', true)
        .order('sort_order', { ascending: true }).order('name', { ascending: true });
      return json({ ok: true, brands: data ?? [] });
    }

    if (action !== 'submit') return err('Unknown action: ' + action, 400);

    // ── submit ───────────────────────────────────────────────────────────────
    const clientId     = ((body.client_id as string) || '').trim() || null;
    const recipCompany = ((body.recipient_company as string) || '').trim();
    const recipName    = ((body.recipient_name as string) || '').trim();
    const contactName  = ((body.contact_name as string) || '').trim();
    const contactEmail = ((body.contact_email as string) || '').trim();
    const requesterEmail = ((body.requester_email as string) || '').trim();
    const requestedBy  = ((body.requested_by as string) || '').trim();
    const address      = ((body.address as string) || '').trim();
    const liquidType   = ((body.liquid_type as string) || '').trim();
    const mixType      = (body.mix_type as string) === 'blend' ? 'blend' : 'straight';
    const bottleSize   = ((body.bottle_size as string) || '').trim();
    const totalVolume  = ((body.total_volume as string) || '').trim();
    const quantity     = parseInt(String(body.quantity ?? ''), 10);
    const abvTarget    = parseFloat(String(body.abv_target ?? ''));
    const notes        = ((body.notes as string) || '').trim();
    const compsIn      = Array.isArray(body.components) ? body.components as CompIn[] : [];

    // Recipient required: an existing client OR a named off-Pulse company.
    if (!clientId && !recipCompany) return err('Please tell us who the sample is for (company or account).', 400);
    // Contact + requester email drive dispatch and confirmation emails.
    if (!contactEmail || !contactEmail.includes('@')) return err('A valid contact email is required.', 400);
    if (!requesterEmail || !requesterEmail.includes('@')) return err('A valid requester email is required.', 400);

    // Normalise components; a blend can never exceed 100%.
    const comps = compsIn
      .map((c, i) => ({
        product_name:  String(c.product_name || '').trim(),
        vol_in_sample: String(c.vol_in_sample || '').trim(),
        abv:           (c.abv === '' || c.abv == null) ? null : (parseFloat(String(c.abv)) || null),
        percentage:    (c.percentage === '' || c.percentage == null) ? null : (parseFloat(String(c.percentage)) || 0),
        sort_order:    i,
      }))
      .filter((c) => c.product_name);
    if (!comps.length) return err('Add at least one product / liquid.', 400);
    if (mixType === 'blend') {
      const total = comps.reduce((a, c) => a + (c.percentage || 0), 0);
      if (total > 100.5) return err(`Blend percentages total ${Math.round(total * 10) / 10}% — they can't exceed 100%.`, 400);
    }

    const sampleId = await nextSampleId(admin);
    const finishedLogNo = await nextFinishedLogNo(admin);
    const nowIso = new Date().toISOString();

    const payload = {
      id:                sampleId,
      client_id:         clientId,
      recipient_company: clientId ? null : (recipCompany || null),
      recipient_name:    clientId ? null : (recipName || null),
      contact_name:      contactName || null,
      contact_email:     contactEmail || null,
      requester_email:   requesterEmail || null,
      requested_by:      requestedBy || null,
      address:           address || null,
      date_shared:       nowIso.slice(0, 10),
      liquid_type:       liquidType || null,
      mix_type:          mixType,
      bottle_size:       bottleSize || null,
      total_volume:      totalVolume || null,
      quantity:          Number.isFinite(quantity) ? quantity : null,
      abv_target:        Number.isFinite(abvTarget) ? abvTarget : null,
      notes:             notes || null,
      request_source:    'external',
      chargeable:        true,
      status:            'submitted',
      finished_log_no:   finishedLogNo,
      created_at:        nowIso,
    };

    const { error: insErr } = await admin.from('samples').insert(payload);
    if (insErr) return err('Could not save the request: ' + insErr.message, 500);

    if (comps.length) {
      const rows = comps.map((c) => ({ ...c, sample_id: sampleId }));
      await admin.from('sample_components').insert(rows);
    }

    // Resolve display name for the recipient (for task titles / emails).
    let recipDisplay = recipCompany || recipName || sampleId;
    if (clientId) {
      const { data: cl } = await admin.from('clients').select('company').eq('id', clientId).maybeSingle();
      if (cl?.company) recipDisplay = cl.company as string;
    }

    // Auto-create the Quality & Compliance coordinator review task.
    const { data: coordUser } = await admin.from('app_users')
      .select('id,display_name,email')
      .eq('role', COORDINATOR_ROLE).eq('status', 'active')
      .order('display_name', { ascending: true }).limit(1).maybeSingle();

    if (coordUser?.id) {
      const taskId = crypto.randomUUID();
      await admin.from('job_tasks').insert({
        id:          taskId,
        title:       'Sample Request — ' + recipDisplay,
        description: 'Review sample request ' + sampleId + ' (' + recipDisplay + ').'
                     + (requestedBy ? ' Raised by ' + requestedBy + '.' : '')
                     + '\nExternal request — confirm details, sign off and delegate preparation.',
        assignee_id: coordUser.id,
        status:      'pending',
        priority:    'high',
        client_id:   clientId,
        sample_id:   sampleId,
        task_kind:   'review',
        created_at:  nowIso,
      });
      await admin.from('crm_notifications').insert({
        id:        crypto.randomUUID(),
        user_id:   coordUser.id,
        type:      'task_assigned',
        task_id:   taskId,
        client_id: clientId,
        body:      'New external sample request ' + sampleId + ' — ' + recipDisplay,
        created_at: nowIso,
      });
      // Alert email to the coordinator.
      await sendEmail(
        (coordUser.email as string) || '',
        'New sample request ' + sampleId + ' — ' + recipDisplay,
        '<p>A new external sample request has landed in Pulse.</p>'
        + '<p><strong>' + esc(sampleId) + '</strong> for ' + esc(recipDisplay) + '.</p>'
        + (requestedBy ? '<p>Raised by ' + esc(requestedBy) + ' (' + esc(requesterEmail) + ').</p>' : '')
        + '<p>Open Pulse to review, confirm and sign it off.</p>'
        + '<p style="color:#999;font-size:12px;">Automated notification from Lighthouse Pulse.</p>'
      );
    }

    // Confirmation email to the requester.
    await sendEmail(
      requesterEmail,
      'We\'ve received your sample request (' + sampleId + ')',
      '<p>Hi ' + esc(contactName || 'there') + ',</p>'
      + '<p>Thanks — we\'ve received your sample request and it\'s now with our sample coordinator for review.</p>'
      + '<p><strong>Reference:</strong> ' + esc(sampleId) + '</p>'
      + '<p>We\'ll be in touch shortly. If anything is unclear, just reply to this email.</p>'
      + '<p style="color:#999;font-size:12px;">Sent via Lighthouse Pulse.</p>'
    );

    return json({ ok: true, id: sampleId });

  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    console.error('[sample-request] error:', message);
    return err(message, 500);
  }
});
