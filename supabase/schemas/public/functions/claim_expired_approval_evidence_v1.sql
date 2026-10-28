CREATE OR REPLACE FUNCTION public.claim_expired_approval_evidence_v1 (
  p_session_token text,
  p_limit         integer DEFAULT 25
)
  RETURNS TABLE (storage_path text)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;

  return query
  with candidates as (
    select upload.id
    from private.approval_evidence_uploads upload
    where upload.location_id = v_profile.location_id
      and (upload.cleanup_claimed_at is not null
        or upload.expires_at <= now() - interval '1 hour')
      and not exists (
        select 1 from public.approval_requests request
        where request.proof_storage_path = upload.storage_path
      )
    order by coalesce(upload.cleanup_claimed_at, upload.expires_at), upload.id
    limit v_limit
    for update skip locked
  ), claimed as (
    update private.approval_evidence_uploads upload
    set cleanup_claimed_at = coalesce(upload.cleanup_claimed_at, now())
    where upload.id in (select candidate.id from candidates candidate)
    returning upload.storage_path
  )
  select claimed.storage_path from claimed;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.claim_expired_approval_evidence_v1(text, integer)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.claim_expired_approval_evidence_v1(text, integer)
  FROM PUBLIC, authenticated;
