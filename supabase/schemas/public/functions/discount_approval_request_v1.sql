CREATE OR REPLACE FUNCTION public.discount_approval_request_v1 (
  p_session_token text,
  p_request_id    uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_request public.approval_requests;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;

  select request.* into v_request
  from public.approval_requests request
  where request.id = p_request_id
    and request.request_type = 'discount'
    and request.location_id = v_profile.location_id
    and (v_profile.role = 'admin'
      or request.requested_by_id = v_profile.profile_id);
  if not found then raise exception 'Discount approval request not found'; end if;
  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."discount_approval_request_v1"(text, uuid) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."discount_approval_request_v1"(text, uuid) TO "service_role";

REVOKE ALL ON FUNCTION "public"."discount_approval_request_v1"(text, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."discount_approval_request_v1"(text, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "public"."discount_approval_request_v1"(text, uuid) FROM PUBLIC, "authenticated";
