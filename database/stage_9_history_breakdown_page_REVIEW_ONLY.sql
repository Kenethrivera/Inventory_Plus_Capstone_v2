-- REVIEW ONLY. Install separately after confirming the installed Stage 7B RPC.
-- Read-only, service-role-only product drilldown using the Stage 7B classification.
BEGIN;
SET LOCAL lock_timeout = '10s';
DO $$ BEGIN
  IF to_regprocedure('public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Stage 7B history coverage must be installed first';
  END IF;
  IF to_regprocedure('public.forecast_history_breakdown_page_v1(uuid,text,text,text,text,uuid,text,integer,integer,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'History breakdown already exists; review its installed definition';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.locations WHERE id='11111111-1111-1111-1111-111111111111'::uuid
    AND store_key='BINAN-001' AND location_name='SPRJ Paint Center') THEN
    RAISE EXCEPTION 'BINAN-001 store identity mismatch';
  END IF;
END $$;

CREATE FUNCTION public.forecast_history_breakdown_page_v1(
  p_location_id uuid, p_model_key text DEFAULT 'blend',
  p_unit text DEFAULT NULL, p_search text DEFAULT NULL,
  p_category text DEFAULT NULL, p_product_id uuid DEFAULT NULL,
  p_state text DEFAULT 'no_sales', p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25, p_scope_search text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE
  v_result jsonb;
  v_end timestamptz := ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date::timestamp AT TIME ZONE 'Asia/Manila');
  v_start timestamptz;
BEGIN
  IF p_location_id IS NULL OR p_model_key IS NULL OR
     p_model_key NOT IN ('mean28','lightgbm','blend','seasonal_experimental') OR
     p_state IS NULL OR p_state NOT IN ('no_sales','limited','sufficient','not_evaluated') OR
     p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 OR
     p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 50 OR
     length(p_unit)>50 OR length(p_search)>120 OR
     length(p_scope_search)>120 OR length(p_category)>120 THEN
    RAISE EXCEPTION 'Invalid history breakdown scope' USING ERRCODE='22023';
  END IF;
  v_start := (((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date -
    CASE WHEN p_model_key='seasonal_experimental' THEN 1095 ELSE 365 END)::timestamp AT TIME ZONE 'Asia/Manila');
  WITH filtered AS MATERIALIZED (
    SELECT p.id,p.location_id,p.product_name,p.sku,p.unit,p.category
    FROM public.products p WHERE p.location_id=p_location_id AND p.is_active IS TRUE
      AND (p_product_id IS NULL OR p.id=p_product_id)
      AND (p_category IS NULL OR coalesce(nullif(btrim(p.category),''),'Uncategorized')=p_category)
      AND (p_unit IS NULL OR lower(btrim(p.unit))=lower(btrim(p_unit)))
      AND (p_scope_search IS NULL OR btrim(p_scope_search)='' OR
           p.product_name ILIKE ('%'||btrim(p_scope_search)||'%') OR
           p.sku ILIKE ('%'||btrim(p_scope_search)||'%'))
      AND (p_search IS NULL OR btrim(p_search)='' OR
           p.product_name ILIKE ('%'||btrim(p_search)||'%') OR
           p.sku ILIKE ('%'||btrim(p_search)||'%'))
  ), enriched AS (
    SELECT p.*,
      r.id AS result_id,r.as_of_business_date,r.history_window_days,r.inventory_unit,
      r.requested_model_version,r.requested_model_config_digest,
      r.requested_implementation_digest,r.request_input_digest,r.output_bundle,
      r.sales_revision AS result_sales_revision,r.product_revision AS result_product_revision,
      rev.sales_revision AS current_sales_revision,rev.product_revision AS current_product_revision,
      j.id AS latest_job_id,j.status AS latest_job_status,
      j.safe_error_code AS latest_job_safe_error_code,
      j.requested_model_version AS latest_job_model_version,
      j.requested_model_config_digest AS latest_job_config_digest,
      j.requested_implementation_digest AS latest_job_implementation_digest,
      j.request_input_digest AS latest_job_input_digest,
      j.sales_revision AS latest_job_sales_revision,j.product_revision AS latest_job_product_revision
    FROM filtered p
    LEFT JOIN LATERAL (
      SELECT er.* FROM private.forecast_execution_results er
      WHERE er.location_id=p_location_id AND er.product_id=p.id
        AND er.requested_model_key=p_model_key AND er.horizon_days=28
      ORDER BY er.as_of_business_date DESC,er.created_at DESC,er.id DESC LIMIT 1
    ) r ON true
    LEFT JOIN private.forecast_input_revisions rev ON rev.location_id=p_location_id AND rev.product_id=p.id
    LEFT JOIN LATERAL (
      SELECT fj.* FROM private.forecast_jobs fj
      WHERE fj.location_id=p_location_id AND fj.product_id=p.id
        AND fj.requested_model_key=p_model_key AND fj.horizon_days=28
      ORDER BY fj.created_at DESC,fj.id DESC LIMIT 1
    ) j ON true
  ), order_candidates AS MATERIALIZED (
    SELECT h.order_id,h.items,h.completed_at FROM public.order_history h
    WHERE h.location_id=p_location_id AND lower(btrim(h.status))='completed'
      AND EXISTS (SELECT 1 FROM filtered) AND h.returned_at IS NULL
      AND h.completed_at>=v_start AND h.completed_at<v_end
      AND coalesce(h.completed_at,h.prepared_at,h.created_at)>=v_start
      AND coalesce(h.completed_at,h.prepared_at,h.created_at)<v_end
    ORDER BY h.completed_at DESC,h.order_id LIMIT 5001
  ), bounded_orders AS MATERIALIZED (
    SELECT * FROM order_candidates ORDER BY completed_at DESC,order_id LIMIT 5000
  ), sales_lines AS MATERIALIZED (
    SELECT (jsonb_typeof(i.value->'unit') IS NULL OR
            jsonb_typeof(i.value->'unit') IN ('string','null')) AS unit_valid,
      coalesce(i.value->>'product_id',i.value->>'productId') AS product_text,
      i.value->>'quantity' AS quantity_text,
      coalesce(nullif(btrim(i.value->>'unit'),''),'pcs') AS unit
    FROM bounded_orders h CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(h.items)='array' THEN
        CASE WHEN jsonb_array_length(h.items)<=100 THEN h.items ELSE '[]'::jsonb END
      ELSE '[]'::jsonb END) i(value)
  ), checked_lines AS MATERIALIZED (
    SELECT unit_valid,
      CASE WHEN pg_input_is_valid(product_text,'uuid') THEN product_text::uuid END AS product_id,
      unit,
      CASE WHEN length(quantity_text)<=64 AND quantity_text ~ '^[0-9]+([.][0-9]+)?$'
           THEN quantity_text::numeric>0 ELSE false END AS quantity_valid
    FROM sales_lines
  ), quality AS (
    SELECT (SELECT count(*)<=5000 FROM order_candidates)
      AND NOT EXISTS(SELECT 1 FROM bounded_orders h WHERE CASE WHEN jsonb_typeof(h.items)='array'
        THEN jsonb_array_length(h.items) NOT BETWEEN 1 AND 100 ELSE true END)
      AND NOT EXISTS(SELECT 1 FROM checked_lines WHERE product_id IS NULL OR quantity_valid IS NOT TRUE OR unit_valid IS NOT TRUE)
      AND NOT EXISTS(SELECT 1 FROM public.order_history h
        WHERE h.location_id=p_location_id AND lower(btrim(h.status))='completed'
          AND h.returned_at IS NULL AND h.completed_at IS NULL) AS complete
  ), positive_sales AS (
    SELECT DISTINCT c.product_id FROM checked_lines c
    WHERE c.product_id IS NOT NULL AND c.quantity_valid
  ), evidence AS (
    SELECT e.*,q.complete,ps.product_id IS NOT NULL AS has_sales,
      ((e.result_id IS NOT NULL AND e.requested_model_version='1'
        AND e.history_window_days=CASE WHEN p_model_key='seasonal_experimental' THEN 1095 ELSE 365 END
        AND e.result_sales_revision=e.current_sales_revision
        AND e.result_product_revision=e.current_product_revision
        AND lower(btrim(e.inventory_unit))=lower(btrim(e.unit))
        AND e.as_of_business_date=(now() AT TIME ZONE 'Asia/Manila')::date
        AND (e.latest_job_id IS NULL OR
          (e.latest_job_model_version=e.requested_model_version
           AND e.latest_job_config_digest=e.requested_model_config_digest
           AND e.latest_job_implementation_digest=e.requested_implementation_digest
           AND e.latest_job_input_digest=e.request_input_digest
           AND e.latest_job_sales_revision=e.result_sales_revision
           AND e.latest_job_product_revision=e.result_product_revision))) IS TRUE
        AND e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,data_provenance}' IS NOT DISTINCT FROM 'real') AS eligible
    FROM enriched e CROSS JOIN quality q
    LEFT JOIN positive_sales ps ON ps.product_id=e.id
  ), classified AS (
    SELECT e.id,e.product_name,e.sku,e.unit,
      CASE WHEN NOT e.complete THEN 'not_evaluated'
        WHEN NOT e.has_sales THEN 'no_sales'
        WHEN NOT e.eligible THEN 'not_evaluated'
        WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}'='insufficient_history'
          OR e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IN
            ('insufficient_training_history','insufficient_uncensored_training_rows',
             'blend_unavailable:insufficient_training_history',
             'blend_unavailable:insufficient_uncensored_training_rows') THEN 'limited'
        WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,is_cold_start}'='false'
          AND e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}' IS NULL
          AND e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IS NULL THEN 'sufficient'
        ELSE 'not_evaluated' END AS state,
      CASE WHEN NOT e.complete THEN 'sales_evidence_incomplete'
        WHEN NOT e.has_sales THEN 'no_recorded_sales'
        WHEN NOT e.eligible AND e.latest_job_status='failed'
          AND e.latest_job_safe_error_code ~ '^[a-z0-9_:-]{1,80}$'
          THEN 'latest_job_failed:'||e.latest_job_safe_error_code
        WHEN NOT e.eligible THEN 'current_model_evidence_unavailable'
        WHEN e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IN
            ('insufficient_uncensored_training_rows',
             'blend_unavailable:insufficient_uncensored_training_rows')
          THEN 'limited_uncensored_training_rows'
        WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}'='insufficient_history'
          OR e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IN
            ('insufficient_training_history','insufficient_uncensored_training_rows',
             'blend_unavailable:insufficient_training_history',
             'blend_unavailable:insufficient_uncensored_training_rows') THEN 'limited_model_history'
        WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,is_cold_start}'='false'
          AND e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}' IS NULL
          AND e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IS NULL THEN 'sufficient_model_history'
        ELSE 'model_eligibility_unresolved' END AS reason_code
    FROM evidence e
  ), matching AS MATERIALIZED (
    SELECT * FROM classified WHERE state=p_state
  ), page_rows AS (
    SELECT * FROM matching ORDER BY lower(product_name),id
    LIMIT p_page_size OFFSET (p_page-1)*p_page_size
  )
  SELECT jsonb_build_object(
    'available',true,'source','completed_sales_and_saved_model_eligibility',
    'business_date',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date,
    'state',p_state,'page',p_page,'page_size',p_page_size,
    'total_count',(SELECT count(*) FROM matching),
    'page_count',(SELECT ceil(count(*)::numeric/p_page_size)::integer FROM matching),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'product_id',id,'product_name',product_name,'sku',sku,'unit',unit,
      'state',state,'reason_code',reason_code,
      'reason',CASE
        WHEN reason_code='sales_evidence_incomplete' THEN 'Completed-sales records could not be verified for this scope.'
        WHEN reason_code='no_recorded_sales' THEN 'No completed sales were recorded in the historical window; demand remains unknown.'
        WHEN reason_code LIKE 'latest_job_failed:%' THEN
          'Current saved model evidence is unavailable. Latest job failed ('||split_part(reason_code,':',2)||').'
        WHEN reason_code='current_model_evidence_unavailable' THEN 'Current saved model evidence is unavailable or not verified as real data.'
        WHEN reason_code='limited_uncensored_training_rows' THEN 'There are too few usable uncensored sales rows for a fully supported model forecast.'
        WHEN reason_code='limited_model_history' THEN 'Sales history is insufficient for a fully supported model forecast.'
        WHEN reason_code='sufficient_model_history' THEN 'Completed sales and current saved model evidence support this classification.'
        ELSE 'Historical model eligibility could not be established.' END
      ) ORDER BY lower(product_name),id)
      FROM page_rows),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
END;
$fn$;
ALTER FUNCTION public.forecast_history_breakdown_page_v1(uuid,text,text,text,text,uuid,text,integer,integer,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_history_breakdown_page_v1(uuid,text,text,text,text,uuid,text,integer,integer,text)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.forecast_history_breakdown_page_v1(uuid,text,text,text,text,uuid,text,integer,integer,text)
  TO service_role;
COMMIT;
