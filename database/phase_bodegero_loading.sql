-- Apply before deploying the Bodegero client. Existing orders remain light-only.
begin;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'staff', 'helper', 'bodegero'));

alter table public.products add column if not exists requires_loading boolean not null default false;
alter table public.orders add column if not exists assigned_bodegero_id text;
alter table public.orders add column if not exists assigned_bodegero_name text;
alter table public.orders add column if not exists loading_verified_at timestamptz;

create index if not exists orders_bodegero_pending_idx
  on public.orders (location_id, assigned_bodegero_id)
  where status in ('pending', 'solo_picking');

create table if not exists public.order_loading_proofs (
  order_id uuid primary key references public.orders(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  bodegero_id bigint not null references public.profiles(id),
  truck_plate text not null,
  loaded_quantities jsonb not null,
  photo_jpeg bytea not null,
  captured_at timestamptz not null default now()
);
alter table public.order_loading_proofs enable row level security;
revoke all on public.order_loading_proofs from public, anon, authenticated;

create table if not exists public.order_heavy_scans (
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  bodegero_id bigint not null references public.profiles(id),
  scanned_at timestamptz not null default now(),
  primary key (order_id, product_id)
);
alter table public.order_heavy_scans enable row level security;
revoke all on public.order_heavy_scans from public, anon, authenticated;

-- Keep product creation and its handling classification in one transaction.
create or replace function public.create_product_v2(
  p_session_token text, p_operation_id text, p_sku text,
  p_product_name text, p_category text, p_product_price numeric,
  p_product_quantity numeric, p_description text, p_image_url text,
  p_manufacturer text, p_model text, p_product_size text,
  p_shelf_level text, p_bin_number text, p_unit text,
  p_max_quantity numeric, p_requires_loading boolean
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_product public.products%rowtype;
  v_actor record;
  v_result jsonb;
begin
  if p_requires_loading is null then raise exception 'handling_required'; end if;
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'invalid_or_expired_session' using errcode = '28000'; end if;
  if nullif(trim(coalesce(p_operation_id, '')), '') is null then
    raise exception 'product_submission_invalid';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'product-create:' || trim(p_operation_id), 0));
  select * into v_product from public.products
  where create_operation_id = trim(p_operation_id);
  if found then
    if v_product.location_id is distinct from v_actor.location_id
        or v_product.sku is distinct from trim(p_sku)
        or v_product.product_name is distinct from trim(p_product_name) then
      raise exception 'product_submission_conflict';
    end if;
    if v_product.requires_loading is distinct from p_requires_loading then
      raise exception 'product_submission_conflict';
    end if;
    return to_jsonb(v_product);
  end if;
  v_result := public.create_product_v1(
    p_session_token, p_operation_id, p_sku, p_product_name, p_category,
    p_product_price, p_product_quantity, p_description, p_image_url,
    p_manufacturer, p_model, p_product_size, p_shelf_level, p_bin_number,
    p_unit, p_max_quantity);
  update public.products set requires_loading = p_requires_loading
  where id = (v_result ->> 'id')::uuid returning * into v_product;
  return to_jsonb(v_product);
end;
$$;
revoke all on function public.create_product_v2(
  text, text, text, text, text, numeric, numeric, text, text, text,
  text, text, text, text, text, numeric, boolean
) from public, authenticated;
grant execute on function public.create_product_v2(
  text, text, text, text, text, numeric, numeric, text, text, text,
  text, text, text, text, text, numeric, boolean
) to anon, service_role;

create or replace function public.product_details_update_v2(
  p_session_token text, p_product_id uuid, p_product_name text,
  p_sku text, p_product_price numeric, p_description text,
  p_manufacturer text, p_model text, p_product_size text,
  p_shelf_level text, p_bin_number text, p_image_url text,
  p_unit text, p_max_quantity numeric, p_requires_loading boolean
) returns boolean language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare v_saved boolean;
begin
  if p_requires_loading is null then raise exception 'handling_required'; end if;
  v_saved := public.product_details_update_v1(
    p_session_token, p_product_id, p_product_name, p_sku,
    p_product_price, p_description, p_manufacturer, p_model,
    p_product_size, p_shelf_level, p_bin_number, p_image_url,
    p_unit, p_max_quantity);
  if not v_saved then return false; end if;
  update public.products set requires_loading = p_requires_loading
  where id = p_product_id;
  return v_saved;
end;
$$;
revoke all on function public.product_details_update_v2(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean
) from public, authenticated;
grant execute on function public.product_details_update_v2(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean
) to anon, service_role;

-- Freeze the handling requirement on each order line when checkout is confirmed.
create or replace function private.assign_order_loading_v1()
returns trigger language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_has_heavy boolean;
  v_has_light boolean;
  v_bodegero record;
  v_item_count integer;
begin
  v_item_count := jsonb_array_length(new.items);
  select jsonb_agg(
    item.value || jsonb_build_object(
      'requires_loading', coalesce(product.requires_loading, false),
      'heavy_verified', false
    ) order by item.position
  ) into new.items
  from jsonb_array_elements(new.items) with ordinality item(value, position)
  join public.products product
    on product.id = (item.value ->> 'product_id')::uuid
   and product.location_id = new.location_id;
  if new.items is null or jsonb_array_length(new.items) <> v_item_count then
    raise exception 'order_items_invalid';
  end if;

  select coalesce(bool_or((item ->> 'requires_loading')::boolean), false),
         coalesce(bool_or(not (item ->> 'requires_loading')::boolean), false)
    into v_has_heavy, v_has_light
  from jsonb_array_elements(new.items) item;
  if not v_has_light then
    new.assigned_helper_id := null;
    new.assigned_helper_name := null;
    new.assigned_at := null;
  end if;
  if not v_has_heavy then return new; end if;

  perform pg_advisory_xact_lock(
    hashtextextended('bodegero-assign:' || new.location_id::text, 0)
  );

  select profile.id, profile.name into v_bodegero
  from public.profiles profile
  left join lateral (
    select count(*) as active_count
    from public.orders work
    where work.location_id = new.location_id
      and work.assigned_bodegero_id = profile.id::text
      and work.status in ('pending', 'solo_picking')
  ) workload on true
  where profile.location_id = new.location_id
    and profile.role = 'bodegero'
    and profile.is_active
  order by workload.active_count, profile.id
  limit 1;
  if found then
    new.assigned_bodegero_id := v_bodegero.id::text;
    new.assigned_bodegero_name := v_bodegero.name;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_assign_loading_v1 on public.orders;
create trigger orders_assign_loading_v1 before insert on public.orders
for each row execute function private.assign_order_loading_v1();

create or replace function private.reject_heavy_only_helper_assignment_v1()
returns trigger language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
begin
  if new.assigned_helper_id is not null and not exists (
    select 1 from jsonb_array_elements(new.items) item
    where item ->> 'requires_loading' is distinct from 'true'
  ) then raise exception 'heavy_only_order_requires_bodegero'; end if;
  return new;
end;
$$;
drop trigger if exists orders_reject_heavy_only_helper_v1 on public.orders;
create trigger orders_reject_heavy_only_helper_v1
before update of assigned_helper_id on public.orders for each row
execute function private.reject_heavy_only_helper_assignment_v1();

-- Product QR verification for an assigned Bodegero. It records identity only;
-- the loading proof checks the full physical quantity separately.
create or replace function public.verify_heavy_order_item_v1(
  p_session_token text, p_order_id uuid, p_product_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_order public.orders%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'bodegero_required' using errcode = '42501';
  end if;
  select * into v_order from public.orders
  where id = p_order_id and location_id = v_actor.location_id
    and assigned_bodegero_id = v_actor.profile_id::text
    and status in ('pending', 'solo_picking') for update;
  if not found then raise exception 'loading_assignment_conflict'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_order.items) item
    where item ->> 'product_id' = p_product_id::text
      and item ->> 'requires_loading' = 'true'
  ) then raise exception 'heavy_item_not_on_order'; end if;

  insert into public.order_heavy_scans (order_id, product_id, bodegero_id)
  values (p_order_id, p_product_id, v_actor.profile_id)
  on conflict (order_id, product_id) do update
    set bodegero_id = excluded.bodegero_id, scanned_at = now();

  update public.orders set items = (
    select jsonb_agg(
      case when item.value ->> 'product_id' = p_product_id::text
        then item.value || '{"heavy_verified":true}'::jsonb
        else item.value end order by item.position)
    from jsonb_array_elements(v_order.items) with ordinality item(value, position)
  ), updated_at = now()
  where id = p_order_id returning * into v_order;
  return to_jsonb(v_order);
end;
$$;
revoke all on function public.verify_heavy_order_item_v1(text, uuid, uuid)
  from public, authenticated;
grant execute on function public.verify_heavy_order_item_v1(text, uuid, uuid)
  to anon, service_role;

create or replace function public.finish_order_loading_v1(
  p_session_token text, p_order_id uuid, p_truck_plate text,
  p_loaded_quantities jsonb, p_photo_base64 text
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_order public.orders%rowtype;
  v_photo bytea;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'bodegero_required' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_truck_plate, '')), '') is null
      or length(trim(p_truck_plate)) > 32
      or jsonb_typeof(p_loaded_quantities) <> 'object' then
    raise exception 'loading_details_invalid';
  end if;
  if p_photo_base64 is null then raise exception 'loading_photo_invalid'; end if;
  v_photo := decode(p_photo_base64, 'base64');
  if octet_length(v_photo) < 100 or octet_length(v_photo) > 1048576
      or substring(v_photo from 1 for 3) <> decode('ffd8ff', 'hex') then
    raise exception 'loading_photo_invalid';
  end if;
  select * into v_order from public.orders
  where id = p_order_id and location_id = v_actor.location_id
    and assigned_bodegero_id = v_actor.profile_id::text
    and status in ('pending', 'solo_picking') for update;
  if not found then raise exception 'loading_assignment_conflict'; end if;
  if v_order.loading_verified_at is not null then
    raise exception 'loading_already_verified';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_order.items) item
    where item ->> 'requires_loading' = 'true'
  ) then raise exception 'heavy_item_not_on_order'; end if;
  if exists (
    select 1 from jsonb_array_elements(v_order.items) item
    where item ->> 'requires_loading' = 'true'
      and (item ->> 'heavy_verified' is distinct from 'true'
        or not exists (
          select 1 from public.order_heavy_scans scan
          where scan.order_id = p_order_id
            and scan.product_id = (item ->> 'product_id')::uuid
            and scan.bodegero_id = v_actor.profile_id
        )
        or not (p_loaded_quantities ? (item ->> 'product_id'))
        or jsonb_typeof(p_loaded_quantities -> (item ->> 'product_id'))
           is distinct from 'number'
        or (p_loaded_quantities ->> (item ->> 'product_id')) !~ '^[0-9]+([.][0-9]+)?$'
        or (p_loaded_quantities ->> (item ->> 'product_id'))::numeric
           <> (item ->> 'quantity')::numeric)
  ) or (select count(*) from jsonb_object_keys(p_loaded_quantities)) <>
      (select count(*) from jsonb_array_elements(v_order.items) item
       where item ->> 'requires_loading' = 'true') then
    raise exception 'loaded_quantity_mismatch';
  end if;

  insert into public.order_loading_proofs (
    order_id, location_id, bodegero_id, truck_plate,
    loaded_quantities, photo_jpeg
  ) values (
    p_order_id, v_actor.location_id, v_actor.profile_id,
    trim(p_truck_plate), p_loaded_quantities, v_photo
  );
  update public.orders set loading_verified_at = now(),
    status = case when not exists (
      select 1 from jsonb_array_elements(v_order.items) item
      where item ->> 'requires_loading' <> 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then 'prepared' else status end,
    prepared_at = case when not exists (
      select 1 from jsonb_array_elements(v_order.items) item
      where item ->> 'requires_loading' <> 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then now() else prepared_at end,
    prepared_by_id = case when not exists (
      select 1 from jsonb_array_elements(v_order.items) item
      where item ->> 'requires_loading' <> 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then v_actor.profile_id::text else prepared_by_id end,
    prepared_by = case when not exists (
      select 1 from jsonb_array_elements(v_order.items) item
      where item ->> 'requires_loading' <> 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then v_actor.profile_id else prepared_by end,
    prepared_by_name = case when not exists (
      select 1 from jsonb_array_elements(v_order.items) item
      where item ->> 'requires_loading' <> 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then v_actor.profile_name else prepared_by_name end,
    updated_at = now()
  where id = p_order_id returning * into v_order;
  return to_jsonb(v_order);
end;
$$;
revoke all on function public.finish_order_loading_v1(text, uuid, text, jsonb, text)
  from public, authenticated;
grant execute on function public.finish_order_loading_v1(text, uuid, text, jsonb, text)
  to anon, service_role;

-- A Bodegero may take an unassigned heavy order if no active account existed
-- when checkout was confirmed.
create or replace function public.claim_order_loading_v1(
  p_session_token text, p_order_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_order public.orders%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'bodegero_required' using errcode = '42501';
  end if;
  update public.orders set
    assigned_bodegero_id = v_actor.profile_id::text,
    assigned_bodegero_name = v_actor.profile_name,
    updated_at = now()
  where id = p_order_id and location_id = v_actor.location_id
    and assigned_bodegero_id is null
    and loading_verified_at is null
    and status in ('pending', 'solo_picking')
    and exists (
      select 1 from jsonb_array_elements(items) item
      where item ->> 'requires_loading' = 'true'
    )
  returning * into v_order;
  if not found then raise exception 'loading_claim_conflict'; end if;
  return to_jsonb(v_order);
end;
$$;
revoke all on function public.claim_order_loading_v1(text, uuid)
  from public, authenticated;
grant execute on function public.claim_order_loading_v1(text, uuid)
  to anon, service_role;

create or replace function public.get_order_loading_proof_v1(
  p_session_token text, p_order_id uuid
) returns jsonb language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_proof public.order_loading_proofs%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role not in ('admin', 'staff', 'bodegero') then
    raise exception 'loading_proof_forbidden' using errcode = '42501';
  end if;
  select * into v_proof from public.order_loading_proofs
  where order_id = p_order_id and location_id = v_actor.location_id
    and (v_actor.role <> 'bodegero' or bodegero_id = v_actor.profile_id);
  if not found then return null; end if;
  return jsonb_build_object(
    'truck_plate', v_proof.truck_plate,
    'loaded_quantities', v_proof.loaded_quantities,
    'captured_at', v_proof.captured_at,
    'bodegero_id', v_proof.bodegero_id,
    'photo_base64', encode(v_proof.photo_jpeg, 'base64')
  );
end;
$$;
revoke all on function public.get_order_loading_proof_v1(text, uuid)
  from public, authenticated;
grant execute on function public.get_order_loading_proof_v1(text, uuid)
  to anon, service_role;

CREATE OR REPLACE FUNCTION public.update_staff_account_v1(
  p_session_token text,
  p_target_profile_id bigint,
  p_name text,
  p_email text,
  p_phone text,
  p_role text,
  p_is_active boolean,
  p_address text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id bigint;
  v_admin_role text;
  v_location_id uuid;
  v_target public.profiles%rowtype;
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  select session_profile.profile_id, session_profile.role,
         session_profile.location_id
    into v_admin_id, v_admin_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  if trim(coalesce(p_name, '')) = '' or
     v_role not in ('admin', 'staff', 'helper', 'bodegero') or
     p_is_active is null then
    return false;
  end if;

  -- Serialize account status changes within the store so two admins cannot
  -- simultaneously remove the last active administrator.
  perform pg_advisory_xact_lock(hashtextextended(v_location_id::text, 0));
  select * into v_target
  from public.profiles
  where id = p_target_profile_id and location_id = v_location_id
  for update;
  if not found then return false; end if;

  if v_target.id = v_admin_id and
     (v_role <> 'admin' or not p_is_active) then
    return false;
  end if;
  if v_target.role = 'admin' and v_target.is_active and
     (v_role <> 'admin' or not p_is_active) and
     (select count(*) from public.profiles
      where location_id = v_location_id and role = 'admin' and is_active) <= 1 then
    return false;
  end if;

  update public.profiles
  set name = trim(p_name),
      email = nullif(trim(coalesce(p_email, '')), ''),
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      address = case when p_address is null then address else nullif(trim(p_address), '') end,
      role = v_role,
      is_active = p_is_active
  where id = p_target_profile_id;

  if v_target.role is distinct from v_role or
     (v_target.is_active and not p_is_active) then
    update private.app_sessions
    set revoked_at = now()
    where profile_id = p_target_profile_id and revoked_at is null;
  end if;
  if not p_is_active then
    update public.staff_presence
    set is_online = false,
        current_module = null,
        logged_out_at = now()
    where user_id = p_target_profile_id::text;
  end if;
  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.auto_assign_pending_orders_v1 (
  p_session_token text
)
  RETURNS TABLE (
    order_id    text,
    helper_id   text,
    helper_name text,
    assigned_at timestamp with time zone
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_role text;
  v_location_id uuid;
  v_order_id public.orders.id%type;
  v_helper_id public.profiles.id%type;
  v_helper_name public.profiles.name%type;
  v_assigned_at timestamptz;
  v_auto_assign boolean := true;
  v_max_active integer := 3;
begin
  select session_profile.role,
         session_profile.location_id
    into v_role, v_location_id
    from private.require_app_session_v1(p_session_token) session_profile;

  if not found or v_role not in ('admin', 'staff', 'cashier', 'helper', 'bodegero') then
    raise exception 'Application session is invalid or expired';
  end if;

  select coalesce(settings.auto_assign_orders, true),
         coalesce(settings.max_active_orders_per_helper, 3)
    into v_auto_assign, v_max_active
    from public.store_settings settings
   where settings.location_id = v_location_id;
  if not found then
    v_auto_assign := true;
    v_max_active := 3;
  end if;
  if not v_auto_assign then return; end if;

  -- All clients reconciling the same store serialize behind one transaction
  -- lock. The conditional UPDATE remains the final ownership guard.
  perform pg_advisory_xact_lock(
    hashtextextended('auto-assign:' || v_location_id::text, 0)
  );

  for v_order_id in
    select pending.id
      from public.orders pending
     where pending.location_id = v_location_id
       and lower(pending.status) = 'pending'
       and pending.assigned_helper_id is null
       and exists (
         select 1 from jsonb_array_elements(pending.items) item
         where item ->> 'requires_loading' is distinct from 'true'
       )
     order by pending.created_at asc, pending.id asc
     for update skip locked
  loop
    select profile.id, profile.name
      into v_helper_id, v_helper_name
      from public.staff_presence presence
      join public.profiles profile
        -- Presence identity is written by the custom-auth client. Compare its
        -- textual representation to the numeric profile key so this migration
        -- remains compatible with the repository's existing presence schema.
        on profile.id::text = presence.user_id::text
       and profile.location_id = v_location_id
      left join lateral (
        select count(*) filter (
                 where lower(work.status) in ('pending', 'prepared')
               )::integer as active_count,
               max(work.assigned_at) as last_assigned_at
          from public.orders work
         where work.location_id = v_location_id
           -- orders.assigned_helper_id is text while profiles.id is bigint.
           -- Cast the profile key once; do not cast the order column so an
           -- assignment lookup index can remain usable.
           and work.assigned_helper_id = profile.id::text
      ) workload on true
     where presence.location_id = v_location_id::text
       and presence.is_online = true
       and presence.last_seen_at >= clock_timestamp() - interval '2 minutes'
       and lower(presence.user_role) = 'helper'
       and lower(profile.role) = 'helper'
       and coalesce(workload.active_count, 0) < v_max_active
     order by coalesce(workload.active_count, 0) asc,
              workload.last_assigned_at asc nulls first,
              profile.id asc
     limit 1;

    if v_helper_id is null then
      exit;
    end if;

    v_assigned_at := clock_timestamp();

    update public.orders assigned
       set assigned_helper_id = v_helper_id::text,
           assigned_helper_name = v_helper_name,
           assigned_at = v_assigned_at,
           assigned_by_admin_id = null,
           assigned_by_admin_name = null
     where assigned.id = v_order_id
       and assigned.location_id = v_location_id
       and lower(assigned.status) = 'pending'
       and assigned.assigned_helper_id is null;

    if found then
      order_id := v_order_id::text;
      helper_id := v_helper_id::text;
      helper_name := v_helper_name;
      assigned_at := v_assigned_at;
      return next;
    end if;
  end loop;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."auto_assign_pending_orders_v1"(text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."auto_assign_pending_orders_v1"(text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."auto_assign_pending_orders_v1"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."auto_assign_pending_orders_v1"(text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."auto_assign_pending_orders_v1"(text) FROM PUBLIC, "authenticated";

-- Persist verified helper picks on the order so all store sessions receive
-- progress through the existing orders realtime publication.
CREATE OR REPLACE FUNCTION public.mark_order_item_picked_v1(
  p_session_token text,
  p_order_id uuid,
  p_product_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_profile record;
  v_order public.orders%rowtype;
  v_product_id text := nullif(trim(coalesce(p_product_id, '')), '');
  v_item jsonb;
  v_updated_items jsonb;
BEGIN
  SELECT * INTO v_profile
  FROM private.require_app_session_v1(p_session_token);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Picking session is invalid or expired';
  END IF;
  IF v_profile.role <> 'helper' OR v_product_id IS NULL THEN
    RAISE EXCEPTION 'order_picking_not_allowed';
  END IF;

  SELECT * INTO v_order
  FROM public.orders customer_order
  WHERE customer_order.id = p_order_id
    AND customer_order.location_id = v_profile.location_id
    AND customer_order.status = 'pending'
    AND customer_order.assigned_helper_id = v_profile.profile_id::text
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_picking_conflict';
  END IF;

  SELECT entry.item INTO v_item
  FROM jsonb_array_elements(v_order.items) AS entry(item)
  WHERE coalesce(entry.item->>'product_id', entry.item->>'productId') = v_product_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_item_not_found';
  END IF;
  IF v_item->>'requires_loading' = 'true' THEN
    RAISE EXCEPTION 'heavy_item_requires_bodegero';
  END IF;
  IF v_item->>'picked' = 'true' THEN
    RETURN to_jsonb(v_order);
  END IF;

  SELECT jsonb_agg(
    CASE
      WHEN coalesce(entry.item->>'product_id', entry.item->>'productId') = v_product_id
        THEN entry.item || jsonb_build_object('picked', true)
      ELSE entry.item
    END ORDER BY entry.position
  ) INTO v_updated_items
  FROM jsonb_array_elements(v_order.items) WITH ORDINALITY AS entry(item, position);

  UPDATE public.orders customer_order
  SET items = v_updated_items,
      updated_at = now()
  WHERE customer_order.id = p_order_id
  RETURNING customer_order.* INTO v_order;

  RETURN to_jsonb(v_order);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_order_item_picked_v1(text, uuid, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.mark_order_item_picked_v1(text, uuid, text)
  FROM PUBLIC, authenticated;

-- Preparation cannot complete until both workers' evidence is present.
create or replace function private.require_order_work_verified_v1()
returns trigger language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
begin
  if new.status = 'prepared' and old.status in ('pending', 'solo_picking') then
    if old.status = 'pending' and exists (
      select 1 from jsonb_array_elements(new.items) item
      where item ->> 'requires_loading' is distinct from 'true'
        and item ->> 'picked' is distinct from 'true'
    ) then raise exception 'light_items_not_verified'; end if;
    if exists (
      select 1 from jsonb_array_elements(new.items) item
      where item ->> 'requires_loading' = 'true'
    ) and (new.loading_verified_at is null or not exists (
      select 1 from public.order_loading_proofs proof
      where proof.order_id = new.id
    )) then
      raise exception 'heavy_loading_not_verified';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_require_work_verified_v1 on public.orders;
create trigger orders_require_work_verified_v1
before update of status on public.orders for each row
execute function private.require_order_work_verified_v1();

CREATE OR REPLACE FUNCTION public.profile_admin_reset_password_v1 (
  p_session_token     text,
  p_target_profile_id bigint,
  p_new_password      text
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_admin_role text;
  v_admin_location uuid;
  v_target_role text;
  v_target_username text;
  v_login_subject_key_hash bytea;
begin
  select session_profile.role, session_profile.location_id
    into v_admin_role, v_admin_location
  from private.require_app_session_v1(p_session_token) session_profile;

  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  select lower(profile.role), profile.username
    into v_target_role, v_target_username
  from public.profiles profile
  where profile.id = p_target_profile_id
    and profile.location_id = v_admin_location
  for update;

  if not found then
    return false;
  end if;

  update public.profiles
  set password = encode(
        extensions.digest(
          convert_to(coalesce(p_new_password, ''), 'UTF8'),
          'sha256'
        ),
        'hex'
      ),
      must_change_password = case
        when v_target_role in ('helper', 'bodegero', 'staff', 'cashier') then true
        else must_change_password
      end
  where id = p_target_profile_id;

  if not found then
    return false;
  end if;

  -- The password update and limiter reset share this transaction. Derive the
  -- key from the trusted target profile, never from client-supplied limiter
  -- metadata. Username matching remains case-sensitive and trim-normalized.
  v_login_subject_key_hash := extensions.digest(
    convert_to('login:' || trim(v_target_username), 'UTF8'),
    'sha256'
  );
  perform private.reset_auth_rate_limit_v1(
    'login',
    v_login_subject_key_hash
  );

  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM PUBLIC, "authenticated";


-- Secure snapshots include handling and Bodegero assignment.
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
      'map_element_id', product_row.map_element_id,
      'requires_loading', product_row.requires_loading
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
      case when v_session.role in ('helper', 'bodegero') then
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
          'assigned_bodegero_id', order_row.assigned_bodegero_id,
          'assigned_bodegero_name', order_row.assigned_bodegero_name,
          'loading_verified_at', order_row.loading_verified_at,
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
          'assigned_bodegero_id', order_row.assigned_bodegero_id,
          'assigned_bodegero_name', order_row.assigned_bodegero_name,
          'loading_verified_at', order_row.loading_verified_at,
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
      (v_session.role = 'helper' and order_row.status = 'pending'
        and (order_row.assigned_helper_id is null
          or order_row.assigned_helper_id = v_session.profile_id::text)
        and exists (select 1 from jsonb_array_elements(order_row.items) item
          where item ->> 'requires_loading' is distinct from 'true'))
      or (v_session.role = 'bodegero'
        and order_row.status in ('pending', 'solo_picking')
        and order_row.loading_verified_at is null
        and (order_row.assigned_bodegero_id is null
          or order_row.assigned_bodegero_id = v_session.profile_id::text)
        and exists (select 1 from jsonb_array_elements(order_row.items) item
          where item ->> 'requires_loading' = 'true'))
      or v_session.role not in ('helper', 'bodegero')
    );

  return v_result;
end;
$$;


-- Clear Bodegero forced password after first change.
create or replace function public.profile_change_password_v1(
  p_session_token text,
  p_current_password text,
  p_new_password text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile_id bigint;
  v_role text;
  v_current_hash text;
  v_new_hash text;
  v_session_token text;
  v_expires_at timestamptz;
begin
  select session_profile.profile_id, session_profile.role
    into v_profile_id, v_role
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then
    return jsonb_build_object('status', 'not_authenticated');
  end if;

  v_current_hash := encode(extensions.digest(
    convert_to(coalesce(p_current_password, ''), 'UTF8'), 'sha256'), 'hex');
  v_new_hash := encode(extensions.digest(
    convert_to(coalesce(p_new_password, ''), 'UTF8'), 'sha256'), 'hex');

  if not exists (
    select 1 from public.profiles profile
    where profile.id = v_profile_id and profile.password = v_current_hash
  ) then return jsonb_build_object('status', 'incorrect_current'); end if;

  if v_new_hash = v_current_hash then
    return jsonb_build_object('status', 'same_password');
  end if;

  if length(coalesce(p_new_password, '')) < 8
    or p_new_password !~ '[A-Z]'
    or p_new_password !~ '[a-z]'
    or p_new_password !~ '[0-9]'
    or p_new_password !~ '[!@#$%^&*(),.?":{}|<>]'
  then return jsonb_build_object('status', 'invalid_new'); end if;

  update public.profiles
  set password = v_new_hash,
      must_change_password = case
        when v_role in ('helper', 'bodegero', 'staff', 'cashier') then false
        else must_change_password
      end
  where id = v_profile_id and password = v_current_hash;

  if not found then
    return jsonb_build_object('status', 'concurrent_change');
  end if;

  -- The password trigger revoked every older session. Issue one replacement
  -- only after the password update has completed.
  select issued.session_token, issued.expires_at
    into v_session_token, v_expires_at
  from private.issue_app_session_v1(v_profile_id) issued;

  return jsonb_build_object(
    'status', 'success',
    'session_token', v_session_token,
    'expires_at', v_expires_at
  );
end;
$$;



-- Secure staff creation and role updates accept the Bodegero role.
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
     or v_role not in ('admin', 'staff', 'helper', 'bodegero') then
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
    v_role in ('staff', 'helper', 'bodegero')
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
  if v_role not in ('admin', 'staff', 'helper', 'bodegero') then
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


commit;
