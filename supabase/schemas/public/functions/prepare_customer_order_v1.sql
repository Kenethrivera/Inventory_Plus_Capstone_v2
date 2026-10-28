CREATE OR REPLACE FUNCTION public.prepare_customer_order_v1 (
  p_session_token   text,
  p_order_id        uuid,
  p_expected_status text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_order public.orders;
  v_expected_status text := lower(trim(coalesce(p_expected_status, '')));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Preparation session is invalid or expired'; end if;
  if v_expected_status not in ('pending', 'solo_picking') then
    raise exception 'order_preparation_conflict';
  end if;

  update public.orders customer_order
  set status = 'prepared',
      prepared_by = v_profile.profile_id,
      prepared_by_id = v_profile.profile_id::text,
      prepared_by_name = v_profile.profile_name,
      prepared_at = now(),
      updated_at = now()
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and customer_order.status = v_expected_status
    and (v_expected_status <> 'pending'
      or v_profile.role <> 'helper'
      or customer_order.assigned_helper_id = v_profile.profile_id::text)
  returning customer_order.* into v_order;

  if not found then
    select customer_order.* into v_order
    from public.orders customer_order
    where customer_order.id = p_order_id
      and customer_order.location_id = v_profile.location_id;
    if not found
        or v_order.status <> 'prepared'
        or v_order.prepared_by_id is distinct from v_profile.profile_id::text then
      raise exception 'order_preparation_conflict';
    end if;
  end if;
  return to_jsonb(v_order);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.prepare_customer_order_v1(text, uuid, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.prepare_customer_order_v1(text, uuid, text)
  FROM PUBLIC, authenticated;
