-- See database/phase_gcash_destination_per_sale.sql for the deployment migration.
create or replace function public.complete_customer_order_v2(
  p_session_token text, p_order_id uuid, p_payment_mode text,
  p_cash_given double precision, p_change_amount double precision,
  p_payment_reference text, p_gcash_account_slot text,
  p_gcash_destination_name text, p_gcash_destination_number text
) returns jsonb language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_result jsonb;
  v_order public.orders%rowtype;
  v_slot text;
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Payment session is invalid or expired'; end if;
  if p_payment_mode is null or trim(p_payment_mode) = '' then
    raise exception 'Payment mode is required';
  end if;
  if lower(trim(p_payment_mode)) = 'gcash' then
    v_slot := lower(trim(coalesce(p_gcash_account_slot, '')));
    if v_slot not in ('primary', 'alternate') then
      raise exception 'Choose a GCash destination';
    end if;
    if length(trim(coalesce(p_gcash_destination_name, ''))) > 120 or
       length(trim(coalesce(p_gcash_destination_number, ''))) > 32 then
      raise exception 'GCash destination details are too long';
    end if;
  else
    v_slot := null;
  end if;
  v_result := public.complete_customer_order_v1(
    p_session_token, p_order_id, p_payment_mode, p_cash_given,
    p_change_amount, p_payment_reference
  );
  if v_result ->> 'reused' = 'true' then return v_result; end if;
  update public.orders customer_order set
    gcash_destination_slot = v_slot,
    gcash_destination_name = case when v_slot is null then null
      else nullif(trim(p_gcash_destination_name), '') end,
    gcash_destination_number = case when v_slot is null then null
      else nullif(trim(p_gcash_destination_number), '') end
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and customer_order.status = 'completed'
  returning * into v_order;
  if not found then raise exception 'order_not_prepared'; end if;
  return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
end;
$function$;

grant execute on function public.complete_customer_order_v2(
  text, uuid, text, double precision, double precision, text, text, text, text
) to anon, service_role, postgres;
revoke all on function public.complete_customer_order_v2(
  text, uuid, text, double precision, double precision, text, text, text, text
) from public, authenticated;
