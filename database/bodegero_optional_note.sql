begin;

-- Apply after bodegero_dual_loading_proof_v2.sql. The truck identifier remains
-- required for heavy orders; the cashier's loading note may be absent.
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
      or length(trim(coalesce(p_bodegero_note, ''))) > 240 then
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
          'bodegero_note', nullif(trim(coalesce(p_bodegero_note, '')), '')
        ) else item.value end order by item.position
    ) from jsonb_array_elements(v_order.items) with ordinality item(value, position)
  ), updated_at = now()
  where id = p_order_id returning * into v_order;
  return to_jsonb(v_order);
end;
$$;

commit;
