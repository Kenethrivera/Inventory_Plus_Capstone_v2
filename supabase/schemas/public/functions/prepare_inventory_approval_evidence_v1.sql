CREATE OR REPLACE FUNCTION public.prepare_inventory_approval_evidence_v1 (
  p_session_token text,
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
  v_file_name text := nullif(trim(coalesce(p_file_name, '')), '');
  v_mime_type text := lower(nullif(trim(coalesce(p_mime_type, '')), ''));
  v_extension text;
  v_upload_id uuid := extensions.gen_random_uuid();
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may upload proof';
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

  insert into private.approval_evidence_uploads (
    id, location_id, requested_by_id, storage_path, file_name, mime_type
  ) values (
    v_upload_id,
    v_profile.location_id,
    v_profile.profile_id,
    v_profile.location_id::text || '/' || v_profile.profile_id::text || '/' ||
      v_upload_id::text || '.' || v_extension,
    v_file_name,
    v_mime_type
  ) returning * into v_upload;

  return jsonb_build_object(
    'storage_path', v_upload.storage_path,
    'file_name', v_upload.file_name,
    'mime_type', v_upload.mime_type,
    'expires_at', v_upload.expires_at
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) FROM PUBLIC, "authenticated";
