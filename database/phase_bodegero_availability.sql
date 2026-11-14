-- Apply after phase_bodegero_loading.sql.

-- Available Bodegeros alone receive or claim new heavy orders.

begin;

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
  join public.staff_presence presence
    on presence.user_id = profile.id::text
   and presence.location_id = new.location_id::text
   and lower(presence.user_role) = 'bodegero'
   and presence.is_online = true
   and presence.logged_out_at is null
   and presence.last_seen_at >= now() - interval '2 minutes'
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
  if not exists (
    select 1 from public.staff_presence presence
    where presence.user_id = v_actor.profile_id::text
      and presence.location_id = v_actor.location_id::text
      and lower(presence.user_role) = 'bodegero'
      and presence.is_online = true
      and presence.logged_out_at is null
      and presence.last_seen_at >= now() - interval '2 minutes'
  ) then
    raise exception 'bodegero_unavailable' using errcode = '42501';
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

commit;
