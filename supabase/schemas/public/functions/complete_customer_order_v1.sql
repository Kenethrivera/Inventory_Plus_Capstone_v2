CREATE OR REPLACE FUNCTION public.complete_customer_order_v1 (
  p_session_token     text,
  p_order_id          uuid,
  p_payment_mode      text,
  p_cash_given        double precision,
  p_change_amount     double precision,
  p_payment_reference text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_order public.orders;
  v_payment_mode text;
  v_payment_reference text;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Payment session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot complete payments';
  end if;

  select customer_order.* into v_order
  from public.orders customer_order
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
  for update;
  if not found then raise exception 'order_not_prepared'; end if;

  if v_order.status = 'completed' then
    raise exception 'order_already_completed';
  end if;
  if v_order.status <> 'prepared' then
    raise exception 'order_not_prepared';
  end if;

  v_payment_mode := coalesce(
    nullif(trim(p_payment_mode), ''),
    nullif(trim(v_order.payment_mode), ''),
    'Cash'
  );
  v_payment_reference := case
    when lower(v_payment_mode) = 'gcash'
      then nullif(trim(p_payment_reference), '')
    else null
  end;
  if lower(v_payment_mode) = 'gcash'
      and (v_payment_reference is null
        or v_payment_reference !~ '^[0-9]{10,13}$') then
    raise exception 'payment_reference_invalid';
  end if;

  if v_payment_reference is not null and exists (
    select 1
    from public.orders other_order
    where other_order.location_id = v_profile.location_id
      and other_order.status = 'completed'
      and lower(trim(other_order.payment_mode)) = 'gcash'
      and lower(trim(other_order.payment_reference)) =
        lower(v_payment_reference)
      and other_order.id <> v_order.id
  ) then
    raise exception 'payment_reference_already_used';
  end if;

  begin
    update public.orders customer_order
    set status = 'completed',
        completed_at = now(),
        completed_by_id = v_profile.profile_id::text,
        completed_by_name = v_profile.profile_name,
        payment_mode = v_payment_mode,
        cash_given = coalesce(p_cash_given, customer_order.cash_given),
        change_amount = coalesce(
          p_change_amount, customer_order.change_amount),
        payment_reference = v_payment_reference
    where customer_order.id = v_order.id
      and customer_order.status = 'prepared'
    returning customer_order.* into v_order;
  exception when unique_violation then
    raise exception 'payment_reference_already_used';
  end;

  if not found then raise exception 'order_not_prepared'; end if;
  return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.complete_customer_order_v1(
  text, uuid, text, double precision, double precision, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.complete_customer_order_v1(
  text, uuid, text, double precision, double precision, text
) FROM PUBLIC, authenticated;
