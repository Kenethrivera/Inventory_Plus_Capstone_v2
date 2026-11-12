CREATE OR REPLACE FUNCTION public.upsert_forecast_replenishment_config_v1 (
  p_session_token text, p_product_id uuid,
  p_supplier_lead_time_days integer, p_review_period_days integer,
  p_safety_stock numeric, p_minimum_order_quantity numeric,
  p_supplier_pack_size numeric, p_supplier_order_unit text,
  p_unit_conversion_factor numeric, p_confirmed_incoming_quantity numeric,
  p_incoming_quantity_verified boolean, p_backorder_quantity numeric,
  p_backorder_quantity_verified boolean, p_supplier_availability text,
  p_data_source text, p_source_captured_at timestamp with time zone,
  p_rationale text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_profile record;
  v_product record;
  v_config public.forecast_replenishment_configs;
  v_order_unit text := nullif(pg_catalog.btrim(coalesce(p_supplier_order_unit, '')), '');
  v_availability text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(p_supplier_availability, ''))), '');
  v_source text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_data_source, '')));
  v_rationale text := nullif(pg_catalog.btrim(coalesce(p_rationale, '')), '');
  v_source_captured_at timestamp with time zone := coalesce(p_source_captured_at, pg_catalog.now());
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Forecasting session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Forecast replenishment configuration is not allowed for this profile';
  end if;

  select product.id, product.location_id, product.unit into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id
    and product.is_active;
  if not found then raise exception 'Forecast product was not found in the authorized location'; end if;
  if nullif(pg_catalog.btrim(v_product.unit), '') is null then
    raise exception 'Forecast product inventory unit is invalid';
  end if;

  if p_supplier_lead_time_days is not null and (p_supplier_lead_time_days < 0 or p_supplier_lead_time_days > 3650)
      or p_review_period_days is not null and (p_review_period_days < 0 or p_review_period_days > 365)
      or p_safety_stock is not null and (p_safety_stock < 0 or p_safety_stock = 'NaN'::numeric)
      or p_minimum_order_quantity is not null and (p_minimum_order_quantity < 0 or p_minimum_order_quantity = 'NaN'::numeric)
      or p_supplier_pack_size is not null and (p_supplier_pack_size <= 0 or p_supplier_pack_size = 'NaN'::numeric)
      or p_unit_conversion_factor is not null and (p_unit_conversion_factor <= 0 or p_unit_conversion_factor = 'NaN'::numeric)
  then raise exception 'Forecast replenishment configuration contains invalid values'; end if;
  if v_availability is not null and v_availability not in ('available', 'unavailable', 'unknown') then
    raise exception 'Forecast supplier availability is invalid';
  end if;
  if v_source not in ('admin_estimate', 'verified_record') then
    raise exception 'Forecast replenishment data source is invalid';
  end if;
  if v_source = 'admin_estimate' and v_rationale is null then
    raise exception 'Admin estimates require a rationale';
  end if;
  if v_source_captured_at > pg_catalog.now() + interval '5 minutes' then
    raise exception 'Forecast replenishment source timestamp is invalid';
  end if;
  if (p_minimum_order_quantity is not null or p_supplier_pack_size is not null)
      and v_order_unit is null then
    raise exception 'Supplier order unit is required for MOQ or pack size';
  end if;
  if p_unit_conversion_factor is not null and v_order_unit is null then
    raise exception 'Supplier order unit is required for unit conversion';
  end if;
  if v_order_unit is not null
      and pg_catalog.lower(v_order_unit) <> pg_catalog.lower(v_product.unit)
      and p_unit_conversion_factor is null then
    raise exception 'Supplier unit conversion is required';
  end if;
  if (p_confirmed_incoming_quantity is null) is distinct from (not coalesce(p_incoming_quantity_verified, false))
      or p_confirmed_incoming_quantity is not null
        and (p_confirmed_incoming_quantity < 0 or p_confirmed_incoming_quantity = 'NaN'::numeric) then
    raise exception 'Incoming quantity must be present only when verified';
  end if;
  if (p_backorder_quantity is null) is distinct from (not coalesce(p_backorder_quantity_verified, false))
      or p_backorder_quantity is not null
        and (p_backorder_quantity < 0 or p_backorder_quantity = 'NaN'::numeric) then
    raise exception 'Backorder quantity must be present only when verified';
  end if;

  insert into public.forecast_replenishment_configs as config (
    product_id, location_id, supplier_lead_time_days, review_period_days,
    safety_stock, minimum_order_quantity, supplier_pack_size,
    supplier_order_unit, unit_conversion_factor,
    confirmed_incoming_quantity, incoming_quantity_verified,
    backorder_quantity, backorder_quantity_verified, supplier_availability,
    data_source, source_captured_at, rationale, updated_at,
    updated_by_profile_id
  ) values (
    v_product.id, v_profile.location_id, p_supplier_lead_time_days,
    p_review_period_days, p_safety_stock, p_minimum_order_quantity,
    p_supplier_pack_size, v_order_unit, p_unit_conversion_factor,
    p_confirmed_incoming_quantity, coalesce(p_incoming_quantity_verified, false),
    p_backorder_quantity, coalesce(p_backorder_quantity_verified, false),
    v_availability, v_source, v_source_captured_at, v_rationale,
    pg_catalog.now(), v_profile.profile_id
  )
  on conflict (product_id, location_id) do update set
    supplier_lead_time_days = excluded.supplier_lead_time_days,
    review_period_days = excluded.review_period_days,
    safety_stock = excluded.safety_stock,
    minimum_order_quantity = excluded.minimum_order_quantity,
    supplier_pack_size = excluded.supplier_pack_size,
    supplier_order_unit = excluded.supplier_order_unit,
    unit_conversion_factor = excluded.unit_conversion_factor,
    confirmed_incoming_quantity = excluded.confirmed_incoming_quantity,
    incoming_quantity_verified = excluded.incoming_quantity_verified,
    backorder_quantity = excluded.backorder_quantity,
    backorder_quantity_verified = excluded.backorder_quantity_verified,
    supplier_availability = excluded.supplier_availability,
    data_source = excluded.data_source,
    source_captured_at = excluded.source_captured_at,
    rationale = excluded.rationale,
    updated_at = excluded.updated_at,
    updated_by_profile_id = excluded.updated_by_profile_id
  returning config.* into v_config;

  return pg_catalog.jsonb_build_object(
    'configured', true, 'product_id', v_config.product_id,
    'location_id', v_config.location_id, 'inventory_unit', v_product.unit,
    'supplier_lead_time_days', v_config.supplier_lead_time_days,
    'review_period_days', v_config.review_period_days,
    'safety_stock', v_config.safety_stock,
    'minimum_order_quantity', v_config.minimum_order_quantity,
    'supplier_pack_size', v_config.supplier_pack_size,
    'supplier_order_unit', v_config.supplier_order_unit,
    'unit_conversion_factor', v_config.unit_conversion_factor,
    'confirmed_incoming_quantity', v_config.confirmed_incoming_quantity,
    'incoming_quantity_verified', v_config.incoming_quantity_verified,
    'backorder_quantity', v_config.backorder_quantity,
    'backorder_quantity_verified', v_config.backorder_quantity_verified,
    'supplier_availability', v_config.supplier_availability,
    'data_source', v_config.data_source,
    'source_captured_at', v_config.source_captured_at,
    'rationale', v_config.rationale, 'updated_at', v_config.updated_at,
    'updated_by_profile_id', v_config.updated_by_profile_id
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.upsert_forecast_replenishment_config_v1(
  text, uuid, integer, integer, numeric, numeric, numeric, text, numeric,
  numeric, boolean, numeric, boolean, text, text, timestamp with time zone, text
) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_forecast_replenishment_config_v1(
  text, uuid, integer, integer, numeric, numeric, numeric, text, numeric,
  numeric, boolean, numeric, boolean, text, text, timestamp with time zone, text
) TO anon, service_role, postgres;
