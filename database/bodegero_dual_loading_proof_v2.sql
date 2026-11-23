begin;

-- Cashier instructions live with the heavy line items so every order snapshot
-- delivers them to the assigned Bodegero without another database request.
create or replace function public.set_order_loading_instructions_v1(
  p_session_token text,
  p_order_id uuid,
  p_truck_identifier text,
  p_bodegero_note text
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_order public.orders%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role not in ('admin', 'staff', 'cashier') then
    raise exception 'cashier_required' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_truck_identifier, '')), '') is null
      or length(trim(p_truck_identifier)) > 32
      or nullif(trim(coalesce(p_bodegero_note, '')), '') is null
      or length(trim(p_bodegero_note)) > 240 then
    raise exception 'loading_instructions_invalid';
  end if;
  select * into v_order from public.orders
  where id = p_order_id and location_id = v_actor.location_id
    and created_by_id = v_actor.profile_id::text
    and status in ('pending', 'solo_picking') for update;
  if not found then raise exception 'loading_order_not_editable'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_order.items) item
    where item ->> 'requires_loading' = 'true'
  ) then raise exception 'heavy_item_not_on_order'; end if;
  update public.orders set items = (
    select jsonb_agg(
      case when item.value ->> 'requires_loading' = 'true' then
        item.value || jsonb_build_object(
          'truck_identifier', trim(p_truck_identifier),
          'bodegero_note', trim(p_bodegero_note)
        ) else item.value end order by item.position
    ) from jsonb_array_elements(v_order.items) with ordinality item(value, position)
  ), updated_at = now()
  where id = p_order_id returning * into v_order;
  return to_jsonb(v_order);
end;
$$;
revoke all on function public.set_order_loading_instructions_v1(text, uuid, text, text)
  from public, authenticated;
grant execute on function public.set_order_loading_instructions_v1(text, uuid, text, text)
  to anon, service_role;

-- Existing proofs remain readable; new loading submissions require both photos.
alter table public.order_loading_proofs
  add column if not exists truck_photo_jpeg bytea;

create or replace function public.finish_order_loading_v2(
  p_session_token text,
  p_order_id uuid,
  p_truck_plate text,
  p_loaded_quantities jsonb,
  p_truck_photo_base64 text,
  p_goods_photo_base64 text
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_truck_photo bytea;
  v_order jsonb;
  v_expected_truck text;
begin
  if p_truck_photo_base64 is null then
    raise exception 'truck_photo_invalid';
  end if;
  v_truck_photo := decode(p_truck_photo_base64, 'base64');
  if octet_length(v_truck_photo) < 100
      or octet_length(v_truck_photo) > 1048576
      or substring(v_truck_photo from 1 for 3) <> decode('ffd8ff', 'hex') then
    raise exception 'truck_photo_invalid';
  end if;

  -- V1 validates the Bodegero assignment, scanned items, quantities, and
  -- loaded-goods JPEG. A failure rolls back the whole V2 transaction.
  v_order := public.finish_order_loading_v1(
    p_session_token, p_order_id, p_truck_plate,
    p_loaded_quantities, p_goods_photo_base64
  );
  select item ->> 'truck_identifier' into v_expected_truck
  from public.orders order_row,
    jsonb_array_elements(order_row.items) item
  where order_row.id = p_order_id
    and item ->> 'requires_loading' = 'true'
  limit 1;
  if v_expected_truck is null or trim(v_expected_truck) <> trim(p_truck_plate) then
    raise exception 'truck_identifier_mismatch';
  end if;
  update public.order_loading_proofs
  set truck_photo_jpeg = v_truck_photo
  where order_id = p_order_id;
  return v_order;
end;
$$;

revoke all on function public.finish_order_loading_v1(text, uuid, text, jsonb, text)
  from public, anon, authenticated;
revoke all on function public.finish_order_loading_v2(text, uuid, text, jsonb, text, text)
  from public, authenticated;
grant execute on function public.finish_order_loading_v2(text, uuid, text, jsonb, text, text)
  to anon, service_role;

create or replace function public.get_order_loading_proof_v2(
  p_session_token text,
  p_order_id uuid
) returns jsonb language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_proof public.order_loading_proofs%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role not in ('admin', 'staff', 'cashier', 'bodegero') then
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
    'photo_base64', encode(v_proof.photo_jpeg, 'base64'),
    'truck_photo_base64',
    case when v_proof.truck_photo_jpeg is null then null
      else encode(v_proof.truck_photo_jpeg, 'base64') end
  );
end;
$$;

revoke all on function public.get_order_loading_proof_v2(text, uuid)
  from public, authenticated;
grant execute on function public.get_order_loading_proof_v2(text, uuid)
  to anon, service_role;

commit;
