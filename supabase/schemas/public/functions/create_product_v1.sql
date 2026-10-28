CREATE OR REPLACE FUNCTION public.create_product_v1 (
  p_session_token       text,
  p_operation_id        text,
  p_sku                 text,
  p_product_name        text,
  p_category            text,
  p_product_price       numeric,
  p_product_quantity    numeric,
  p_description         text,
  p_image_url           text,
  p_manufacturer        text,
  p_model               text,
  p_product_size        text,
  p_shelf_level         text,
  p_bin_number          text,
  p_unit                text,
  p_max_quantity        numeric
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_product public.products;
  v_operation_id text := nullif(trim(coalesce(p_operation_id, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Product session is invalid or expired'; end if;
  if v_operation_id is null or length(v_operation_id) < 16 then
    raise exception 'product_submission_invalid';
  end if;
  if nullif(trim(coalesce(p_sku, '')), '') is null
      or nullif(trim(coalesce(p_product_name, '')), '') is null
      or p_product_price is null or p_product_price < 0
      or p_product_quantity is null or p_product_quantity < 0
      or p_max_quantity is null or p_max_quantity < 0 then
    raise exception 'product_data_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'product-create:' || v_operation_id,
    0
  ));
  select product.* into v_product
  from public.products product
  where product.create_operation_id = v_operation_id;
  if found then
    if v_product.location_id is distinct from v_profile.location_id
        or v_product.sku is distinct from trim(p_sku)
        or v_product.product_name is distinct from trim(p_product_name) then
      raise exception 'product_submission_conflict';
    end if;
    return to_jsonb(v_product);
  end if;

  begin
    insert into public.products (
      sku, product_name, category, product_price, product_quantity,
      description, image_url, location_id, manufacturer, model,
      product_size, shelf_level, bin_number, unit, max_quantity,
      create_operation_id
    ) values (
      trim(p_sku), trim(p_product_name), p_category, p_product_price,
      p_product_quantity, p_description, p_image_url, v_profile.location_id,
      p_manufacturer, p_model, p_product_size, p_shelf_level, p_bin_number,
      coalesce(nullif(trim(p_unit), ''), 'pcs'), p_max_quantity,
      v_operation_id
    ) returning * into v_product;
  exception when unique_violation then
    raise exception 'product_sku_already_exists';
  end;

  insert into public.transaction_history (
    product_id, transaction_type, quantity_change, new_quantity,
    location_id, user_id, user_name, operation_id, operation_scope
  ) values (
    v_product.id, 'add', v_product.product_quantity,
    v_product.product_quantity, v_profile.location_id, v_profile.profile_id,
    v_profile.profile_name, v_operation_id, 'product_create'
  );
  return to_jsonb(v_product);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.create_product_v1(
  text, text, text, text, text, numeric, numeric, text, text, text, text,
  text, text, text, text, numeric
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.create_product_v1(
  text, text, text, text, text, numeric, numeric, text, text, text, text,
  text, text, text, text, numeric
) FROM PUBLIC, authenticated;
