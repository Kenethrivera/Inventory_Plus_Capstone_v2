-- Phase B1: transactional/idempotent P0 operations.
-- Run this file once in the Supabase SQL editor. Do not run function sections
-- separately: the surrounding transaction keeps deployment atomic.

begin;

alter table public.orders
  add column if not exists checkout_operation_id text;

alter table public.transaction_history
  add column if not exists operation_id text;

alter table public.transaction_history
  add column if not exists operation_scope text;

do $preflight$
begin
  if exists (
    select 1
    from public.orders customer_order
    where customer_order.status = 'completed'
      and customer_order.location_id is not null
      and lower(trim(customer_order.payment_mode)) = 'gcash'
      and nullif(trim(customer_order.payment_reference), '') is not null
    group by customer_order.location_id,
      lower(trim(customer_order.payment_reference))
    having count(*) > 1
  ) then
    raise exception
      'Existing duplicate completed GCash references must be resolved before Phase B1 deployment';
  end if;
end;
$preflight$;

create unique index if not exists orders_checkout_operation_unique
  on public.orders (checkout_operation_id)
  where checkout_operation_id is not null;

create unique index if not exists orders_completed_gcash_reference_unique
  on public.orders (location_id, lower(trim(payment_reference)))
  where status = 'completed'
    and lower(trim(payment_mode)) = 'gcash'
    and payment_reference is not null
    and trim(payment_reference) <> '';

create unique index if not exists transaction_history_operation_unique
  on public.transaction_history (
    location_id, operation_id, product_id, transaction_type
  )
  where operation_id is not null;

create unique index if not exists
  transaction_history_inventory_adjustment_operation_unique
  on public.transaction_history (operation_id)
  where operation_scope = 'inventory_adjustment'
    and operation_id is not null;

-- Legacy checkout contract retained for already-deployed clients. This RPC
-- creates the order and consumes discount approval, but does not deduct stock.
create or replace function public.create_customer_order_v1 (
  p_session_token text,
  p_items jsonb,
  p_total_amount numeric,
  p_discount_amount numeric,
  p_discount_mode text,
  p_discount_value numeric,
  p_discount_reason text,
  p_checkout_token text,
  p_discount_approval_request_id uuid,
  p_solo_handled boolean,
  p_assigned_helper_id text,
  p_assigned_helper_name text,
  p_assigned_at timestamp with time zone,
  p_assigned_by_admin_id text,
  p_assigned_by_admin_name text,
  p_payment_mode text,
  p_cash_given double precision,
  p_change_amount double precision
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_snapshot record;
  v_request public.approval_requests;
  v_order public.orders;
  v_limit numeric;
  v_requires_approval boolean;
  v_expected_total numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Checkout session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot create orders';
  end if;

  select * into v_snapshot
  from private.discount_cart_snapshot_v1(
    v_profile.location_id, p_items, p_discount_mode, p_discount_value,
    p_discount_reason, p_checkout_token
  );
  v_expected_total := v_snapshot.subtotal_amount - v_snapshot.discount_amount;
  if abs(round(coalesce(p_discount_amount, 0), 2)
      - v_snapshot.discount_amount) > 0.01
      or abs(round(coalesce(p_total_amount, 0), 2)
      - v_expected_total) > 0.01 then
    raise exception 'Cart pricing changed. Review the discount and try again';
  end if;

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10)
    into v_limit
  from public.store_settings settings
  where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
  v_requires_approval := v_profile.role <> 'admin'
    and v_snapshot.effective_percentage > v_limit;

  if v_requires_approval then
    if p_discount_approval_request_id is null then
      raise exception 'Admin approval is required for this discount';
    end if;
    select request.* into v_request
    from public.approval_requests request
    where request.id = p_discount_approval_request_id
    for update;
    if not found
        or v_request.request_type <> 'discount'
        or v_request.status <> 'approved'
        or v_request.location_id <> v_profile.location_id
        or v_request.requested_by_id <> v_profile.profile_id
        or v_request.used_at is not null
        or v_request.checkout_token <> trim(p_checkout_token)
        or v_request.cart_fingerprint <> v_snapshot.cart_fingerprint
        or v_request.discount_mode <> lower(trim(p_discount_mode))
        or v_request.discount_value <> p_discount_value
        or v_request.discount_amount <> v_snapshot.discount_amount
        or v_request.subtotal_amount <> v_snapshot.subtotal_amount
        or coalesce(trim(v_request.reason), '') <>
          coalesce(trim(p_discount_reason), '') then
      raise exception 'Discount approval does not match the current checkout';
    end if;
  end if;

  insert into public.orders (
    location_id, status, total_amount, discount_amount, payment_mode,
    cash_given, change_amount, items, created_by, created_by_id,
    created_by_name, assigned_helper_id, assigned_helper_name, assigned_at,
    assigned_by_admin_id, assigned_by_admin_name,
    discount_approval_request_id
  ) values (
    v_profile.location_id,
    case when coalesce(p_solo_handled, false)
      then 'solo_picking' else 'pending' end,
    v_expected_total, v_snapshot.discount_amount,
    coalesce(nullif(trim(p_payment_mode), ''), 'Cash'),
    p_cash_given, p_change_amount, v_snapshot.normalized_items,
    v_profile.profile_id, v_profile.profile_id::text,
    v_profile.profile_name,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_name end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_at end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_name end,
    case when v_requires_approval then p_discount_approval_request_id
      else null end
  ) returning * into v_order;

  if v_requires_approval then
    update public.approval_requests
    set used_at = now(), used_order_id = v_order.id
    where id = v_request.id;
  end if;

  return to_jsonb(v_order);
end;
$function$;

grant execute on function public.create_customer_order_v1(
  text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean,
  text, text, timestamp with time zone, text, text, text,
  double precision, double precision
) to anon, service_role, postgres;
revoke all on function public.create_customer_order_v1(
  text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean,
  text, text, timestamp with time zone, text, text, text,
  double precision, double precision
) from public, authenticated;

-- Phase B1 transactional checkout for the new client.
create or replace function public.create_customer_order_v2 (
  p_session_token text,
  p_items jsonb,
  p_total_amount numeric,
  p_discount_amount numeric,
  p_discount_mode text,
  p_discount_value numeric,
  p_discount_reason text,
  p_checkout_token text,
  p_discount_approval_request_id uuid,
  p_solo_handled boolean,
  p_assigned_helper_id text,
  p_assigned_helper_name text,
  p_assigned_at timestamp with time zone,
  p_assigned_by_admin_id text,
  p_assigned_by_admin_name text,
  p_payment_mode text,
  p_cash_given double precision,
  p_change_amount double precision
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_snapshot record;
  v_request public.approval_requests;
  v_order public.orders;
  v_item record;
  v_new_quantity numeric;
  v_limit numeric;
  v_requires_approval boolean;
  v_expected_total numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Checkout session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot create orders';
  end if;
  if length(trim(coalesce(p_checkout_token, ''))) < 16 then
    raise exception 'checkout_operation_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'checkout:' || trim(p_checkout_token),
    0
  ));
  select customer_order.* into v_order
  from public.orders customer_order
  where customer_order.checkout_operation_id = trim(p_checkout_token);
  if found then
    if v_order.location_id is distinct from v_profile.location_id
        or v_order.created_by is distinct from v_profile.profile_id then
      raise exception 'checkout_operation_conflict';
    end if;
    return to_jsonb(v_order);
  end if;

  perform product.id
  from public.products product
  join (
    select distinct (entry.value ->> 'product_id')::uuid as product_id
    from jsonb_array_elements(p_items) entry
  ) requested on requested.product_id = product.id
  where product.location_id = v_profile.location_id
  order by product.id
  for update of product;

  begin
    select * into v_snapshot
    from private.discount_cart_snapshot_v1(
      v_profile.location_id, p_items, p_discount_mode, p_discount_value,
      p_discount_reason, p_checkout_token
    );
  exception when others then
    if sqlerrm = 'A cart item is unavailable or exceeds current stock' then
      raise exception 'checkout_inventory_changed';
    end if;
    raise;
  end;

  v_expected_total := v_snapshot.subtotal_amount - v_snapshot.discount_amount;
  if abs(round(coalesce(p_discount_amount, 0), 2)
      - v_snapshot.discount_amount) > 0.01
      or abs(round(coalesce(p_total_amount, 0), 2)
      - v_expected_total) > 0.01 then
    raise exception 'Cart pricing changed. Review the discount and try again';
  end if;

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10)
    into v_limit
  from public.store_settings settings
  where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
  v_requires_approval := v_profile.role <> 'admin'
    and v_snapshot.effective_percentage > v_limit;

  if v_requires_approval then
    if p_discount_approval_request_id is null then
      raise exception 'Admin approval is required for this discount';
    end if;
    select request.* into v_request
    from public.approval_requests request
    where request.id = p_discount_approval_request_id
    for update;
    if not found
        or v_request.request_type <> 'discount'
        or v_request.status <> 'approved'
        or v_request.location_id <> v_profile.location_id
        or v_request.requested_by_id <> v_profile.profile_id
        or v_request.used_at is not null
        or v_request.checkout_token <> trim(p_checkout_token)
        or v_request.cart_fingerprint <> v_snapshot.cart_fingerprint
        or v_request.discount_mode <> lower(trim(p_discount_mode))
        or v_request.discount_value <> p_discount_value
        or v_request.discount_amount <> v_snapshot.discount_amount
        or v_request.subtotal_amount <> v_snapshot.subtotal_amount
        or coalesce(trim(v_request.reason), '') <>
          coalesce(trim(p_discount_reason), '') then
      raise exception 'Discount approval does not match the current checkout';
    end if;
  end if;

  insert into public.orders (
    location_id, status, total_amount, discount_amount, payment_mode,
    cash_given, change_amount, items, created_by, created_by_id,
    created_by_name, assigned_helper_id, assigned_helper_name, assigned_at,
    assigned_by_admin_id, assigned_by_admin_name,
    discount_approval_request_id, checkout_operation_id
  ) values (
    v_profile.location_id,
    case when coalesce(p_solo_handled, false)
      then 'solo_picking' else 'pending' end,
    v_expected_total, v_snapshot.discount_amount,
    coalesce(nullif(trim(p_payment_mode), ''), 'Cash'),
    p_cash_given, p_change_amount, v_snapshot.normalized_items,
    v_profile.profile_id, v_profile.profile_id::text,
    v_profile.profile_name,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_name end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_at end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_name end,
    case when v_requires_approval then p_discount_approval_request_id
      else null end,
    trim(p_checkout_token)
  ) returning * into v_order;

  for v_item in
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(v_snapshot.normalized_items) entry
    order by (entry.value ->> 'product_id')::uuid
  loop
    update public.products product
    set product_quantity = product.product_quantity - v_item.quantity
    where product.id = v_item.product_id
      and product.location_id = v_profile.location_id
    returning product.product_quantity into v_new_quantity;
    if not found then raise exception 'checkout_inventory_changed'; end if;

    insert into public.transaction_history (
      product_id, transaction_type, quantity_change, new_quantity,
      location_id, user_id, user_name, operation_id, operation_scope
    ) values (
      v_item.product_id, 'checkout', -v_item.quantity, v_new_quantity,
      v_profile.location_id, v_profile.profile_id, v_profile.profile_name,
      trim(p_checkout_token), 'checkout'
    );
  end loop;

  if v_requires_approval then
    update public.approval_requests
    set used_at = now(), used_order_id = v_order.id
    where id = v_request.id;
  end if;

  return to_jsonb(v_order);
end;
$function$;

grant execute on function public.create_customer_order_v2(
  text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean,
  text, text, timestamp with time zone, text, text, text,
  double precision, double precision
) to anon, service_role, postgres;
revoke all on function public.create_customer_order_v2(
  text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean,
  text, text, timestamp with time zone, text, text, text,
  double precision, double precision
) from public, authenticated;

create or replace function public.cancel_customer_order_v1 (
  p_session_token text,
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_order public.orders;
  v_item record;
  v_new_quantity numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Cancellation session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot cancel orders';
  end if;

  select customer_order.* into v_order
  from public.orders customer_order
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
  for update;
  if not found then raise exception 'order_cannot_be_cancelled'; end if;

  if v_order.status = 'cancelled' then
    return jsonb_build_object('order', to_jsonb(v_order), 'reused', true);
  end if;
  if v_order.status = 'completed' then
    raise exception 'order_cannot_be_cancelled';
  end if;
  if v_order.status not in ('pending', 'prepared', 'solo_picking') then
    raise exception 'order_cannot_be_cancelled';
  end if;

  perform product.id
  from public.products product
  join (
    select (entry.value ->> 'product_id')::uuid as product_id
    from jsonb_array_elements(v_order.items) entry
    group by (entry.value ->> 'product_id')::uuid
  ) requested on requested.product_id = product.id
  where product.location_id = v_profile.location_id
  order by product.id
  for update of product;

  for v_item in
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      sum((entry.value ->> 'quantity')::numeric) as quantity
    from jsonb_array_elements(v_order.items) entry
    group by (entry.value ->> 'product_id')::uuid
    order by (entry.value ->> 'product_id')::uuid
  loop
    update public.products product
    set product_quantity = product.product_quantity + v_item.quantity
    where product.id = v_item.product_id
      and product.location_id = v_profile.location_id
    returning product.product_quantity into v_new_quantity;
    if not found then raise exception 'inventory_changed'; end if;

    insert into public.transaction_history (
      product_id, transaction_type, quantity_change, new_quantity,
      location_id, user_id, user_name, operation_id
    ) values (
      v_item.product_id, 'order_cancelled', v_item.quantity, v_new_quantity,
      v_profile.location_id, v_profile.profile_id, v_profile.profile_name,
      'cancel:' || v_order.id::text
    );
  end loop;

  update public.orders customer_order
  set status = 'cancelled',
      cancelled_by_id = v_profile.profile_id::text,
      cancelled_by_name = v_profile.profile_name,
      cancelled_at = now()
  where customer_order.id = v_order.id
  returning customer_order.* into v_order;

  return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
end;
$function$;

grant execute on function public.cancel_customer_order_v1(text, uuid)
  to anon, service_role, postgres;
revoke all on function public.cancel_customer_order_v1(text, uuid)
  from public, authenticated;

create or replace function public.complete_customer_order_v1 (
  p_session_token text,
  p_order_id uuid,
  p_payment_mode text,
  p_cash_given double precision,
  p_change_amount double precision,
  p_payment_reference text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
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

grant execute on function public.complete_customer_order_v1(
  text, uuid, text, double precision, double precision, text
) to anon, service_role, postgres;
revoke all on function public.complete_customer_order_v1(
  text, uuid, text, double precision, double precision, text
) from public, authenticated;

create or replace function public.adjust_inventory_quantity_v1 (
  p_session_token text,
  p_operation_id text,
  p_product_id uuid,
  p_expected_quantity numeric,
  p_new_quantity numeric,
  p_transaction_type text,
  p_note text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_product public.products;
  v_existing public.transaction_history;
  v_transaction public.transaction_history;
  v_quantity_change numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Inventory session is invalid or expired'; end if;
  if length(trim(coalesce(p_operation_id, ''))) < 16
      or trim(p_operation_id) not like 'inventory-adjustment:%' then
    raise exception 'inventory_operation_invalid';
  end if;
  if p_transaction_type not in ('stock_in', 'checkout', 'write_off') then
    raise exception 'inventory_operation_invalid';
  end if;
  if p_expected_quantity is null or p_new_quantity is null
      or p_new_quantity < 0 then
    raise exception 'inventory_operation_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'inventory-adjustment:' || trim(p_operation_id),
    0
  ));
  select history.* into v_existing
  from public.transaction_history history
  where history.operation_scope = 'inventory_adjustment'
    and history.operation_id = trim(p_operation_id);
  if found then
    if v_existing.location_id is distinct from v_profile.location_id
        or v_existing.user_id is distinct from v_profile.profile_id
        or v_existing.product_id is distinct from p_product_id
        or v_existing.transaction_type is distinct from p_transaction_type
        or v_existing.new_quantity is distinct from p_new_quantity
        or v_existing.quantity_change is distinct from
          (p_new_quantity - p_expected_quantity)
        or (v_existing.new_quantity - v_existing.quantity_change)
          is distinct from
          p_expected_quantity then
      raise exception 'inventory_operation_conflict';
    end if;
    return jsonb_build_object(
      'transaction_id', v_existing.id,
      'product_id', v_existing.product_id,
      'new_quantity', v_existing.new_quantity,
      'quantity_change', v_existing.quantity_change,
      'reused', true
    );
  end if;

  select product.* into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id
    and coalesce(product.is_active, true)
  for update;
  if not found or v_product.product_quantity <> p_expected_quantity then
    raise exception 'inventory_changed';
  end if;

  v_quantity_change := p_new_quantity - p_expected_quantity;
  if v_quantity_change = 0 then raise exception 'inventory_operation_invalid'; end if;

  update public.products product
  set product_quantity = p_new_quantity
  where product.id = v_product.id
    and product.location_id = v_profile.location_id;

  insert into public.transaction_history (
    product_id, transaction_type, quantity_change, new_quantity,
    location_id, user_id, user_name, note, operation_id, operation_scope
  ) values (
    v_product.id, p_transaction_type, v_quantity_change, p_new_quantity,
    v_profile.location_id, v_profile.profile_id, v_profile.profile_name,
    nullif(trim(coalesce(p_note, '')), ''), trim(p_operation_id),
    'inventory_adjustment'
  ) returning * into v_transaction;

  return jsonb_build_object(
    'transaction_id', v_transaction.id,
    'product_id', v_transaction.product_id,
    'new_quantity', v_transaction.new_quantity,
    'quantity_change', v_transaction.quantity_change,
    'reused', false
  );
end;
$function$;

grant execute on function public.adjust_inventory_quantity_v1(
  text, text, uuid, numeric, numeric, text, text
) to anon, service_role, postgres;
revoke all on function public.adjust_inventory_quantity_v1(
  text, text, uuid, numeric, numeric, text, text
) from public, authenticated;

commit;
