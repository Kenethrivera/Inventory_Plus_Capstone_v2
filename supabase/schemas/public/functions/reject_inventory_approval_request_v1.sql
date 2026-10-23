CREATE OR REPLACE FUNCTION public.reject_inventory_approval_request_v1 (
  p_session_token text,
  p_request_id    uuid,
  p_review_note   text DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
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
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may reject stock changes';
  end if;

  select request.* into v_request
  from public.approval_requests request
  where request.id = p_request_id
  for update;

  if not found then raise exception 'Approval request not found'; end if;
  if v_request.location_id <> v_profile.location_id then
    raise exception 'Approval request is outside the active location';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'Approval request is already %', v_request.status;
  end if;

  update public.approval_requests
  set status = 'rejected',
      reviewed_by_id = v_profile.profile_id,
      reviewed_by_name = v_profile.profile_name,
      reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_review_note, '')), '')
  where id = v_request.id
  returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);

  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."reject_inventory_approval_request_v1"(text, uuid, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."reject_inventory_approval_request_v1"(text, uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."reject_inventory_approval_request_v1"(text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."reject_inventory_approval_request_v1"(text, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."reject_inventory_approval_request_v1"(text, uuid, text) FROM PUBLIC, "authenticated";
