CREATE OR REPLACE FUNCTION public.inventory_approval_evidence_access_v1 (
  p_session_token text,
  p_request_id    uuid
)
  RETURNS text
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_request public.approval_requests;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  select request.* into v_request
  from public.approval_requests request
  where request.id = p_request_id;
  if not found or v_request.location_id <> v_profile.location_id then
    raise exception 'Approval evidence is unavailable';
  end if;
  if v_profile.role <> 'admin'
      and v_request.requested_by_id <> v_profile.profile_id then
    raise exception 'Approval evidence is unavailable';
  end if;
  return v_request.proof_storage_path;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."inventory_approval_evidence_access_v1"(text, uuid) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."inventory_approval_evidence_access_v1"(text, uuid) TO "service_role";

REVOKE ALL ON FUNCTION "public"."inventory_approval_evidence_access_v1"(text, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."inventory_approval_evidence_access_v1"(text, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "public"."inventory_approval_evidence_access_v1"(text, uuid) FROM PUBLIC, "authenticated";
