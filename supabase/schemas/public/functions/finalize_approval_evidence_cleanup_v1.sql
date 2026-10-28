CREATE OR REPLACE FUNCTION public.finalize_approval_evidence_cleanup_v1 (
  p_session_token text,
  p_storage_paths text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_deleted integer;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;

  delete from private.approval_evidence_uploads upload
  where upload.location_id = v_profile.location_id
    and upload.cleanup_claimed_at is not null
    and upload.storage_path = any(coalesce(p_storage_paths, '{}'::text[]))
    and not exists (
      select 1 from public.approval_requests request
      where request.proof_storage_path = upload.storage_path
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.finalize_approval_evidence_cleanup_v1(text, text[])
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.finalize_approval_evidence_cleanup_v1(text, text[])
  FROM PUBLIC, authenticated;
