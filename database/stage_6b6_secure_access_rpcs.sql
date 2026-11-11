-- Inventory Plus Stage 6B.6 - additive secure access interfaces.
--
-- This migration is intentionally additive. It does not revoke table grants,
-- enable RLS, or modify production data. Deploy and exercise it in the
-- isolated Stage 6B test project before changing any production privilege.

begin;

create or replace function public.inventory_snapshot_v1(
  p_session_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);

  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'id', product_row.id,
      'sku', product_row.sku,
      'product_name', product_row.product_name,
      'category', product_row.category,
      'manufacturer', product_row.manufacturer,
      'model', product_row.model,
      'product_size', product_row.product_size,
      'product_price', product_row.product_price,
      'product_quantity', product_row.product_quantity,
      'created_at', product_row.created_at,
      'updated_at', product_row.updated_at,
      'image_url', product_row.image_url,
      'location_id', product_row.location_id,
      'shelf_level', product_row.shelf_level,
      'bin_number', product_row.bin_number,
      'description', product_row.description,
      'unit', product_row.unit,
      'max_quantity', product_row.max_quantity,
      'is_active', product_row.is_active,
      'map_element_id', product_row.map_element_id
    ) order by product_row.created_at, product_row.id),
    '[]'::jsonb
  ) into v_result
  from public.products product_row
  where product_row.location_id = v_session.location_id;

  return v_result;
end;
$$;

create or replace function public.operational_orders_snapshot_v1(
  p_session_token text,
  p_created_since timestamptz,
  p_event_since timestamptz
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);

  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if p_created_since is null or p_event_since is null
     or p_created_since > p_event_since then
    raise exception 'order_snapshot_boundaries_required' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      case when v_session.role = 'helper' then
        jsonb_build_object(
          'id', order_row.id,
          'status', order_row.status,
          'items', order_row.items,
          'location_id', order_row.location_id,
          'created_at', order_row.created_at,
          'updated_at', order_row.updated_at,
          'created_by_id', order_row.created_by_id,
          'created_by_name', order_row.created_by_name,
          'assigned_helper_id', order_row.assigned_helper_id,
          'assigned_helper_name', order_row.assigned_helper_name,
          'assigned_at', order_row.assigned_at,
          'assigned_by_admin_id', order_row.assigned_by_admin_id,
          'assigned_by_admin_name', order_row.assigned_by_admin_name,
          'prepared_by_id', order_row.prepared_by_id,
          'prepared_by_name', order_row.prepared_by_name,
          'prepared_at', order_row.prepared_at
        )
      else
        jsonb_build_object(
          'id', order_row.id,
          'status', order_row.status,
          'items', order_row.items,
          'location_id', order_row.location_id,
          'created_at', order_row.created_at,
          'updated_at', order_row.updated_at,
          'total_amount', order_row.total_amount,
          'discount_amount', order_row.discount_amount,
          'payment_mode', order_row.payment_mode,
          'cash_given', order_row.cash_given,
          'change_amount', order_row.change_amount,
          'payment_reference', order_row.payment_reference,
          'created_by_id', order_row.created_by_id,
          'created_by_name', order_row.created_by_name,
          'assigned_helper_id', order_row.assigned_helper_id,
          'assigned_helper_name', order_row.assigned_helper_name,
          'assigned_at', order_row.assigned_at,
          'assigned_by_admin_id', order_row.assigned_by_admin_id,
          'assigned_by_admin_name', order_row.assigned_by_admin_name,
          'prepared_by_id', order_row.prepared_by_id,
          'prepared_by_name', order_row.prepared_by_name,
          'prepared_at', order_row.prepared_at,
          'completed_by_id', order_row.completed_by_id,
          'completed_by_name', order_row.completed_by_name,
          'completed_at', order_row.completed_at,
          'cancelled_by_id', order_row.cancelled_by_id,
          'cancelled_by_name', order_row.cancelled_by_name,
          'cancelled_at', order_row.cancelled_at,
          'returned_by_id', order_row.returned_by_id,
          'returned_by_name', order_row.returned_by_name,
          'returned_at', order_row.returned_at,
          'return_reason', order_row.return_reason
        )
      end
      order by order_row.created_at desc, order_row.id
    ),
    '[]'::jsonb
  ) into v_result
  from public.orders order_row
  where order_row.location_id = v_session.location_id
    and (
      order_row.status in ('pending', 'prepared', 'solo_picking')
      or order_row.created_at >= p_created_since
      or order_row.prepared_at >= p_event_since
      or order_row.completed_at >= p_event_since
      or order_row.cancelled_at >= p_event_since
      or order_row.returned_at >= p_event_since
    )
    and (
      v_session.role <> 'helper'
      or (
        order_row.status = 'pending'
        and (
          order_row.assigned_helper_id is null
          or order_row.assigned_helper_id = v_session.profile_id::text
        )
      )
    );

  return v_result;
end;
$$;

create or replace function public.current_profile_snapshot_v1(
  p_session_token text
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

  return (
    select jsonb_build_object(
      'id', profile_row.id,
      'location_id', profile_row.location_id,
      'name', profile_row.name,
      'role', profile_row.role,
      'email', profile_row.email,
      'address', profile_row.address,
      'phone', profile_row.phone,
      'must_change_password', profile_row.must_change_password
    )
    from public.profiles profile_row
    where profile_row.id = v_session.profile_id
      and profile_row.location_id = v_session.location_id
  );
end;
$$;

create or replace function public.staff_configuration_snapshot_v1(
  p_session_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);

  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  -- Password hashes are deliberately excluded.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', profile_row.id,
        'name', profile_row.name,
        'username', profile_row.username,
        'role', profile_row.role,
        'created_at', profile_row.created_at,
        'location_id', profile_row.location_id,
        'email', profile_row.email,
        'phone', profile_row.phone,
        'address', profile_row.address,
        'must_change_password', profile_row.must_change_password
      ) order by profile_row.name, profile_row.id
    ),
    '[]'::jsonb
  ) into v_result
  from public.profiles profile_row
  where profile_row.location_id = v_session.location_id;

  return v_result;
end;
$$;

create or replace function public.staff_create_v1(
  p_session_token text,
  p_name text,
  p_username text,
  p_password text,
  p_role text,
  p_email text default null,
  p_phone text default null,
  p_address text default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_profile public.profiles%rowtype;
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null
     or nullif(trim(coalesce(p_username, '')), '') is null
     or coalesce(p_password, '') = ''
     or length(p_name) > 200
     or length(p_username) > 100
     or length(p_password) > 1024
     or length(coalesce(p_email, '')) > 320
     or length(coalesce(p_phone, '')) > 50
     or length(coalesce(p_address, '')) > 1000
     or v_role not in ('admin', 'staff', 'helper') then
    raise exception 'invalid_staff_input' using errcode = '22023';
  end if;

  insert into public.profiles (
    name, username, password, role, location_id, email, phone, address,
    must_change_password
  ) values (
    trim(p_name),
    trim(p_username),
    encode(extensions.digest(convert_to(p_password, 'UTF8'), 'sha256'), 'hex'),
    v_role,
    v_session.location_id,
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    nullif(trim(coalesce(p_address, '')), ''),
    v_role in ('staff', 'helper')
  ) returning * into v_profile;

  return jsonb_build_object(
    'id', v_profile.id,
    'name', v_profile.name,
    'username', v_profile.username,
    'role', v_profile.role,
    'created_at', v_profile.created_at,
    'location_id', v_profile.location_id,
    'email', v_profile.email,
    'phone', v_profile.phone,
    'address', v_profile.address,
    'must_change_password', v_profile.must_change_password
  );
end;
$$;

create or replace function public.staff_update_role_v1(
  p_session_token text,
  p_target_profile_id bigint,
  p_role text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_profile public.profiles%rowtype;
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if v_session.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if v_role not in ('admin', 'staff', 'helper') then
    raise exception 'invalid_staff_role' using errcode = '22023';
  end if;

  update public.profiles profile_row
  set role = v_role
  where profile_row.id = p_target_profile_id
    and profile_row.location_id = v_session.location_id
  returning * into v_profile;

  if not found then
    raise exception 'staff_not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_profile.id,
    'name', v_profile.name,
    'username', v_profile.username,
    'role', v_profile.role,
    'created_at', v_profile.created_at,
    'location_id', v_profile.location_id,
    'email', v_profile.email,
    'phone', v_profile.phone,
    'address', v_profile.address,
    'must_change_password', v_profile.must_change_password
  );
end;
$$;

create or replace function public.staff_profile_v1(
  p_session_token text,
  p_target_profile_id bigint
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
      'id', profile_row.id,
      'name', profile_row.name,
      'username', profile_row.username,
      'role', profile_row.role,
      'created_at', profile_row.created_at,
      'location_id', profile_row.location_id,
      'email', profile_row.email,
      'phone', profile_row.phone,
      'address', profile_row.address,
      'must_change_password', profile_row.must_change_password
    )
    from public.profiles profile_row
    where profile_row.id = p_target_profile_id
      and profile_row.location_id = v_session.location_id
  );
end;
$$;

create or replace function public.staff_delete_v1(
  p_session_token text,
  p_target_profile_id bigint
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
  if p_target_profile_id = v_session.profile_id then
    raise exception 'cannot_delete_current_profile' using errcode = '22023';
  end if;

  delete from public.profiles profile_row
  where profile_row.id = p_target_profile_id
    and profile_row.location_id = v_session.location_id;
  return found;
end;
$$;

create or replace function public.current_profile_update_v1(
  p_session_token text,
  p_name text,
  p_email text,
  p_address text,
  p_phone text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_profile public.profiles%rowtype;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'profile_name_required' using errcode = '22023';
  end if;
  if length(p_name) > 200
     or length(coalesce(p_email, '')) > 320
     or length(coalesce(p_phone, '')) > 50
     or length(coalesce(p_address, '')) > 1000 then
    raise exception 'invalid_profile_input' using errcode = '22023';
  end if;

  update public.profiles profile_row
  set name = trim(p_name),
      email = nullif(trim(coalesce(p_email, '')), ''),
      address = nullif(trim(coalesce(p_address, '')), ''),
      phone = nullif(trim(coalesce(p_phone, '')), '')
  where profile_row.id = v_session.profile_id
    and profile_row.location_id = v_session.location_id
  returning * into v_profile;

  if not found then
    raise exception 'current_profile_not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_profile.id,
    'location_id', v_profile.location_id,
    'name', v_profile.name,
    'role', v_profile.role,
    'email', v_profile.email,
    'address', v_profile.address,
    'phone', v_profile.phone,
    'must_change_password', v_profile.must_change_password
  );
end;
$$;

revoke all on function public.inventory_snapshot_v1(text) from public, authenticated;
revoke all on function public.operational_orders_snapshot_v1(text, timestamptz, timestamptz) from public, authenticated;
revoke all on function public.current_profile_snapshot_v1(text) from public, authenticated;
revoke all on function public.staff_configuration_snapshot_v1(text) from public, authenticated;
revoke all on function public.staff_create_v1(text, text, text, text, text, text, text, text) from public, authenticated;
revoke all on function public.staff_update_role_v1(text, bigint, text) from public, authenticated;
revoke all on function public.staff_profile_v1(text, bigint) from public, authenticated;
revoke all on function public.staff_delete_v1(text, bigint) from public, authenticated;
revoke all on function public.current_profile_update_v1(text, text, text, text, text) from public, authenticated;

grant execute on function public.inventory_snapshot_v1(text) to anon, service_role;
grant execute on function public.operational_orders_snapshot_v1(text, timestamptz, timestamptz) to anon, service_role;
grant execute on function public.current_profile_snapshot_v1(text) to anon, service_role;
grant execute on function public.staff_configuration_snapshot_v1(text) to anon, service_role;
grant execute on function public.staff_create_v1(text, text, text, text, text, text, text, text) to anon, service_role;
grant execute on function public.staff_update_role_v1(text, bigint, text) to anon, service_role;
grant execute on function public.staff_profile_v1(text, bigint) to anon, service_role;
grant execute on function public.staff_delete_v1(text, bigint) to anon, service_role;
grant execute on function public.current_profile_update_v1(text, text, text, text, text) to anon, service_role;

commit;
