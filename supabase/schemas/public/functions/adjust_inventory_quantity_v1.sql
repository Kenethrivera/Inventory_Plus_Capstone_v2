CREATE OR REPLACE FUNCTION public.adjust_inventory_quantity_v1 (
  p_session_token     text,
  p_operation_id      text,
  p_product_id        uuid,
  p_expected_quantity numeric,
  p_new_quantity      numeric,
  p_transaction_type  text,
  p_note              text    DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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

GRANT EXECUTE ON FUNCTION "public"."adjust_inventory_quantity_v1"(text, text, uuid, numeric, numeric, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."adjust_inventory_quantity_v1"(text, text, uuid, numeric, numeric, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."adjust_inventory_quantity_v1"(text, text, uuid, numeric, numeric, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."adjust_inventory_quantity_v1"(text, text, uuid, numeric, numeric, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."adjust_inventory_quantity_v1"(text, text, uuid, numeric, numeric, text, text) FROM PUBLIC, "authenticated";
