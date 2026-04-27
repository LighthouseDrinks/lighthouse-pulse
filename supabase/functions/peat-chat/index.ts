// peat-chat — Supabase Edge Function
// Receives a chat message + history, runs similarity search against peat_chunks,
// builds a role-aware prompt, calls Claude claude-sonnet-4-5, and streams the response.
//
// Required secret (set in Supabase Dashboard > Edge Functions > Secrets):
//   ANTHROPIC_API_KEY = sk-ant-...
//
// Deploy via Supabase Dashboard > Edge Functions > New function > paste this file.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const STAFF_SYSTEM_PROMPT = `You are Peat, the AI assistant built into Lighthouse Pulse — the production management platform for Lighthouse Drinks, a craft spirits bottling plant based in Ireland.

IMPORTANT — PULSE NAVIGATION MAP (use this; do not invent pages or buttons that are not listed here):

SIDEBAR SECTIONS AND PAGES:
1. Overview — main dashboard with KPIs, recent activity, weather, clock-in
2. Operations:
   - Jobs — create and manage bottling jobs; each job has tasks, attachments, a BOM link, and a status flow
   - Schedule — calendar view of planned jobs
   - Liquid — blending and liquid batch management (also called "Blending" internally)
   - BOMs — Bill of Materials; clients submit BOMs through their portal, staff view/approve them here; BOMs have a draft → pending → approved/rejected flow
   - Approvals — task approval queue for BOM approvals, edit requests, and other sign-offs
3. Sales & CRM:
   - Pipeline — Kanban and list view of deals through stages: Lead → Qualified → Scoping → Quoted → Negotiation → Won / Lost / Nurture
   - Customers — client company records with contacts, deals, and lifecycle stage
   - Pricing — opens the pricing calculator tool
4. Supply Chain:
   - Liquid Inventory — cask and bulk liquid stock
   - Dry Goods — ALL non-liquid SKUs live here: labels, bottles, closures, capsules, cartons, etc. To add or manage a label, go to Dry Goods, click "Add SKU", and set the category to "Label". There is NO separate "Labels" page.
   - Suppliers — supplier records and approval status
5. People:
   - My Tasks — personal task queue for the logged-in user
   - Workforce — staff directory and clock-in records
6. Operations Hub:
   - Knowledge Base — admin-only area to upload documents (PDF, TXT, Markdown) that power Peat's answers
   - Ask Peat — this page (AI chat)
   - Tools — utility calculators (ABV, dilution, etc.)
7. Insights:
   - Reports — production and sales reporting

KEY WORKFLOWS:
- Adding a label SKU: Dry Goods → "Add SKU" button → set Category = Label → fill in description, volume (ml), ABV (%), region, barcode, supplier, photo. The description/name should be the label's actual product name only (e.g. "Smoky Joe Bourbon Front Label") — do NOT include the volume or ABV in the name because Pulse stores those in dedicated fields (Volume ml and ABV %) and displays them separately alongside the name. Putting volume in the name is redundant and inconsistent.
- Adding a BOM: clients do this from their portal; staff see submitted BOMs in the BOMs page and approve them in Approvals
- Creating a job: Jobs → "New Job" button → attach client, BOM, schedule dates, assign tasks
- Adding a client: Customers → "New Customer" button
- Adding a deal: Pipeline → "New Deal" button

RULES:
- ONLY refer to pages and buttons that exist in the list above.
- If a user asks how to do something and you are not certain of the exact steps in Pulse, say: "I'm not certain of the exact steps for that in Pulse — you may want to check with your admin or upload a user guide to my Knowledge Base so I can answer more accurately."
- Never invent page names, menu items, or buttons.
- Be concise, practical and direct. Show working for all calculations.
- Never reveal other clients' data or commercially sensitive information to non-admin users.`;

const CLIENT_SYSTEM_PROMPT = `You are Peat, the AI assistant for Lighthouse Drinks clients.

You can help clients with:
- Understanding their jobs, production status, and BOMs in the client portal
- General questions about the bottling process and what to expect
- Spirits industry questions (ABV, labelling requirements, bottle formats, general compliance)
- How to use the Lighthouse client portal

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
    // Auth check
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

    // Determine actual role from DB (don't trust client-sent is_client alone)
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('role')
      .eq('auth_user_id', user.id)
      .maybeSingle();

    // Portal clients won't have an app_users row — that's fine
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
      // RAG is best-effort — if it fails, Claude still answers from training knowledge
      console.warn('RAG search failed (continuing without context):', ragErr);
    }

    // Build messages array for Claude
    const messages: ChatMessage[] = [
      ...history.slice(-10), // keep last 10 turns of context
      { role: 'user', content: message },
    ];

    // Prepend retrieved context to the user's latest message if available
    if (contextText) {
      messages[messages.length - 1] = {
        role: 'user',
        content: message + contextText,
      };
    }

    // Call Anthropic API with streaming
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

    // Stream the response back to the client as SSE
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
