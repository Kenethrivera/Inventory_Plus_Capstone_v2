CREATE OR REPLACE FUNCTION public.forecast_replenishment_config_v1 (
  p_session_token text,
  p_product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_profile record;
  v_product record;
  v_config record;
  v_configured boolean;
begin
  if p_product_id is null then
    raise exception 'Forecast product identifier is required';
  end if;
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Forecasting session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Forecast replenishment configuration is not allowed for this profile';
  end if;

  select product.id, product.location_id, product.unit into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id
    and product.is_active;
  if not found then return null; end if;
  if nullif(pg_catalog.btrim(v_product.unit), '') is null then
    raise exception 'Forecast product inventory unit is invalid';
  end if;

  select config.* into v_config
  from public.forecast_replenishment_configs config
  where config.product_id = v_product.id
    and config.location_id = v_profile.location_id;
  v_configured := found;

  return pg_catalog.jsonb_build_object(
    'configured', v_configured,
    'product_id', v_product.id,
    'location_id', v_profile.location_id,
    'inventory_unit', v_product.unit,
    'supplier_lead_time_days', case when v_configured then v_config.supplier_lead_time_days else null end,
    'review_period_days', case when v_configured then v_config.review_period_days else null end,
    'safety_stock', case when v_configured then v_config.safety_stock else null end,
    'minimum_order_quantity', case when v_configured then v_config.minimum_order_quantity else null end,
    'supplier_pack_size', case when v_configured then v_config.supplier_pack_size else null end,
    'supplier_order_unit', case when v_configured then v_config.supplier_order_unit else null end,
    'unit_conversion_factor', case when v_configured then v_config.unit_conversion_factor else null end,
    'confirmed_incoming_quantity', case when v_configured then v_config.confirmed_incoming_quantity else null end,
    'incoming_quantity_verified', case when v_configured then v_config.incoming_quantity_verified else false end,
    'backorder_quantity', case when v_configured then v_config.backorder_quantity else null end,
    'backorder_quantity_verified', case when v_configured then v_config.backorder_quantity_verified else false end,
    'supplier_availability', case when v_configured then v_config.supplier_availability else null end,
    'data_source', case when v_configured then v_config.data_source else null end,
    'source_captured_at', case when v_configured then v_config.source_captured_at else null end,
    'rationale', case when v_configured then v_config.rationale else null end,
    'updated_at', case when v_configured then v_config.updated_at else null end,
    'updated_by_profile_id', case when v_configured then v_config.updated_by_profile_id else null end
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.forecast_replenishment_config_v1(text, uuid)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_replenishment_config_v1(text, uuid)
  TO anon, service_role, postgres;
