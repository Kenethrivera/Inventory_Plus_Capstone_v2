CREATE OR REPLACE FUNCTION public.assign_order_helper_v1 (
  p_session_token      text,
  p_order_id           uuid,
  p_helper_id          text,
  p_expected_helper_id text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_helper public.profiles;
  v_order public.orders;
  v_helper_id text := nullif(trim(coalesce(p_helper_id, '')), '');
  v_expected_helper_id text := nullif(trim(coalesce(p_expected_helper_id, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Assignment session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then raise exception 'assignment_not_allowed'; end if;

  select helper.* into v_helper
  from public.profiles helper
  where helper.id::text = v_helper_id
    and helper.location_id = v_profile.location_id
    and lower(helper.role) = 'helper';
  if not found then raise exception 'assignment_helper_unavailable'; end if;

  update public.orders customer_order
  set assigned_helper_id = v_helper.id::text,
      assigned_helper_name = v_helper.name,
      assigned_at = now(),
      assigned_by_admin_id = v_profile.profile_id::text,
      assigned_by_admin_name = v_profile.profile_name,
      updated_at = now()
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and customer_order.status = 'pending'
    and customer_order.assigned_helper_id is not distinct from v_expected_helper_id
  returning customer_order.* into v_order;

  if found then
    return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
  end if;
  raise exception 'order_assignment_conflict';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.assign_order_helper_v1(text, uuid, text, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.assign_order_helper_v1(text, uuid, text, text)
  FROM PUBLIC, authenticated;
