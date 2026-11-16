-- Apply after phase_bodegero_loading.sql and phase_2c_discount_approval_fix.sql, before deploying the Color client.
begin;

alter table public.products add column if not exists color text;

-- Keep product creation and its optional color in one transaction.
create or replace function public.create_product_v3(
  p_session_token text, p_operation_id text, p_sku text,
  p_product_name text, p_category text, p_product_price numeric,
  p_product_quantity numeric, p_description text, p_image_url text,
  p_manufacturer text, p_model text, p_product_size text,
  p_shelf_level text, p_bin_number text, p_unit text,
  p_max_quantity numeric, p_requires_loading boolean, p_color text
) returns jsonb language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_result jsonb;
  v_product public.products%rowtype;
begin
  v_result := public.create_product_v2(
    p_session_token, p_operation_id, p_sku, p_product_name, p_category,
    p_product_price, p_product_quantity, p_description, p_image_url,
    p_manufacturer, p_model, p_product_size, p_shelf_level, p_bin_number,
    p_unit, p_max_quantity, p_requires_loading
  );
  update public.products
  set color = nullif(btrim(p_color), '')
  where id = (v_result ->> 'id')::uuid
  returning * into v_product;
  return to_jsonb(v_product);
end;
$$;
revoke all on function public.create_product_v3(
  text, text, text, text, text, numeric, numeric, text, text, text,
  text, text, text, text, text, numeric, boolean, text
) from public, authenticated;
grant execute on function public.create_product_v3(
  text, text, text, text, text, numeric, numeric, text, text, text,
  text, text, text, text, text, numeric, boolean, text
) to anon, service_role;

-- Reuse the existing session and product checks before writing Color.
create or replace function public.product_details_update_v3(
  p_session_token text, p_product_id uuid, p_product_name text,
  p_sku text, p_product_price numeric, p_description text,
  p_manufacturer text, p_model text, p_product_size text,
  p_shelf_level text, p_bin_number text, p_image_url text,
  p_unit text, p_max_quantity numeric, p_requires_loading boolean,
  p_color text
) returns boolean language plpgsql security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_saved boolean;
begin
  v_saved := public.product_details_update_v2(
    p_session_token, p_product_id, p_product_name, p_sku,
    p_product_price, p_description, p_manufacturer, p_model,
    p_product_size, p_shelf_level, p_bin_number, p_image_url,
    p_unit, p_max_quantity, p_requires_loading
  );
  if not v_saved then return false; end if;
  update public.products
  set color = nullif(btrim(p_color), '')
  where id = p_product_id;
  return true;
end;
$$;
revoke all on function public.product_details_update_v3(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean, text
) from public, authenticated;
grant execute on function public.product_details_update_v3(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean, text
) to anon, service_role;

-- Secure inventory snapshots must include Color as well as the existing fields.
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
      'color', product_row.color,
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
-- New orders include Color in the item name used by helpers and Bodegeros.
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
    select product.id,
      case when nullif(trim(product.color), '') is null
        then product.product_name
        else product.product_name || ' · ' || trim(product.color)
      end as product_name, product.unit,
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

commit;
notify pgrst, 'reload schema';
