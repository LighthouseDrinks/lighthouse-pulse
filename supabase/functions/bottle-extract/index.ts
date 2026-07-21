// bottle-extract — Supabase Edge Function
//
// Backs the Tools -> Shipper & Pallet Planner drawing upload. The browser sends
// a base64-encoded bottle technical drawing (PDF or image); this function proxies
// it to the Anthropic Messages API with a fixed extraction instruction and returns
// ONLY the parsed JSON dimensions. The Anthropic key never touches the client.
//
// Deploy: supabase functions deploy bottle-extract
// Required secret: ANTHROPIC_API_KEY (already configured for peat-chat).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Exact instruction text from the module brief — JSON-only output.
const INSTRUCTION = `This is a glass bottle technical drawing. Extract ONLY what a case/carton designer needs. Respond with ONLY a JSON object, no markdown, no preamble:
{"body_diameter_mm":number|null,"total_height_mm":number|null,"glass_weight_g":number|null,"fill_volume_ml":number|null,"notes":"short string"}
Rules: body_diameter_mm is the widest body diameter of the bottle (not the finish/cap). total_height_mm is overall glass height to the lip. glass_weight_g is the stated empty bottle weight (may be listed in g or kg). fill_volume_ml is brimful or nominal capacity — prefer nominal. Use null for anything not stated. Convert units to mm/g/ml.`;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Normalise the incoming mime type to something Anthropic accepts, and decide
// whether it is a document (PDF) or an image content block.
function classifyMime(mime: string): { kind: 'image' | 'document'; mediaType: string } | null {
  const m = (mime || '').toLowerCase();
  if (m === 'application/pdf') return { kind: 'document', mediaType: 'application/pdf' };
  if (m === 'image/jpg' || m === 'image/jpeg') return { kind: 'image', mediaType: 'image/jpeg' };
  if (m === 'image/png') return { kind: 'image', mediaType: 'image/png' };
  if (m === 'image/gif') return { kind: 'image', mediaType: 'image/gif' };
  if (m === 'image/webp') return { kind: 'image', mediaType: 'image/webp' };
  return null;
}

// Strip accidental ```json fences / preamble and parse the first JSON object.
function parseModelJson(text: string): Record<string, unknown> | null {
  if (!text) return null;
  let t = text.trim();
  t = t.replace(/^```(?:json)?/i, '').replace(/```$/i, '').trim();
  try {
    return JSON.parse(t);
  } catch (_) {
    const start = t.indexOf('{');
    const end = t.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try { return JSON.parse(t.slice(start, end + 1)); } catch (_) { /* fall through */ }
    }
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Unauthorized' }, 401);

    const supabaseUrl  = Deno.env.get('SUPABASE_URL')!;
    const anonKey      = Deno.env.get('SUPABASE_ANON_KEY')!;
    const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY') || '';

    if (!anthropicKey) return json({ error: 'ANTHROPIC_API_KEY not configured' }, 500);

    // Require an authenticated Pulse user (staff tool).
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return json({ error: 'Unauthorized' }, 401);

    const body = await req.json().catch(() => ({})) as {
      fileBase64?: string; mimeType?: string; fileName?: string;
    };
    const fileBase64 = (body.fileBase64 || '').trim();
    if (!fileBase64) return json({ error: 'No file provided' }, 400);

    const cls = classifyMime(body.mimeType || '');
    if (!cls) return json({ error: 'Unsupported file type — use PDF, PNG or JPEG.' }, 400);

    const fileBlock = cls.kind === 'document'
      ? { type: 'document', source: { type: 'base64', media_type: cls.mediaType, data: fileBase64 } }
      : { type: 'image',    source: { type: 'base64', media_type: cls.mediaType, data: fileBase64 } };

    const anthropicRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': anthropicKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-5',
        max_tokens: 512,
        messages: [
          { role: 'user', content: [ fileBlock, { type: 'text', text: INSTRUCTION } ] },
        ],
      }),
    });

    if (!anthropicRes.ok) {
      const errText = await anthropicRes.text();
      console.error('[bottle-extract] Anthropic error', anthropicRes.status, errText);
      return json({ error: `Anthropic API error ${anthropicRes.status}` }, 502);
    }

    const payload = await anthropicRes.json();
    const text = Array.isArray(payload?.content)
      ? payload.content.filter((c: { type?: string }) => c?.type === 'text')
          .map((c: { text?: string }) => c.text || '').join('\n')
      : '';

    const parsed = parseModelJson(text);
    if (!parsed) {
      console.error('[bottle-extract] could not parse model output:', text);
      return json({ error: 'Could not parse extraction result' }, 502);
    }

    const num = (v: unknown): number | null => {
      if (v === null || v === undefined || v === '') return null;
      const n = typeof v === 'number' ? v : parseFloat(String(v));
      return Number.isFinite(n) ? n : null;
    };

    return json({
      body_diameter_mm: num(parsed.body_diameter_mm),
      total_height_mm:  num(parsed.total_height_mm),
      glass_weight_g:   num(parsed.glass_weight_g),
      fill_volume_ml:   num(parsed.fill_volume_ml),
      notes:            typeof parsed.notes === 'string' ? parsed.notes.slice(0, 300) : '',
    });

  } catch (e) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    console.error('[bottle-extract] error:', message);
    return json({ error: message }, 500);
  }
});
