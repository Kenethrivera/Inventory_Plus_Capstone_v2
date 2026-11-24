-- REVIEW ONLY. Do not run without separate migration approval.
-- FastAPI authenticates the Admin and supplies the session's location_id.
-- Only the server-side service role may execute this bounded private-table read.
CREATE OR REPLACE FUNCTION public.forecast_saved_result_page_v1(
  p_location_id uuid, p_product_id uuid, p_model_key text DEFAULT NULL,
  p_page integer DEFAULT 1, p_page_size integer DEFAULT 20,
  p_result_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 20), 1), 20);
  v_count integer;
  v_items jsonb;
BEGIN
  IF p_location_id IS NULL OR p_product_id IS NULL OR
     (p_model_key IS NOT NULL AND p_model_key NOT IN
       ('blend', 'lightgbm', 'mean28', 'seasonal_experimental')) THEN
    RAISE EXCEPTION 'Invalid saved forecast scope' USING ERRCODE = '22023';
  END IF;
  SELECT count(*)::integer INTO v_count
    FROM private.forecast_execution_results r
   WHERE r.location_id = p_location_id AND r.product_id = p_product_id
     AND (p_model_key IS NULL OR r.requested_model_key = p_model_key)
     AND (p_result_id IS NULL OR r.id = p_result_id);
  SELECT coalesce(jsonb_agg(row_value ORDER BY created_at DESC, result_id DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT r.created_at, r.id AS result_id,
             jsonb_build_object(
               'result_id', r.id, 'job_id', r.job_id,
               'product_id', r.product_id, 'location_id', r.location_id,
               'model_key', r.requested_model_key,
               'model_version', r.requested_model_version,
               'forecast_start_date', r.forecast_start_date,
               'forecast_end_date', r.forecast_end_date,
               'inventory_unit', r.inventory_unit,
               'saved_at', r.created_at,
               'source_data_as_of', r.source_data_as_of,
               'as_of_business_date', r.as_of_business_date,
               'implementation_digest', r.requested_implementation_digest,
               'points', coalesce((
                 SELECT jsonb_agg(jsonb_build_object(
                   'date', point.value->>'date',
                   'quantity', point.value->>'quantity',
                   'unit', point.value->>'unit'
                 ) ORDER BY point.ordinality)
                 FROM jsonb_array_elements(coalesce(
                   r.output_bundle #> '{outputs,requested_forecasts,series,0,points}',
                   '[]'::jsonb
                 )) WITH ORDINALITY AS point(value, ordinality)
               ), '[]'::jsonb),
               'data_quality_warnings', coalesce(
                 r.output_bundle #> '{outputs,requested_forecasts,series,0,points,0,metadata,data_quality,warnings}',
                 '[]'::jsonb)
             ) AS row_value
        FROM private.forecast_execution_results r
       WHERE r.location_id = p_location_id AND r.product_id = p_product_id
         AND (p_model_key IS NULL OR r.requested_model_key = p_model_key)
         AND (p_result_id IS NULL OR r.id = p_result_id)
       ORDER BY r.created_at DESC, r.id DESC
       LIMIT v_size OFFSET ((v_page - 1)::bigint * v_size)
    ) scoped;
  RETURN jsonb_build_object('page', v_page, 'page_size', v_size,
    'total_count', v_count, 'page_count',
    CASE WHEN v_count = 0 THEN 0 ELSE ceil(v_count::numeric / v_size)::integer END,
    'items', v_items);
END;
$$;
ALTER FUNCTION public.forecast_saved_result_page_v1(uuid,uuid,text,integer,integer,uuid)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_saved_result_page_v1(uuid,uuid,text,integer,integer,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_saved_result_page_v1(uuid,uuid,text,integer,integer,uuid)
  TO service_role;
