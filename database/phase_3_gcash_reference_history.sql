-- Phase 3 durable GCash payment reference history.
-- Apply through the normal migration process only. Do not execute from Flutter.

alter table public.order_history
  add column if not exists payment_reference text;

-- Preserve exactly what is currently stored, including shortened legacy values.
update public.order_history history
set payment_reference = source.payment_reference
from public.orders source
where history.order_id = source.id::text
  and history.payment_reference is null
  and source.payment_reference is not null;

create or replace function public.sync_order_history_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_returned_by_name text;
begin
  if new.returned_by_id is not null then
    select profile.name
      into v_returned_by_name
      from public.profiles profile
     where profile.id::text = new.returned_by_id::text;
  end if;

  insert into public.order_history (
    order_id, location_id, status, items, created_at,
    assigned_at, prepared_at, completed_at, cancelled_at, returned_at,
    created_by_id, created_by_name,
    assigned_helper_id, assigned_helper_name,
    prepared_by_id, prepared_by_name,
    completed_by_id, completed_by_name,
    cancelled_by_id, cancelled_by_name,
    returned_by_id, returned_by_name,
    total_amount, discount_amount, payment_mode, payment_reference,
    cash_given, change_amount, snapshot_updated_at
  ) values (
    new.id::text, new.location_id, new.status,
    coalesce(new.items::jsonb, '[]'::jsonb), new.created_at,
    new.assigned_at, new.prepared_at, new.completed_at,
    new.cancelled_at, new.returned_at,
    new.created_by_id::text, new.created_by_name,
    new.assigned_helper_id::text, new.assigned_helper_name,
    new.prepared_by_id::text, new.prepared_by_name,
    new.completed_by_id::text, new.completed_by_name,
    new.cancelled_by_id::text, new.cancelled_by_name,
    new.returned_by_id::text, v_returned_by_name,
    coalesce(new.total_amount, 0), coalesce(new.discount_amount, 0),
    new.payment_mode, new.payment_reference, new.cash_given,
    new.change_amount, now()
  )
  on conflict (order_id) do update set
    location_id = excluded.location_id,
    status = excluded.status,
    items = excluded.items,
    created_at = excluded.created_at,
    assigned_at = excluded.assigned_at,
    prepared_at = excluded.prepared_at,
    completed_at = excluded.completed_at,
    cancelled_at = excluded.cancelled_at,
    returned_at = excluded.returned_at,
    created_by_id = excluded.created_by_id,
    created_by_name = excluded.created_by_name,
    assigned_helper_id = excluded.assigned_helper_id,
    assigned_helper_name = excluded.assigned_helper_name,
    prepared_by_id = excluded.prepared_by_id,
    prepared_by_name = excluded.prepared_by_name,
    completed_by_id = excluded.completed_by_id,
    completed_by_name = excluded.completed_by_name,
    cancelled_by_id = excluded.cancelled_by_id,
    cancelled_by_name = excluded.cancelled_by_name,
    returned_by_id = excluded.returned_by_id,
    returned_by_name = coalesce(
      excluded.returned_by_name, public.order_history.returned_by_name),
    total_amount = excluded.total_amount,
    discount_amount = excluded.discount_amount,
    payment_mode = excluded.payment_mode,
    payment_reference = excluded.payment_reference,
    cash_given = excluded.cash_given,
    change_amount = excluded.change_amount,
    snapshot_updated_at = excluded.snapshot_updated_at;

  return new;
end;
$$;

create or replace function public.history_order_detail_v1(
  p_session_token text,
  p_order_id text
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account_id text;
  v_role text;
  v_location_id uuid;
  v_order jsonb;
begin
  select session_profile.profile_id::text, session_profile.role,
      session_profile.location_id
    into v_account_id, v_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then raise exception 'History session is invalid or expired'; end if;

  select case
    when v_role = 'helper' then jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'assigned_helper_id', o.assigned_helper_id, 'assigned_at', o.assigned_at,
      'prepared_by_id', o.prepared_by_id, 'prepared_at', o.prepared_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity'
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    when v_role in ('staff', 'cashier') then jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'created_by_id', o.created_by_id,
      'assigned_helper_id', o.assigned_helper_id, 'assigned_at', o.assigned_at,
      'prepared_by_id', o.prepared_by_id, 'prepared_at', o.prepared_at,
      'completed_by_id', o.completed_by_id, 'completed_at', o.completed_at,
      'cancelled_by_id', o.cancelled_by_id, 'cancelled_at', o.cancelled_at,
      'returned_by_id', o.returned_by_id, 'returned_at', o.returned_at,
      'payment_mode', o.payment_mode,
      'payment_reference', o.payment_reference,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity'
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    else jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'discount_amount', o.discount_amount,
      'cash_given', o.cash_given, 'change_amount', o.change_amount,
      'payment_mode', o.payment_mode,
      'payment_reference', o.payment_reference,
      'created_by_name', coalesce(o.created_by_name, (
        select name from public.profiles
        where id::text = o.created_by_id::text
      )),
      'prepared_by_name', coalesce(o.prepared_by_name, (
        select name from public.profiles
        where id::text = o.prepared_by_id::text
      )),
      'completed_by_name', coalesce(o.completed_by_name, (
        select name from public.profiles
        where id::text = o.completed_by_id::text
      )),
      'cancelled_by_name', coalesce(o.cancelled_by_name, (
        select name from public.profiles
        where id::text = o.cancelled_by_id::text
      )),
      'prepared_at', o.prepared_at, 'completed_at', o.completed_at,
      'cancelled_at', o.cancelled_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity',
          'price', coalesce(item -> 'price', item -> 'unit_price')
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
  end into v_order
  from public.order_history o
  where o.location_id = v_location_id and o.order_id = p_order_id and (
    v_role = 'admin'
    or (v_role = 'helper' and (
      o.assigned_helper_id = v_account_id
      or o.prepared_by_id = v_account_id))
    or (v_role in ('staff', 'cashier') and (
      o.created_by_id = v_account_id
      or o.completed_by_id = v_account_id
      or o.cancelled_by_id = v_account_id
      or o.returned_by_id = v_account_id))
  );
  return v_order;
end;
$$;

create or replace function public.history_export_sales_v1(
  p_session_token text,
  p_period_start timestamptz,
  p_period_end timestamptz
) returns setof jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_role text;
  v_location_id uuid;
begin
  if p_period_start is null or p_period_end is null
    or p_period_end <= p_period_start then
    raise exception 'Invalid export period';
  end if;
  select session_profile.role, session_profile.location_id
    into v_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then raise exception 'History session is invalid or expired'; end if;
  if v_role <> 'admin' then
    raise exception 'Sales export is not allowed for this profile';
  end if;

  return query
    select jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'discount_amount', o.discount_amount,
      'cash_given', o.cash_given, 'change_amount', o.change_amount,
      'payment_mode', o.payment_mode,
      'payment_reference', o.payment_reference,
      'created_by_name', o.created_by_name,
      'prepared_by_name', o.prepared_by_name,
      'completed_by_name', o.completed_by_name,
      'cancelled_by_name', o.cancelled_by_name,
      'prepared_at', o.prepared_at, 'completed_at', o.completed_at,
      'cancelled_at', o.cancelled_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity',
          'price', coalesce(item -> 'price', item -> 'unit_price')
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    from public.order_history o
    where o.location_id = v_location_id and lower(o.status) = 'completed'
      and coalesce(o.completed_at, o.prepared_at, o.created_at) >= p_period_start
      and coalesce(o.completed_at, o.prepared_at, o.created_at) < p_period_end
    order by coalesce(o.completed_at, o.prepared_at, o.created_at) desc,
      o.order_id desc;
end;
$$;
