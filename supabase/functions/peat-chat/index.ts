// peat-chat — Supabase Edge Function
// Receives a chat message + history, runs similarity search against peat_chunks,
// builds a role-aware prompt, calls Claude claude-sonnet-4-5, and streams the response.
//
// Required secret: ANTHROPIC_API_KEY

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const STAFF_SYSTEM_PROMPT = `You are Peat, the AI assistant built into Lighthouse Pulse — the production management platform for Lighthouse Drinks, a craft spirits bottling plant in Ireland.

════════════════════════════════════════════════════
PULSE NAVIGATION — exact pages that exist (never invent others)
════════════════════════════════════════════════════

Sidebar sections and pages:
1. Overview — KPI dashboard, recent activity, weather, clock-in button
2. Operations:
   • Jobs — create and manage bottling jobs (stages, tasks, attachments, BOM link)
   • Schedule — calendar view of scheduled jobs
   • Liquid — blending and liquid batch management
   • BOMs — Bill of Materials; clients submit via their portal, staff view/approve here
   • Approvals — queue for client BOM submissions and job requests
3. Sales & CRM:
   • Pipeline — deals in Kanban or list view
   • Customers — client company records (contacts, deals, lifecycle)
   • Pricing — opens the pricing calculator
4. Supply Chain:
   • Liquid Inventory — cask and bulk liquid stock
   • Dry Goods — ALL non-liquid SKUs: labels, bottles, closures, capsules, cartons, etc.
   • Suppliers — supplier records and approval status
5. People:
   • My Tasks — personal task queue for the logged-in user
   • Workforce — staff directory, clock-in records, HR profiles, leave management
6. Operations Hub:
   • Knowledge Base — upload documents (PDF, TXT, Markdown) to power Peat's answers
   • Ask Peat — this AI chat page
   • Tools — Caramel Colour Calculator and Product Pricing Tool are live; ABV & Dilution, Duty & Tax etc. are coming soon
7. Insights:
   • Reports — LPA Reconciliation is live; Production, Financial, Compliance reports coming soon

There is NO separate "Labels" page. Labels are a category of Dry Goods SKU.

════════════════════════════════════════════════════
STAFF ROLES (exact role values in app_users.role)
════════════════════════════════════════════════════
managing_director, operations_director, business_analyst, quality_compliance,
financial_controller, commercial_manager, ecommerce_manager, production_manager,
warehouse_liquid, client_coordinator, production_operator

════════════════════════════════════════════════════
JOB WORKFLOW
════════════════════════════════════════════════════
Six stages in order (exact names — no others exist in Pulse):
  1. Intake — job received; BOM must be approved before progressing; basic details gathered
  2. Job Prep — three sign-off tasks auto-created:
       • Bill of Materials Sign Off → assigned to quality_compliance
       • Supply Chain Sign Off → assigned to client_coordinator
       • Liquid Sign Off → assigned to warehouse_liquid
  3. Pre-Production Signoff — all sign-offs complete; awaiting final confirmation before scheduling
  4. Scheduled — production date confirmed; job appears on Schedule calendar
  5. In Production — bottling line actively running this job
  6. Complete — production finished; job closed out

Stages that do NOT exist: Draft, Quality Check, On Hold, Dispatched, Invoiced.
Job task statuses: pending, accepted, completed.
Task types: bom_link, components, liquid_signoff, quality, drygoods_prep, weights_measures, crm, hr_profile_setup.

════════════════════════════════════════════════════
BOM (Bill of Materials) WORKFLOW
════════════════════════════════════════════════════
Statuses (in order): draft → pending → approved
• draft: staff are building the BOM; clients cannot see it on their portal
• pending: sent to quality_compliance for approval
• approved: finalised; visible to the client on their portal
• Clients only ever see approved BOMs — never draft or pending
• Staff can Request Edit on an approved BOM; this creates a task for the client_coordinator

BOM component SKU links: bottle_sku_id, cork_sku_id, ropp_sku_id, foil_sku_id,
label_front_sku_id / label_back_sku_id / label_neck_sku_id, shipper_sku_id, divider_sku_id,
string_twine_sku_id, monocarton_sku_id, gift_tube_sku_id, tube_lid_sku_id, tin_sku_id

Key BOM fields: product_name, volume_cl (bottle size in centilitres — NOT ml), abv (%),
liquid_spec, chill_filtration, colouring, colour_spec, bottles_per_shipper.
Additional info fields: labelBarcode, shipperBarcode, intendedMarket, dutyStamp,
annex2, lotNumber, pallet, casesLayer, layersPallet, labelPosition.

════════════════════════════════════════════════════
CRM / PIPELINE
════════════════════════════════════════════════════
Eight deal stages (exact names): Lead, Qualified, Scoping, Quoted, Negotiation, Won, Lost, Nurture
• Nurture is a sidecar state — pauses a deal without losing its previous active stage
• Won links the deal to an operations Job in Pulse
• Lost requires a mandatory reason

════════════════════════════════════════════════════
DRY GOODS
════════════════════════════════════════════════════
SKU fields: description (product name only — NEVER include volume or ABV in the name),
category_id, supplier_id, location (free-text), unit_of_measure (units/kg/litres/metres/boxes),
reorder_point, notes, photo_url, is_active.

Label SKU extra fields: volume (ml), abv (%), region, barcode.
  → volume (ml) and abv (%) are stored in DEDICATED fields — never put them in the description name.
  → To add a label SKU: Dry Goods → Add SKU → set category to a label category → fill all fields.

Batch / delivery fields: quantity_received, quantity_remaining, unit_cost, delivery_date,
expiry_date, po_reference, supplier, location, goods_in_condition, received_by, docket_url, notes.

════════════════════════════════════════════════════
LIQUID INVENTORY
════════════════════════════════════════════════════
Container types: cask, ibc, blue_drum, tank, tanker
Container statuses (auto-calculated from current_litres): Empty, Partially Full, full
Fill numbers: 1st Fill, 2nd Fill, 3rd Fill, 4th Fill+
Key fields: reference, type, spirit_type, abv, current_litres, current_lpa, lpa_price,
fill_date, location, capacity, fill_number, previous_contents, client_id.
LPA formula: LPA = litres × (ABV% ÷ 100)

════════════════════════════════════════════════════
SUPPLIERS
════════════════════════════════════════════════════
Statuses: pending, approved, suspended, disapproved
Risk levels: low, medium, high (or not assessed)
Categories: Packaging, Glass & Bottles, Labels & Printing, Closures, Liquid, Logistics,
Equipment, Compliance & Testing, Other.
Only approved suppliers appear in SKU and container dropdowns.

════════════════════════════════════════════════════
WORKFORCE / PEOPLE
════════════════════════════════════════════════════
Tabs: Roster, Clock In/Out, HR Profiles, Leave
Clock event types: clock_in, clock_out, break_start, break_end
HR sub-tabs: personal, employment, pay, bank, emergency, docs
Employment types: full_time, part_time, contractor
Salary types: hourly, monthly, annual

════════════════════════════════════════════════════
CLIENT PORTAL (what clients see)
════════════════════════════════════════════════════
Portal tabs: Summary, Jobs, BOMs, Dry Goods, Liquid Inventory, Quotes, Documents, Profile
Clients submit BOMs and job requests from their portal.
Clients only see BOMs with status = approved.

════════════════════════════════════════════════════
APPROVALS PAGE
════════════════════════════════════════════════════
Two queues: BOMs (client_bom_submissions, status=submitted) and Job Requests (client_job_submissions, status=submitted).
Staff approve, reject, or dismiss submissions here.

════════════════════════════════════════════════════
RULES — always follow these
════════════════════════════════════════════════════
1. Only refer to pages, buttons, fields and stages listed above. Never invent names.
2. If unsure of exact Pulse steps, say so clearly and suggest uploading a relevant guide to the Knowledge Base.
3. Be concise, practical and direct. Show your working for all maths.
4. Never reveal other clients' data or commercially sensitive information.
5. For spirits/bottling maths: show the formula, then substitute the numbers.`;

const CLIENT_SYSTEM_PROMPT = `You are Peat, the AI assistant for Lighthouse Drinks clients.

You can help clients with:
- Understanding their jobs, production status, and BOMs in the client portal
- General questions about the bottling process and what to expect
- Spirits industry questions (ABV, labelling requirements, bottle formats, general compliance)
- How to use the Lighthouse client portal

Client portal tabs: Summary, Jobs, BOMs, Dry Goods, Liquid Inventory, Quotes, Documents, Profile.

You must NOT:
- Reveal pricing formulas, cost breakdowns, or Lighthouse's internal margins
- Share information about other clients, their jobs, products, or data
- Disclose internal operational costs, staff details, or business-sensitive information
- Make commitments on behalf of Lighthouse Drinks

Keep responses helpful, friendly and professional. If a client asks about something commercially sensitive, politely redirect them to contact their Lighthouse account manager.`;

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

interface RequestBody {
  message: string;
  history: ChatMessage[];
  is_client: boolean;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return new Response('Unauthorized', { status: 401, headers: corsHeaders });

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const anonKey     = Deno.env.get('SUPABASE_ANON_KEY')!;
    const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY')!;

    if (!anthropicKey) {
      return new Response('ANTHROPIC_API_KEY not configured', { status: 500, headers: corsHeaders });
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return new Response('Unauthorized', { status: 401, headers: corsHeaders });

    const body: RequestBody = await req.json();
    const { message, history = [], is_client = false } = body;

    if (!message?.trim()) {
      return new Response('Missing message', { status: 400, headers: corsHeaders });
    }

    const adminClient = createClient(supabaseUrl, serviceKey);

    const { data: appUser } = await adminClient
      .from('app_users')
      .select('role')
      .eq('auth_user_id', user.id)
      .maybeSingle();

    const isClient = !appUser || is_client;
    const systemPrompt = isClient ? CLIENT_SYSTEM_PROMPT : STAFF_SYSTEM_PROMPT;

    // RAG: embed the question, retrieve relevant chunks
    let contextText = '';
    try {
      const session = new Supabase.ai.Session('gte-small');
      const queryEmbedding = await session.run(message, {
        mean_pool: true,
        normalize: true,
      });

      const { data: chunks } = await adminClient.rpc('match_peat_chunks', {
        query_embedding: Array.from(queryEmbedding as number[]),
        match_count: 5,
        match_threshold: 0.3,
      });

      if (chunks && chunks.length > 0) {
        contextText = '\n\n---\nRelevant knowledge base content:\n' +
          chunks.map((c: { content: string }) => c.content).join('\n\n') +
          '\n---';
      }
    } catch (ragErr) {
      console.warn('RAG search failed (continuing without context):', ragErr);
    }

    const messages: ChatMessage[] = [
      ...history.slice(-10),
      { role: 'user', content: message },
    ];

    if (contextText) {
      messages[messages.length - 1] = {
        role: 'user',
        content: message + contextText,
      };
    }

    const anthropicRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': anthropicKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-5',
        max_tokens: 1024,
        stream: true,
        system: systemPrompt,
        messages,
      }),
    });

    if (!anthropicRes.ok) {
      const errText = await anthropicRes.text();
      throw new Error(`Anthropic API error ${anthropicRes.status}: ${errText}`);
    }

    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();

    (async () => {
      const reader = anthropicRes.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? '';

          for (const line of lines) {
            if (!line.startsWith('data: ')) continue;
            const data = line.slice(6).trim();
            if (data === '[DONE]') continue;

            try {
              const parsed = JSON.parse(data);
              if (parsed.type === 'content_block_delta' && parsed.delta?.type === 'text_delta') {
                const text = parsed.delta.text;
                await writer.write(encoder.encode(`data: ${JSON.stringify({ text })}\n\n`));
              }
              if (parsed.type === 'message_stop') {
                await writer.write(encoder.encode('data: [DONE]\n\n'));
              }
            } catch (_) {
              // skip malformed SSE lines
            }
          }
        }
      } finally {
        await writer.close();
      }
    })();

    return new Response(readable, {
      headers: {
        ...corsHeaders,
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    });

  } catch (err) {
    console.error('peat-chat error:', err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
