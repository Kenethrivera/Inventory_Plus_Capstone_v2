CREATE OR REPLACE FUNCTION public.create_inventory_approval_request_v1 (
  p_session_token text,
  p_request_type  text,
  p_product_id    uuid,
  p_quantity      numeric,
  p_reason        text    DEFAULT NULL::text,
  p_note          text    DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_product record;
  v_request public.approval_requests;
  v_type text := lower(trim(coalesce(p_request_type, '')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may request stock changes';
  end if;
  if v_type not in ('restock', 'write_off') then
    raise exception 'Unsupported approval request type';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0';
  end if;

  select product.id, product.location_id, product.product_name, product.sku,
      coalesce(product.unit, 'pcs') as unit,
      product.product_quantity, coalesce(product.is_active, true) as is_active
    into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id;

  if not found or not v_product.is_active then
    raise exception 'Item not found, disabled, or outside the active location';
  end if;
  if v_type = 'write_off' and v_reason is null then
    raise exception 'A write-off reason is required';
  end if;
  if v_type = 'write_off' and p_quantity > v_product.product_quantity then
    raise exception 'Cannot request more than the current stock';
  end if;

  insert into public.approval_requests (
    location_id, request_type, requested_by_id, requested_by_name,
    requested_by_role, product_id, product_name, product_sku, unit,
    requested_quantity, stock_at_request, reason, note
  ) values (
    v_profile.location_id, v_type, v_profile.profile_id,
    v_profile.profile_name, v_profile.role, v_product.id,
    v_product.product_name, coalesce(v_product.sku, ''), v_product.unit,
    p_quantity, v_product.product_quantity, v_reason, v_note
  ) returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);

  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text) FROM PUBLIC, "authenticated";
