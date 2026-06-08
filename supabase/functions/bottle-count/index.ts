import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function jsonResponse(obj: unknown, status: number): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, 'content-type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const url = new URL(req.url);

  // Token may arrive as a Bearer header (POST from a script / curl) or as a
  // ?token= query param. The Shelly app's webhook screen can only send a plain
  // GET URL with no headers or body, so the query-param form lets it work too.
  const headerToken = (req.headers.get('authorization') || '').replace(/^bearer\s+/i, '').trim();
  const queryToken  = (url.searchParams.get('token') || '').trim();
  const token = headerToken || queryToken;

  if (!token || token !== Deno.env.get('BOTTLE_COUNT_SECRET')) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  // Params arrive in the JSON body (POST) or the query string (GET)
  let lineId = '';
  let count = 1;

  if (req.method === 'POST') {
    let body: { line_id?: string; count?: number };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: 'Invalid JSON' }, 400);
    }
    lineId = String(body.line_id ?? '').trim();
    count  = Number(body.count ?? 1);
  } else {
    lineId = String(url.searchParams.get('line_id') ?? '').trim();
    count  = Number(url.searchParams.get('count') ?? 1);
  }

  if (!lineId) {
    return jsonResponse({ error: 'line_id is required' }, 400);
  }
  if (!Number.isFinite(count) || count <= 0) count = 1;

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Look up the currently active job for this bay/line
  const { data: activeJobs } = await supabase
    .from('jobs')
    .select('id')
    .eq('job_bay', Number(lineId) || lineId)
    .not('actual_start', 'is', null)
    .is('actual_end', null)
    .limit(1);

  const jobId = activeJobs && activeJobs.length > 0 ? activeJobs[0].id : null;

  const { error } = await supabase
    .from('line_events')
    .insert({ line_id: lineId, job_id: jobId, count });

  if (error) {
    return jsonResponse({ error: error.message }, 500);
  }

  return jsonResponse({ ok: true, line_id: lineId, count, job_id: jobId }, 200);
});
