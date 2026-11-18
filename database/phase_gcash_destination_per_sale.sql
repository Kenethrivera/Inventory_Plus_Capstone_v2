-- Run after phase_secondary_gcash_account.sql. Records which QR each sale used.
alter table public.orders
  add column if not exists gcash_destination_slot text,
  add column if not exists gcash_destination_name text,
  add column if not exists gcash_destination_number text;

alter table public.order_history
  add column if not exists gcash_destination_slot text,
  add column if not exists gcash_destination_name text,
  add column if not exists gcash_destination_number text;

do $block$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.orders'::regclass
      and conname = 'orders_gcash_destination_slot_check'
  ) then
    alter table public.orders
      add constraint orders_gcash_destination_slot_check
      check (gcash_destination_slot is null or
             gcash_destination_slot in ('primary', 'alternate'));
  end if;
end;
$block$;

create index if not exists orders_gcash_destination_history_idx
  on public.orders (location_id, gcash_destination_slot, completed_at desc)
  where status = 'completed' and lower(trim(payment_mode)) = 'gcash';

create or replace function public.sync_gcash_destination_history_v1()
returns trigger language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  update public.order_history set
    gcash_destination_slot = new.gcash_destination_slot,
    gcash_destination_name = new.gcash_destination_name,
    gcash_destination_number = new.gcash_destination_number
  where order_id = new.id::text;
  return new;
end;
$function$;

drop trigger if exists zz_orders_sync_gcash_destination_v1 on public.orders;
create trigger zz_orders_sync_gcash_destination_v1
after update of gcash_destination_slot, gcash_destination_name,
  gcash_destination_number on public.orders
for each row execute function public.sync_gcash_destination_history_v1();

update public.order_history history set
  gcash_destination_slot = orders.gcash_destination_slot,
  gcash_destination_name = orders.gcash_destination_name,
  gcash_destination_number = orders.gcash_destination_number
from public.orders orders
where history.order_id = orders.id::text
  and orders.gcash_destination_slot is not null;

revoke all on function public.sync_gcash_destination_history_v1()
  from public, anon, authenticated;
grant execute on function public.sync_gcash_destination_history_v1()
  to service_role, postgres;

create or replace function public.complete_customer_order_v2(
  p_session_token text,
  p_order_id uuid,
  p_payment_mode text,
  p_cash_given double precision,
  p_change_amount double precision,
  p_payment_reference text,
  p_gcash_account_slot text,
  p_gcash_destination_name text,
  p_gcash_destination_number text
) returns jsonb
language plpgsql security definer
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

  -- The original completion function locks and validates the order, then
  -- records the payment and reference. This wrapper runs in one transaction.
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

-- Checkout asks this read-only function before offering the backup QR.
create or replace function public.gcash_destination_feature_ready_v1()
returns boolean language sql stable
set search_path to 'public', 'pg_temp'
as $function$ select true $function$;

grant execute on function public.gcash_destination_feature_ready_v1()
  to anon, authenticated, service_role, postgres;
