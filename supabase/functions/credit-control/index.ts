// credit-control — Supabase Edge Function
// Sends a chase email for an overdue Xero invoice via Resend. The email is
// designed to read like a personal email — no Pulse or Xero branding.
//
// Deploy: supabase functions deploy credit-control
// Requires the secret RESEND_API_KEY (Resend dashboard → API Keys).
// The sending domain (e.g. lighthousedrinks.com) must be verified in Resend
// before delivery — set SPF + DKIM DNS records first.
//
// Sender identity (credit_from_name / credit_from_email) lives in app_settings,
// editable from Finance > Settings. The function refuses to send if either is
// empty so users can't accidentally send chase emails from a placeholder.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Role policy is read from the `roles` table at request time
// (has_finance_access). See supabase/migrations/roles_table.sql.

const RESEND_URL = 'https://api.resend.com/emails';

// Defaults so the EF never refuses to send purely because app_settings is
// blank. Persisted overrides from Finance > Settings still win.
const DEFAULT_FROM_NAME  = 'Lighthouse Drinks';
const DEFAULT_FROM_EMAIL = 'creditcontrol@lighthousedrinks.com';

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function err(message: string, status = 400): Response {
  return json({ error: message }, status);
}

function fillTemplate(text: string, vars: Record<string, string>): string {
  let out = text;
  for (const [k, v] of Object.entries(vars)) {
    out = out.replaceAll(`{{${k}}}`, v);
  }
  return out;
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
    // Defence-in-depth: require status=active so terminated users with a
    // valid session can't call this finance endpoint.
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('id, role, status')
      .eq('auth_user_id', user.id)
      .single();
    if (!appUser || appUser.status !== 'active') return err('Forbidden — finance roles only', 403);

    const { data: roleRow } = await adminClient
      .from('roles')
      .select('has_finance_access')
      .eq('key', appUser.role)
      .maybeSingle();
    if (!roleRow?.has_finance_access) {
      return err('Forbidden — finance roles only', 403);
    }
    const userId = appUser.id as string;
    const body   = await req.json() as Record<string, unknown>;
    const action = body.action as string;

    // ── send_chase_email ────────────────────────────────────────────────────
    if (action === 'send_chase_email') {
      const templateId       = (body.template_id        as string) || '';
      const invoiceId        = (body.invoice_id         as string) || '';
      const invoiceNo        = (body.invoice_number     as string) || '';
      const contactName      = ((body.contact_name      as string) || '').trim();
      const contactEmail     = ((body.contact_email     as string) || '').trim();
      const amountDue        = (body.amount_due         as string) || '';
      const dueDate          = (body.due_date           as string) || '';
      const daysOverdue      = Number(body.days_overdue ?? 0);
      const invoiceUrl       = (body.invoice_url        as string) || '';
      // Per-send overrides from the editable modal. When supplied they win
      // over the stored template — template_id is still required so the log
      // captures which tone was sent.
      const subjectOverride  = ((body.subject_override   as string) || '').trim();
      const bodyHtmlOverride = ((body.body_html_override as string) || '').trim();

      if (!templateId)   return err('template_id is required', 400);
      if (!contactEmail) return err('contact_email is required', 400);

      // Load template (always — used for fallback + for the tone name in logs).
      const { data: tpl, error: tplErr } = await adminClient
        .from('credit_control_templates')
        .select('id, name, subject, body_html')
        .eq('id', templateId)
        .single();
      if (tplErr || !tpl) return err('Template not found', 404);

      // Load sender identity — fall back to module defaults when blank so a
      // missing app_settings row never blocks a chase. Resend still rejects
      // unverified sending domains; that error path is handled below.
      const { data: settings } = await adminClient
        .from('app_settings')
        .select('key, value')
        .in('key', ['credit_from_name', 'credit_from_email']);
      const sMap: Record<string, string> = {};
      for (const r of (settings ?? [])) sMap[r.key] = (r.value || '').trim();
      const fromName  = sMap['credit_from_name']  || DEFAULT_FROM_NAME;
      const fromEmail = sMap['credit_from_email'] || DEFAULT_FROM_EMAIL;

      const apiKey = Deno.env.get('RESEND_API_KEY');
      if (!apiKey) return err('RESEND_API_KEY not configured on the server', 500);

      const vars: Record<string, string> = {
        contact_name:    contactName || 'there',
        invoice_number:  invoiceNo,
        amount_due:      amountDue,
        due_date:        dueDate,
        days_overdue:    String(daysOverdue),
        invoice_url:     invoiceUrl,
      };
      // Overrides come from the editable modal with vars already substituted
      // on the client (so what the user previewed is what gets sent). We still
      // run fillTemplate over them as a no-op safety net so any leftover
      // {{vars}} the user kept also resolve.
      const rawSubject = subjectOverride  || (tpl.subject   as string);
      const rawHtml    = bodyHtmlOverride || (tpl.body_html as string);
      const subject    = fillTemplate(rawSubject, vars);
      const html       = fillTemplate(rawHtml,    vars);

      console.log('[credit-control] sending chase to', contactEmail, 'template:', tpl.name);
      const resendRes = await fetch(RESEND_URL, {
        method: 'POST',
        headers: {
          Authorization:  `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from:    `${fromName} <${fromEmail}>`,
          to:      [contactEmail],
          subject,
          html,
        }),
      });
      const resendData = await resendRes.json().catch(() => ({}));
      const messageId  = (resendData?.id as string) || null;

      const sendStatus = resendRes.status >= 200 && resendRes.status < 300 ? 'sent' : 'failed';
      let errorMsg: string | null = sendStatus === 'failed'
        ? (resendData?.message || resendData?.name || `Resend ${resendRes.status}`)
        : null;
      // Rewrite the opaque Resend "domain not verified" message into something
      // actionable. The first chase after a fresh install usually hits this.
      if (errorMsg && /domain.*(verif|not verified)|is not verified/i.test(errorMsg)) {
        const domain = fromEmail.includes('@') ? fromEmail.split('@')[1] : fromEmail;
        errorMsg = `Sending domain "${domain}" is not verified in Resend. Add it (SPF + DKIM) at https://resend.com/domains, then retry.`;
      }

      // Log the attempt regardless of outcome — useful audit trail
      await adminClient.from('credit_control_log').insert({
        invoice_id:           invoiceId || null,
        template_id:          templateId,
        sent_by:              userId,
        recipient_email:      contactEmail,
        days_overdue:         daysOverdue,
        provider_message_id:  messageId,
        send_status:          sendStatus,
      });

      if (sendStatus === 'failed') {
        console.error('[credit-control] resend error:', resendRes.status, JSON.stringify(resendData).slice(0, 300));
        return err(`Email failed to send: ${errorMsg}`, 400);
      }
      return json({ ok: true, message_id: messageId });
    }

    // ── list_chase_log ──────────────────────────────────────────────────────
    // Returns the most recent chase per invoice_id so the Invoices grid can
    // show "Chased X days ago" badges.
    if (action === 'list_chase_log') {
      const { data } = await adminClient
        .from('credit_control_log')
        .select('invoice_id, recipient_email, sent_at, send_status, template_id')
        .not('invoice_id', 'is', null)
        .order('sent_at', { ascending: false })
        .limit(1000);
      return json({ log: data ?? [] });
    }

    return err('Unknown action: ' + action, 400);

  } catch (e) {
    console.error('[credit-control] unhandled error:', e);
    return err(String(e), 500);
  }
});
