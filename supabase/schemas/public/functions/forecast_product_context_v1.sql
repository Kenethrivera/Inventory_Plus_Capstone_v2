-- Inventory Plus forecasting module: authenticated product/inventory context.
--
-- This is the only product-table read required by the forecasting API. It is
-- intentionally read-only, Admin-only, and location-scoped through the opaque
-- application session. It does not expose supplier data or mutate inventory.

create or replace function public.forecast_product_context_v1(
  p_session_token text,
  p_product_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'pg_temp'
as $function$
declare
  v_profile record;
  v_product record;
begin
  if p_product_id is null then
    raise exception 'Forecast product identifier is required';
  end if;

  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Forecasting session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Forecasting product context is not allowed for this profile';
  end if;

  select
    product.id,
    product.location_id,
    product.sku,
    product.product_name,
    product.unit,
    product.product_quantity,
    product.max_quantity,
    product.created_at,
    product.updated_at,
    product.is_active
  into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id
    and product.is_active;

  if not found then
    return null;
  end if;
  if v_product.id is distinct from p_product_id
      or v_product.location_id is distinct from v_profile.location_id
      or nullif(pg_catalog.btrim(v_product.product_name), '') is null
      or nullif(pg_catalog.btrim(v_product.unit), '') is null then
    raise exception 'Forecast product identity or inventory unit is invalid';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', v_product.id,
    'location_id', v_product.location_id,
    'sku', v_product.sku,
    'product_name', v_product.product_name,
    'unit', v_product.unit,
    'product_quantity', v_product.product_quantity,
    'max_quantity', v_product.max_quantity,
    'created_at', v_product.created_at,
    'updated_at', v_product.updated_at,
    'is_active', v_product.is_active
  );
end;
$function$;

revoke all on function public.forecast_product_context_v1(text, uuid)
  from public, authenticated;

grant execute on function public.forecast_product_context_v1(text, uuid)
  to anon, service_role, postgres;
