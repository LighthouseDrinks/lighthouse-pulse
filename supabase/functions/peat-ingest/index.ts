// peat-ingest — Supabase Edge Function
// Receives pre-extracted text from the client (PDF.js handles PDF extraction browser-side),
// chunks it, embeds each chunk using the Supabase gte-small model, stores in peat_chunks.
//
// Deploy via Supabase Dashboard > Edge Functions > New function > paste this file.
// No secrets needed for this function (uses the service role key from the runtime env).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const CHUNK_SIZE  = 500;  // target chars per chunk (not tokens — simpler, close enough)
const CHUNK_OVERLAP = 80; // overlap between consecutive chunks

function chunkText(text: string): string[] {
  const chunks: string[] = [];
  let start = 0;
  while (start < text.length) {
    const end = Math.min(start + CHUNK_SIZE, text.length);
    chunks.push(text.slice(start, end).trim());
    if (end === text.length) break;
    start = end - CHUNK_OVERLAP;
  }
  return chunks.filter(c => c.length > 20); // drop tiny trailing chunks
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    // Auth check — must be admin or manager
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return new Response('Unauthorized', { status: 401, headers: corsHeaders });

    const supabaseUrl  = Deno.env.get('SUPABASE_URL')!;
    const serviceKey   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const anonKey      = Deno.env.get('SUPABASE_ANON_KEY')!;

    // Verify the caller's JWT
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return new Response('Unauthorized', { status: 401, headers: corsHeaders });

    // Check role via app_users table
    const adminClient = createClient(supabaseUrl, serviceKey);
    const { data: appUser } = await adminClient
      .from('app_users')
      .select('role')
      .eq('auth_user_id', user.id)
      .single();

    if (!appUser || !['admin', 'manager'].includes(appUser.role)) {
      return new Response('Forbidden — admin/manager only', { status: 403, headers: corsHeaders });
    }

    const body = await req.json() as {
      name: string;
      file_type: string;
      text: string;
    };

    if (!body.name || !body.text) {
      return new Response('Missing name or text', { status: 400, headers: corsHeaders });
    }

    const cleanText = body.text.replace(/\s+/g, ' ').trim();
    const chunks    = chunkText(cleanText);

    // Insert document record
    const { data: doc, error: docErr } = await adminClient
      .from('peat_documents')
      .insert({
        name:        body.name,
        file_type:   body.file_type || 'txt',
        char_count:  cleanText.length,
        uploaded_by: user.id,
      })
      .select()
      .single();

    if (docErr) throw docErr;

    // Embed and store each chunk using Supabase's built-in gte-small model
    const session = new Supabase.ai.Session('gte-small');

    const chunkRows = [];
    for (let i = 0; i < chunks.length; i++) {
      const embedding = await session.run(chunks[i], {
        mean_pool: true,
        normalize: true,
      });
      chunkRows.push({
        document_id: doc.id,
        content:     chunks[i],
        embedding:   Array.from(embedding as number[]),
        chunk_index: i,
      });
    }

    const { error: chunkErr } = await adminClient
      .from('peat_chunks')
      .insert(chunkRows);

    if (chunkErr) throw chunkErr;

    return new Response(
      JSON.stringify({ success: true, document_id: doc.id, chunks: chunks.length }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('peat-ingest error:', err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
