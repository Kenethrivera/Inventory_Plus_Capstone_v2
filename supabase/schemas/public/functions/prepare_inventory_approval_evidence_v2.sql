CREATE OR REPLACE FUNCTION public.prepare_inventory_approval_evidence_v2 (
  p_session_token text,
  p_operation_id  text,
  p_file_name     text,
  p_mime_type     text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_upload private.approval_evidence_uploads;
  v_request public.approval_requests;
  v_operation_id text := nullif(trim(coalesce(p_operation_id, '')), '');
  v_file_name text := nullif(trim(coalesce(p_file_name, '')), '');
  v_mime_type text := lower(nullif(trim(coalesce(p_mime_type, '')), ''));
  v_extension text;
  v_storage_path text;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may upload proof';
  end if;
  if v_operation_id is null or length(v_operation_id) < 16 then
    raise exception 'evidence_operation_invalid';
  end if;
  if v_file_name is null or length(v_file_name) > 255 then
    raise exception 'A valid proof file name is required';
  end if;
  v_extension := case v_mime_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'image/gif' then 'gif'
    else null
  end;
  if v_extension is null then
    raise exception 'Only JPG, PNG, WebP, or GIF proof images are allowed';
  end if;

  -- Serialize with create_inventory_approval_request_v2. A retry must observe
  -- a committed request before it can recreate or overwrite its evidence.
  perform pg_advisory_xact_lock(hashtextextended(
    'inventory-approval:' || v_operation_id,
    0
  ));
  select request.* into v_request
  from public.approval_requests request
  where request.submission_operation_id = v_operation_id
    and request.location_id = v_profile.location_id
    and request.requested_by_id = v_profile.profile_id;
  if found and v_request.proof_storage_path is not null then
    return jsonb_build_object(
      'storage_path', v_request.proof_storage_path,
      'file_name', v_request.proof_file_name,
      'mime_type', v_request.proof_mime_type,
      'expires_at', null,
      'already_submitted', true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'approval-evidence:' || v_profile.location_id::text || ':' ||
      v_profile.profile_id::text || ':' || v_operation_id,
    0
  ));
  select upload.* into v_upload
  from private.approval_evidence_uploads upload
  where upload.location_id = v_profile.location_id
    and upload.requested_by_id = v_profile.profile_id
    and upload.operation_id = v_operation_id
  for update;
  if found then
    if v_upload.cleanup_claimed_at is not null then
      raise exception 'evidence_upload_expired';
    end if;
    if v_upload.mime_type <> v_mime_type then
      raise exception 'evidence_operation_conflict';
    end if;
    update private.approval_evidence_uploads upload
    set expires_at = now() + interval '15 minutes',
        file_name = v_file_name
    where upload.id = v_upload.id
    returning * into v_upload;
  else
    v_storage_path := v_profile.location_id::text || '/' ||
      v_profile.profile_id::text || '/' ||
      encode(extensions.digest(convert_to(v_operation_id, 'UTF8'), 'sha256'), 'hex') ||
      '.' || v_extension;
    insert into private.approval_evidence_uploads (
      location_id, requested_by_id, storage_path, file_name, mime_type,
      operation_id
    ) values (
      v_profile.location_id, v_profile.profile_id, v_storage_path,
      v_file_name, v_mime_type, v_operation_id
    ) returning * into v_upload;
  end if;

  return jsonb_build_object(
    'storage_path', v_upload.storage_path,
    'file_name', v_upload.file_name,
    'mime_type', v_upload.mime_type,
    'expires_at', v_upload.expires_at,
    'already_submitted', false
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.prepare_inventory_approval_evidence_v2(
  text, text, text, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.prepare_inventory_approval_evidence_v2(
  text, text, text, text
) FROM PUBLIC, authenticated;
