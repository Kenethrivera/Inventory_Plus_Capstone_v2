import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, apikey, content-type, x-client-info, x-app-session-token',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const hasImageSignature = (bytes: Uint8Array, mimeType: string) => {
  if (mimeType === 'image/jpeg') {
    return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  }
  if (mimeType === 'image/png') {
    return bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 &&
      bytes[2] === 0x4e && bytes[3] === 0x47;
  }
  const text = new TextDecoder().decode(bytes.slice(0, 12));
  if (mimeType === 'image/gif') return text.startsWith('GIF87a') || text.startsWith('GIF89a');
  return mimeType === 'image/webp' && text.startsWith('RIFF') && text.slice(8, 12) === 'WEBP';
};

const cleanupExpiredEvidence = async (
  admin: ReturnType<typeof createClient>,
  sessionToken: string,
) => {
  const { data, error } = await admin.rpc('claim_expired_approval_evidence_v1', {
    p_session_token: sessionToken,
    p_limit: 25,
  });
  if (error || !Array.isArray(data) || data.length === 0) return;
  const paths = data
    .map((row) => row?.storage_path?.toString())
    .filter((path): path is string => Boolean(path));
  if (paths.length === 0) return;

  const { error: removeError } = await admin.storage
    .from('approval_evidence')
    .remove(paths);
  if (removeError) return;
  await admin.rpc('finalize_approval_evidence_cleanup_v1', {
    p_session_token: sessionToken,
    p_storage_paths: paths,
  });
};

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const sessionToken = request.headers.get('x-app-session-token')?.trim();
  if (!sessionToken) return json({ error: 'Missing application session' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: 'Evidence service is not configured' }, 500);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const contentType = request.headers.get('content-type') ?? '';
    if (contentType.includes('multipart/form-data')) {
      const form = await request.formData();
      if (form.get('action') !== 'upload') {
        return json({ error: 'Unsupported evidence action' }, 400);
      }
      const file = form.get('file');
      const fileName = form.get('fileName')?.toString().trim() ?? '';
      const mimeType = form.get('mimeType')?.toString().trim().toLowerCase() ?? '';
      const operationId = form.get('operationId')?.toString().trim() ?? '';
      if (!(file instanceof File) || file.size === 0 || file.size > 10 * 1024 * 1024) {
        return json({ error: 'Proof image must be between 1 byte and 10 MB' }, 400);
      }
      if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(mimeType)) {
        return json({ error: 'Unsupported proof image type' }, 400);
      }
      if (operationId.length < 16) {
        return json({ error: 'Unable to complete the upload. Please try again.' }, 400);
      }
      const bytes = new Uint8Array(await file.arrayBuffer());
      if (!hasImageSignature(bytes, mimeType)) {
        return json({ error: 'The selected file is not a valid image' }, 400);
      }

      await cleanupExpiredEvidence(admin, sessionToken);
      const { data: intent, error: intentError } = await admin.rpc(
        'prepare_inventory_approval_evidence_v2',
        {
          p_session_token: sessionToken,
          p_operation_id: operationId,
          p_file_name: fileName,
          p_mime_type: mimeType,
        },
      );
      if (intentError || !intent?.storage_path) {
        return json({ error: 'Unable to complete the upload. Please try again.' }, 403);
      }

      if (intent.already_submitted === true) {
        return json({
          storagePath: intent.storage_path,
          fileName: intent.file_name,
          mimeType: intent.mime_type,
        });
      }

      const { error: uploadError } = await admin.storage
        .from('approval_evidence')
        .upload(intent.storage_path, new Blob([bytes], { type: mimeType }), {
          contentType: mimeType,
          upsert: true,
        });
      if (uploadError) {
        return json({ error: 'Unable to complete the upload. Please try again.' }, 400);
      }

      return json({
        storagePath: intent.storage_path,
        fileName: intent.file_name,
        mimeType: intent.mime_type,
      });
    }

    const body = await request.json();
    if (body?.action !== 'signedUrl' || typeof body?.requestId !== 'string') {
      return json({ error: 'Unsupported evidence action' }, 400);
    }
    const { data: storagePath, error: accessError } = await admin.rpc(
      'inventory_approval_evidence_access_v1',
      { p_session_token: sessionToken, p_request_id: body.requestId },
    );
    if (accessError) return json({ error: 'Approval evidence is unavailable' }, 403);
    if (!storagePath) return json({ signedUrl: null });

    const { data: signed, error: signedError } = await admin.storage
      .from('approval_evidence')
      .createSignedUrl(storagePath, 300);
    if (signedError) return json({ error: 'Approval evidence is unavailable' }, 404);
    return json({ signedUrl: signed.signedUrl });
  } catch (error) {
    return json({ error: 'Unable to complete the request. Please try again.' }, 500);
  }
});
