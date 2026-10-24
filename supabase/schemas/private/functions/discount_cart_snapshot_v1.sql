CREATE OR REPLACE FUNCTION private.discount_cart_snapshot_v1 (
  p_location_id    uuid,
  p_items          jsonb,
  p_discount_mode  text,
  p_discount_value numeric,
  p_checkout_token text
)
  RETURNS TABLE (
    normalized_items     jsonb,
    subtotal_amount      numeric,
    discount_amount      numeric,
    effective_percentage numeric,
    cart_fingerprint     text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_mode text := lower(trim(coalesce(p_discount_mode, '')));
  v_value numeric := coalesce(p_discount_value, 0);
  v_requested_count integer;
  v_unique_count integer;
  v_matched_count integer;
  v_quantities_valid boolean;
  v_items jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_effective numeric;
  v_fingerprint text;
begin
  if p_location_id is null then raise exception 'Location is required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The cart cannot be empty';
  end if;
  if v_mode not in ('percentage', 'amount') then
    raise exception 'Unsupported discount mode';
  end if;
  if v_value < 0 then raise exception 'Discount cannot be negative'; end if;
  if v_mode = 'percentage' and v_value > 100 then
    raise exception 'Percentage discount cannot exceed 100%%';
  end if;
  if length(trim(coalesce(p_checkout_token, ''))) < 16 then
    raise exception 'Checkout snapshot token is invalid';
  end if;

  with requested as (
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) entry
  )
  select count(*), count(distinct product_id), bool_and(quantity > 0)
    into v_requested_count, v_unique_count, v_quantities_valid
  from requested;

  if v_requested_count <> jsonb_array_length(p_items)
      or v_unique_count <> v_requested_count
      or not coalesce(v_quantities_valid, false) then
    raise exception 'Cart items or quantities are invalid';
  end if;

  with requested as (
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) entry
  ), scoped as (
    select product.id, product.product_name, product.unit,
      product.product_price, requested.quantity
    from requested
    join public.products product on product.id = requested.product_id
    where product.location_id = p_location_id
      and coalesce(product.is_active, true)
      and requested.quantity <= product.product_quantity
  )
  select
    count(*),
    jsonb_agg(
      jsonb_build_object(
        'product_id', scoped.id,
        'product_name', scoped.product_name,
        'quantity', scoped.quantity,
        'unit', coalesce(nullif(trim(scoped.unit), ''), 'pcs'),
        'unit_price', scoped.product_price,
        'line_total', round(scoped.product_price * scoped.quantity, 2)
      ) order by scoped.id
    ),
    round(sum(scoped.product_price * scoped.quantity), 2)
  into v_matched_count, v_items, v_subtotal
  from scoped;

  if v_matched_count <> v_requested_count then
    raise exception 'A cart item is unavailable or exceeds current stock';
  end if;

  v_subtotal := coalesce(v_subtotal, 0);
  v_discount := round(case v_mode
    when 'percentage' then v_subtotal * (v_value / 100)
    else v_value
  end, 2);
  if v_discount > v_subtotal then
    raise exception 'Discount cannot exceed subtotal';
  end if;
  v_effective := case when v_subtotal <= 0 then 0
    else round((v_discount / v_subtotal) * 100, 6) end;
  v_fingerprint := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'items', v_items,
      'subtotal', v_subtotal,
      'discount_mode', v_mode,
      'discount_value', v_value,
      'discount_amount', v_discount,
      'effective_percentage', v_effective,
      'checkout_token', trim(p_checkout_token)
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');

  return query select v_items, v_subtotal, v_discount, v_effective,
    v_fingerprint;
end;
$function$;

CREATE OR REPLACE FUNCTION private.discount_cart_snapshot_v1 (
  p_location_id    uuid,
  p_items          jsonb,
  p_discount_mode  text,
  p_discount_value numeric,
  p_reason         text,
  p_checkout_token text
)
  RETURNS TABLE (
    normalized_items     jsonb,
    subtotal_amount      numeric,
    discount_amount      numeric,
    effective_percentage numeric,
    cart_fingerprint     text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
  select * from private.discount_cart_snapshot_v1(
    p_location_id, p_items, p_discount_mode, p_discount_value,
    p_checkout_token
  )
$function$;

REVOKE ALL ON FUNCTION "private"."discount_cart_snapshot_v1"(uuid, jsonb, text, numeric, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "private"."discount_cart_snapshot_v1"(uuid, jsonb, text, numeric, text, text) FROM PUBLIC;
