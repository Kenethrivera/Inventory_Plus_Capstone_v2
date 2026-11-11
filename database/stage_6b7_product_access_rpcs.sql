-- Inventory Plus Stage 6B.7 - additive product mutation interfaces.
-- ISOLATED TESTING FIRST. This file does not revoke any existing privilege.

begin;

create or replace function public.forecast_product_snapshot_v1(
  p_session_token text,
  p_product_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  return (
    select jsonb_build_object(
      'id', product_row.id,
      'sku', product_row.sku,
      'product_name', product_row.product_name,
      'unit', product_row.unit,
      'product_quantity', product_row.product_quantity,
      'max_quantity', product_row.max_quantity,
      'location_id', product_row.location_id,
      'created_at', product_row.created_at,
      'updated_at', product_row.updated_at,
      'is_active', product_row.is_active
    )
    from public.products product_row
    where product_row.id = p_product_id
      and product_row.location_id = v_session.location_id
      and product_row.is_active
  );
end;
$$;

create or replace function public.product_details_update_v1(
  p_session_token text,
  p_product_id uuid,
  p_product_name text,
  p_sku text,
  p_product_price numeric,
  p_description text,
  p_manufacturer text,
  p_model text,
  p_product_size text,
  p_shelf_level text,
  p_bin_number text,
  p_image_url text,
  p_unit text,
  p_max_quantity numeric
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if p_product_id is null
     or nullif(trim(coalesce(p_product_name, '')), '') is null
     or nullif(trim(coalesce(p_sku, '')), '') is null
     or nullif(trim(coalesce(p_unit, '')), '') is null
     or p_product_price is null or p_product_price < 0
     or p_max_quantity is null or p_max_quantity < 0
     or length(p_product_name) > 300
     or length(p_sku) > 100
     or length(p_unit) > 50
     or length(coalesce(p_description, '')) > 4000
     or length(coalesce(p_image_url, '')) > 2048 then
    raise exception 'invalid_product_input' using errcode = '22023';
  end if;

  update public.products product_row
  set product_name = trim(p_product_name),
      sku = trim(p_sku),
      product_price = p_product_price,
      description = nullif(trim(coalesce(p_description, '')), ''),
      manufacturer = nullif(trim(coalesce(p_manufacturer, '')), ''),
      model = nullif(trim(coalesce(p_model, '')), ''),
      product_size = nullif(trim(coalesce(p_product_size, '')), ''),
      shelf_level = nullif(trim(coalesce(p_shelf_level, '')), ''),
      bin_number = nullif(trim(coalesce(p_bin_number, '')), ''),
      image_url = nullif(trim(coalesce(p_image_url, '')), ''),
      unit = trim(p_unit),
      max_quantity = p_max_quantity,
      updated_at = clock_timestamp()
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id;

  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

create or replace function public.product_set_active_v1(
  p_session_token text,
  p_product_id uuid,
  p_is_active boolean
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_product public.products%rowtype;
  v_transaction_id uuid;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if p_product_id is null or p_is_active is null then
    raise exception 'invalid_product_status_input' using errcode = '22023';
  end if;

  select * into v_product
  from public.products product_row
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id
  for update;
  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;

  if not p_is_active and exists (
    select 1
    from public.orders order_row
    cross join lateral jsonb_array_elements(coalesce(order_row.items, '[]'::jsonb)) item
    where order_row.location_id = v_session.location_id
      and order_row.status in ('pending', 'prepared', 'solo_picking')
      and coalesce(item ->> 'product_id', item ->> 'productId') = p_product_id::text
  ) then
    raise exception 'product_in_open_order' using errcode = '23514';
  end if;

  if v_product.is_active is distinct from p_is_active then
    update public.products product_row
    set is_active = p_is_active,
        updated_at = clock_timestamp()
    where product_row.id = p_product_id
      and product_row.location_id = v_session.location_id;

    insert into public.transaction_history (
      product_id, user_id, user_name, transaction_type, quantity_change,
      new_quantity, location_id, operation_id, operation_scope
    ) values (
      p_product_id, v_session.profile_id, v_session.profile_name,
      case when p_is_active then 'item_restored' else 'item_disabled' end,
      0, v_product.product_quantity, v_session.location_id,
      'product-status:' || extensions.gen_random_uuid()::text,
      'product_status'
    ) returning id into v_transaction_id;
  end if;

  return jsonb_build_object(
    'product_id', p_product_id,
    'is_active', p_is_active,
    'transaction_id', v_transaction_id
  );
end;
$$;

create or replace function public.product_delete_inactive_v1(
  p_session_token text,
  p_product_id uuid
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_product public.products%rowtype;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  select * into v_product
  from public.products product_row
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id
  for update;
  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;
  if v_product.is_active then
    raise exception 'product_must_be_inactive' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.orders order_row
    cross join lateral jsonb_array_elements(coalesce(order_row.items, '[]'::jsonb)) item
    where order_row.location_id = v_session.location_id
      and order_row.status in ('pending', 'prepared', 'solo_picking')
      and coalesce(item ->> 'product_id', item ->> 'productId') = p_product_id::text
  ) then
    raise exception 'product_in_open_order' using errcode = '23514';
  end if;

  delete from public.products product_row
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id;

  insert into public.transaction_history (
    product_id, user_id, user_name, transaction_type, quantity_change,
    new_quantity, location_id, operation_id, operation_scope
  ) values (
    null, v_session.profile_id, v_session.profile_name, 'delete',
    -v_product.product_quantity, 0, v_session.location_id,
    'product-delete:' || extensions.gen_random_uuid()::text,
    'product_delete'
  );
  return true;
end;
$$;

create or replace function public.product_shelf_bin_update_v1(
  p_session_token text,
  p_product_id uuid,
  p_shelf_level text,
  p_bin_number text
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if length(coalesce(p_shelf_level, '')) > 100
     or length(coalesce(p_bin_number, '')) > 100 then
    raise exception 'invalid_product_location_input' using errcode = '22023';
  end if;

  update public.products product_row
  set shelf_level = nullif(trim(coalesce(p_shelf_level, '')), ''),
      bin_number = nullif(trim(coalesce(p_bin_number, '')), ''),
      updated_at = clock_timestamp()
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id;
  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

create or replace function public.product_map_assignment_v1(
  p_session_token text,
  p_product_id uuid,
  p_map_element_id text
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_map_element_id, '')), '') is null
     or length(p_map_element_id) > 200 then
    raise exception 'invalid_map_element' using errcode = '22023';
  end if;

  update public.products product_row
  set map_element_id = trim(p_map_element_id),
      updated_at = clock_timestamp()
  where product_row.id = p_product_id
    and product_row.location_id = v_session.location_id;
  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

revoke all on function public.forecast_product_snapshot_v1(text, uuid) from public, authenticated;
revoke all on function public.product_details_update_v1(text, uuid, text, text, numeric, text, text, text, text, text, text, text, text, numeric) from public, authenticated;
revoke all on function public.product_set_active_v1(text, uuid, boolean) from public, authenticated;
revoke all on function public.product_delete_inactive_v1(text, uuid) from public, authenticated;
revoke all on function public.product_shelf_bin_update_v1(text, uuid, text, text) from public, authenticated;
revoke all on function public.product_map_assignment_v1(text, uuid, text) from public, authenticated;

grant execute on function public.forecast_product_snapshot_v1(text, uuid) to anon, service_role;
grant execute on function public.product_details_update_v1(text, uuid, text, text, numeric, text, text, text, text, text, text, text, text, numeric) to anon, service_role;
grant execute on function public.product_set_active_v1(text, uuid, boolean) to anon, service_role;
grant execute on function public.product_delete_inactive_v1(text, uuid) to anon, service_role;
grant execute on function public.product_shelf_bin_update_v1(text, uuid, text, text) to anon, service_role;
grant execute on function public.product_map_assignment_v1(text, uuid, text) to anon, service_role;

commit;
