import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  // Bearer token auth — the Shelly sends this in its webhook header
  const authHeader = req.headers.get('authorization') || '';
  const token = authHeader.replace(/^bearer\s+/i, '').trim();
  if (!token || token !== Deno.env.get('BOTTLE_COUNT_SECRET')) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...CORS, 'content-type': 'application/json' },
    });
  }

  let body: { line_id?: string; count?: number };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), {
      status: 400,
      headers: { ...CORS, 'content-type': 'application/json' },
    });
  }

  const lineId = String(body.line_id ?? '').trim();
  const count  = Number(body.count ?? 1);

  if (!lineId) {
    return new Response(JSON.stringify({ error: 'line_id is required' }), {
      status: 400,
      headers: { ...CORS, 'content-type': 'application/json' },
    });
  }

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
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...CORS, 'content-type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ ok: true, line_id: lineId, count, job_id: jobId }), {
    status: 200,
    headers: { ...CORS, 'content-type': 'application/json' },
  });
});
