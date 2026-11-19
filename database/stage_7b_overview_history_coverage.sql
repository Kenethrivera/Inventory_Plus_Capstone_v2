-- REVIEW ONLY. No V1 RPC is altered or overloaded.
-- Live PostgreSQL 17.6 V1 contract verified 2026-11-18 (project pzotcznujkuzymndluwl): forecast_snapshot_page_v1(uuid,uuid,text,integer,
-- integer,text,text,boolean). V1 is preserved without changes.
-- Two distinct V2 names prevent PostgREST optional-argument overload ambiguity.
-- Completed-sales evidence covers the selected model's frozen historical window,
-- never a claim of lifetime zero sales or of today's intraday activity.
BEGIN;
SET LOCAL lock_timeout = '5s';

-- Fail closed on name/signature drift rather than creating optional-argument
-- overloads. This block runs only if the migration is later approved/applied.
DO $guard$
BEGIN
 IF to_regprocedure('public.forecast_snapshot_page_v1(uuid,uuid,text,integer,integer,text,text,boolean)') IS NULL THEN
  RAISE EXCEPTION 'Expected V1 snapshot signature is missing';
 END IF;
 -- Live baseline: fail if V1 changes between this preflight and installation.
 IF md5(pg_get_functiondef('public.forecast_snapshot_page_v1(uuid,uuid,text,integer,integer,text,text,boolean)'::regprocedure))
    IS DISTINCT FROM '043bac224858bec4faea7561196e3bc6' THEN
  RAISE EXCEPTION 'V1 snapshot definition changed after Stage 7B live preflight';
 END IF;
 IF EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND (
   (p.proname='forecast_snapshot_page_v2' AND p.oid IS DISTINCT FROM
    to_regprocedure('public.forecast_snapshot_page_v2(uuid,uuid,text,integer,integer,text,text,boolean,text,uuid)')::oid)
   OR (p.proname='forecast_history_coverage_v2' AND p.oid IS DISTINCT FROM
    to_regprocedure('public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid)')::oid)
  )
 ) THEN RAISE EXCEPTION 'Conflicting V2 RPC signature; inspect before installation';
 END IF;
END;
$guard$;

CREATE OR REPLACE FUNCTION public.forecast_history_coverage_v2(
 p_location_id uuid, p_model_key text DEFAULT 'blend',
 p_unit text DEFAULT NULL, p_search text DEFAULT NULL,
 p_category text DEFAULT NULL, p_product_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE v_result jsonb;
 v_end timestamptz := ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date::timestamp AT TIME ZONE 'Asia/Manila');
 v_start timestamptz;
BEGIN
 IF p_location_id IS NULL OR p_model_key IS NULL OR
    p_model_key NOT IN ('mean28','lightgbm','blend','seasonal_experimental')
    OR length(p_unit)>50 OR length(p_search)>120 OR length(p_category)>120 THEN
  RAISE EXCEPTION 'Invalid coverage scope' USING ERRCODE='22023';
 END IF;
 v_start := (((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date -
   CASE WHEN p_model_key='seasonal_experimental' THEN 1095 ELSE 365 END)::timestamp AT TIME ZONE 'Asia/Manila');
    WITH filtered AS MATERIALIZED (
        SELECT p.id, p.location_id, p.product_name, p.sku, p.unit,
               p.category, p.product_quantity, p.is_active
          FROM public.products p
         WHERE p.location_id = p_location_id
           AND p.is_active IS TRUE
           AND (p_product_id IS NULL OR p.id=p_product_id)
           AND (p_category IS NULL OR coalesce(nullif(btrim(p.category),''),'Uncategorized')=p_category)
           AND (p_unit IS NULL OR lower(btrim(p.unit)) = lower(btrim(p_unit)))
           AND (p_search IS NULL OR btrim(p_search) = ''
                OR p.product_name ILIKE ('%' || btrim(p_search) || '%')
                OR p.sku ILIKE ('%' || btrim(p_search) || '%'))
    ),
    total AS (
        SELECT count(*)::integer AS total_count FROM filtered
    ),
    page_rows AS (
        SELECT f.*
          FROM filtered f
    ),
    enriched AS (
        SELECT p.*,
               r.id AS result_id,
               r.created_at AS result_created_at,
               r.forecast_start_date,
               r.forecast_end_date,
               r.as_of_business_date,
               r.as_of_at,
               r.horizon_days,
               r.history_window_days,
               r.inventory_unit,
               r.requested_model_key,
               r.requested_model_version,
               r.requested_model_config_digest,
               r.requested_implementation_digest,
               r.request_input_digest,
               r.source_data_as_of,
               r.sales_revision AS result_sales_revision,
               r.product_revision AS result_product_revision,
               r.output_bundle,
               rev.sales_revision AS current_sales_revision,
               rev.product_revision AS current_product_revision,
               j.status AS latest_job_status,
               j.id AS latest_job_id,
               j.safe_error_code,
               j.requested_model_version AS latest_job_model_version,
               j.requested_model_config_digest AS latest_job_config_digest,
               j.requested_implementation_digest AS latest_job_implementation_digest,
               j.request_input_digest AS latest_job_input_digest,
               j.sales_revision AS latest_job_sales_revision,
               j.product_revision AS latest_job_product_revision
          FROM page_rows p
          LEFT JOIN LATERAL (
              SELECT er.*
                FROM private.forecast_execution_results er
               WHERE er.location_id = p_location_id
                 AND er.product_id = p.id
                 AND er.requested_model_key = p_model_key
                 AND er.horizon_days = 28
               ORDER BY er.as_of_business_date DESC, er.created_at DESC, er.id DESC
               LIMIT 1
          ) r ON true
          LEFT JOIN private.forecast_input_revisions rev
            ON rev.location_id = p_location_id AND rev.product_id = p.id
          LEFT JOIN LATERAL (
              SELECT fj.id, fj.status, fj.safe_error_code,
                     fj.requested_model_version,
                     fj.requested_model_config_digest,
                     fj.requested_implementation_digest,
                     fj.request_input_digest,
                     fj.sales_revision,
                     fj.product_revision
                FROM private.forecast_jobs fj
               WHERE fj.location_id = p_location_id
                 AND fj.product_id = p.id
                 AND fj.requested_model_key = p_model_key
                 AND fj.horizon_days = 28
               ORDER BY fj.created_at DESC, fj.id DESC
               LIMIT 1
          ) j ON true
    ), order_candidates AS MATERIALIZED (
 SELECT h.order_id,h.items,h.completed_at
 FROM public.order_history h
 WHERE h.location_id=p_location_id AND lower(btrim(h.status))='completed'
   AND EXISTS (SELECT 1 FROM filtered)
   AND h.returned_at IS NULL
   AND h.completed_at>=v_start AND h.completed_at<v_end
   -- Redundant for nonnull completed_at; matches the deployed event-time index.
   AND coalesce(h.completed_at,h.prepared_at,h.created_at)>=v_start
   AND coalesce(h.completed_at,h.prepared_at,h.created_at)<v_end
 ORDER BY h.completed_at DESC,h.order_id
 LIMIT 5001
), bounded_orders AS MATERIALIZED (
 SELECT * FROM order_candidates ORDER BY completed_at DESC,order_id LIMIT 5000
), sales_lines AS MATERIALIZED (
 SELECT (jsonb_typeof(i.value->'unit') IS NULL OR jsonb_typeof(i.value->'unit') IN ('string','null')) AS unit_valid,
        coalesce(i.value->>'product_id',i.value->>'productId') AS product_text,
        i.value->>'quantity' AS quantity_text,
        coalesce(nullif(btrim(i.value->>'unit'),''),'pcs') AS unit
 FROM bounded_orders h
 CROSS JOIN LATERAL jsonb_array_elements(
   CASE WHEN jsonb_typeof(h.items)='array' THEN
     CASE WHEN jsonb_array_length(h.items)<=100 THEN h.items ELSE '[]'::jsonb END
   ELSE '[]'::jsonb END) i(value)
), checked_lines AS MATERIALIZED (
 SELECT unit_valid, CASE WHEN pg_input_is_valid(product_text,'uuid') THEN product_text::uuid END AS product_id,
        unit,
        CASE WHEN length(quantity_text)<=64 AND quantity_text ~ '^[0-9]+([.][0-9]+)?$'
             THEN quantity_text::numeric>0 ELSE false END AS quantity_valid
 FROM sales_lines
), quality AS (
 SELECT (SELECT count(*)<=5000 FROM order_candidates)
   AND NOT EXISTS(SELECT 1 FROM bounded_orders h
     WHERE CASE WHEN jsonb_typeof(h.items)='array'
       THEN jsonb_array_length(h.items) NOT BETWEEN 1 AND 100 ELSE true END)
   AND NOT EXISTS(SELECT 1 FROM checked_lines WHERE product_id IS NULL OR quantity_valid IS NOT TRUE OR unit_valid IS NOT TRUE)
   AND NOT EXISTS(SELECT 1 FROM public.order_history h
      WHERE h.location_id=p_location_id AND lower(btrim(h.status))='completed'
        AND h.returned_at IS NULL AND h.completed_at IS NULL) AS complete
), positive_sales AS (
 SELECT DISTINCT c.product_id
 FROM checked_lines c WHERE c.product_id IS NOT NULL AND c.quantity_valid
), classified AS (
 SELECT CASE
   -- Only a complete authoritative scan establishes absence of completed sales.
   WHEN NOT q.complete THEN 'not_evaluated'
   WHEN ps.product_id IS NULL THEN 'no_sales'
   -- Positive sales do not establish eligibility; use current model metadata.
   WHEN (e.result_id IS NOT NULL AND
                             e.requested_model_version = '1' AND
                             e.history_window_days = CASE WHEN p_model_key='seasonal_experimental' THEN 1095 ELSE 365 END AND
                             e.result_sales_revision = e.current_sales_revision AND
                             e.result_product_revision = e.current_product_revision AND
                             lower(btrim(e.inventory_unit)) = lower(btrim(e.unit)) AND
                             e.as_of_business_date =
                               (now() AT TIME ZONE 'Asia/Manila')::date AND
                             (e.latest_job_id IS NULL OR
                              (e.latest_job_model_version = e.requested_model_version AND
                               e.latest_job_config_digest = e.requested_model_config_digest AND
                               e.latest_job_implementation_digest = e.requested_implementation_digest AND
                               e.latest_job_input_digest = e.request_input_digest AND
                               e.latest_job_sales_revision = e.result_sales_revision AND
                               e.latest_job_product_revision = e.result_product_revision))) IS NOT TRUE OR
     e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,data_provenance}' IS DISTINCT FROM 'real'
     THEN 'not_evaluated'
   WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}'='insufficient_history'
    OR e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IN
      ('insufficient_training_history','insufficient_uncensored_training_rows',
       'blend_unavailable:insufficient_training_history',
       'blend_unavailable:insufficient_uncensored_training_rows') THEN 'limited'
   WHEN e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,is_cold_start}'='false'
    AND e.output_bundle #>> '{outputs,requested_forecasts,series,0,points,0,metadata,cold_start_reason}' IS NULL
    AND e.output_bundle #>> '{outputs,requested_forecasts,fallback_reason}' IS NULL THEN 'sufficient'
   ELSE 'not_evaluated' END AS state
 FROM enriched e CROSS JOIN quality q
 LEFT JOIN positive_sales ps ON ps.product_id=e.id
)
SELECT jsonb_build_object('available',true,'source','completed_sales_and_saved_model_eligibility',
 'business_date',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::date,
 'history_start',v_start,'history_end_exclusive',v_end,
 'sales_evidence_complete',(SELECT complete FROM quality),
 'orders_scanned',(SELECT count(*) FROM bounded_orders),
 'order_limit',5000,'item_limit_per_order',100,
 'total',count(*),'no_sales',count(*) FILTER(WHERE state='no_sales'),
 'limited',count(*) FILTER(WHERE state='limited'),
 'sufficient',count(*) FILTER(WHERE state='sufficient'),
 'not_evaluated',count(*) FILTER(WHERE state='not_evaluated')) INTO v_result FROM classified;
 RETURN v_result;
END;
$fn$;
ALTER FUNCTION public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.forecast_snapshot_page_v2(
    p_location_id uuid,
    p_product_id uuid DEFAULT NULL,
    p_model_key text DEFAULT 'blend',
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 25,
    p_unit text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_include_bundle boolean DEFAULT false,
    p_scope_category text DEFAULT NULL,
    p_scope_product_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_result jsonb;
BEGIN
    IF p_location_id IS NULL
       OR p_model_key IS NULL
       OR p_model_key NOT IN ('mean28', 'lightgbm', 'blend', 'seasonal_experimental')
       OR length(p_unit)>50 OR length(p_search)>120 OR length(p_scope_category)>120
       OR p_page IS NULL OR p_page < 1 OR p_page > 10000
       OR p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 50
       OR (p_include_bundle IS TRUE AND p_product_id IS NULL) THEN
        RAISE EXCEPTION 'Forecast snapshot query is invalid' USING ERRCODE = '22023';
    END IF;

    IF p_product_id IS NOT NULL THEN
        p_page := 1;
        p_page_size := 1;
    END IF;

    WITH filtered AS MATERIALIZED (
        SELECT p.id, p.location_id, p.product_name, p.sku, p.unit,
               p.category, p.product_quantity, p.is_active
          FROM public.products p
         WHERE p.location_id = p_location_id
           AND p.is_active IS TRUE
           AND (p_scope_product_id IS NULL OR p.id=p_scope_product_id)
           AND (p_scope_category IS NULL OR coalesce(nullif(btrim(p.category),''),'Uncategorized')=p_scope_category)
           AND (p_product_id IS NULL OR p.id = p_product_id)
           AND (p_unit IS NULL OR lower(btrim(p.unit)) = lower(btrim(p_unit)))
           AND (p_search IS NULL OR btrim(p_search) = ''
                OR p.product_name ILIKE ('%' || btrim(p_search) || '%')
                OR p.sku ILIKE ('%' || btrim(p_search) || '%'))
    ),
    total AS (
        SELECT count(*)::integer AS total_count FROM filtered
    ),
    page_rows AS (
        SELECT f.*
          FROM filtered f
         ORDER BY lower(f.product_name), f.id
         OFFSET ((p_page - 1) * p_page_size)
         LIMIT p_page_size
    ),
    enriched AS (
        SELECT p.*,
               r.id AS result_id,
               r.created_at AS result_created_at,
               r.forecast_start_date,
               r.forecast_end_date,
               r.as_of_business_date,
               r.as_of_at,
               r.horizon_days,
               r.history_window_days,
               r.inventory_unit,
               r.requested_model_key,
               r.requested_model_version,
               r.requested_model_config_digest,
               r.requested_implementation_digest,
               r.request_input_digest,
               r.source_data_as_of,
               r.sales_revision AS result_sales_revision,
               r.product_revision AS result_product_revision,
               r.output_bundle,
               rev.sales_revision AS current_sales_revision,
               rev.product_revision AS current_product_revision,
               j.status AS latest_job_status,
               j.id AS latest_job_id,
               j.safe_error_code,
               j.requested_model_version AS latest_job_model_version,
               j.requested_model_config_digest AS latest_job_config_digest,
               j.requested_implementation_digest AS latest_job_implementation_digest,
               j.request_input_digest AS latest_job_input_digest,
               j.sales_revision AS latest_job_sales_revision,
               j.product_revision AS latest_job_product_revision,
               rs.id AS saved_recommendation_id,
               rs.created_at AS saved_recommendation_created_at,
               rs.forecast_model AS saved_recommendation_model,
               rs.predicted_demand AS saved_recommendation_demand,
               rs.recommended_restock_quantity AS saved_restock_quantity,
               rs.inventory_unit_snapshot AS saved_recommendation_unit
          FROM page_rows p
          LEFT JOIN LATERAL (
              SELECT er.*
                FROM private.forecast_execution_results er
               WHERE er.location_id = p_location_id
                 AND er.product_id = p.id
                 AND er.requested_model_key = p_model_key
                 AND er.horizon_days = 28
               ORDER BY er.as_of_business_date DESC, er.created_at DESC, er.id DESC
               LIMIT 1
          ) r ON true
          LEFT JOIN private.forecast_input_revisions rev
            ON rev.location_id = p_location_id AND rev.product_id = p.id
          LEFT JOIN LATERAL (
              SELECT fj.id, fj.status, fj.safe_error_code,
                     fj.requested_model_version,
                     fj.requested_model_config_digest,
                     fj.requested_implementation_digest,
                     fj.request_input_digest,
                     fj.sales_revision,
                     fj.product_revision
                FROM private.forecast_jobs fj
               WHERE fj.location_id = p_location_id
                 AND fj.product_id = p.id
                 AND fj.requested_model_key = p_model_key
                 AND fj.horizon_days = 28
               ORDER BY fj.created_at DESC, fj.id DESC
               LIMIT 1
          ) j ON true
          LEFT JOIN LATERAL (
              SELECT s.id, s.created_at, s.forecast_model, s.predicted_demand,
                     s.recommended_restock_quantity, s.inventory_unit_snapshot
                FROM public.forecast_recommendation_snapshots s
               WHERE s.location_id_snapshot = p_location_id
                 AND s.product_id_snapshot = p.id
               ORDER BY s.created_at DESC, s.id DESC
               LIMIT 1
          ) rs ON true
    )
    SELECT jsonb_build_object(
        'page', p_page,
        'page_size', p_page_size,
        'total_count', total.total_count,
        'page_count', CASE WHEN total.total_count = 0 THEN 0
                           ELSE ceil(total.total_count::numeric / p_page_size)::integer END,
        'items', COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'product', jsonb_build_object(
                        'product_id', e.id,
                        'location_id', e.location_id,
                        'name', e.product_name,
                        'sku', e.sku,
                        'unit', e.unit,
                        'category', e.category,
                        'on_hand', e.product_quantity
                    ),
                    'status', CASE
                        WHEN e.result_id IS NOT NULL AND
                             e.requested_model_version = '1' AND
                             e.history_window_days = CASE WHEN p_model_key='seasonal_experimental' THEN 1095 ELSE 365 END AND
                             e.result_sales_revision = e.current_sales_revision AND
                             e.result_product_revision = e.current_product_revision AND
                             lower(btrim(e.inventory_unit)) = lower(btrim(e.unit)) AND
                             e.as_of_business_date =
                               (now() AT TIME ZONE 'Asia/Manila')::date AND
                             (e.latest_job_id IS NULL OR
                              (e.latest_job_model_version = e.requested_model_version AND
                               e.latest_job_config_digest = e.requested_model_config_digest AND
                               e.latest_job_implementation_digest = e.requested_implementation_digest AND
                               e.latest_job_input_digest = e.request_input_digest AND
                               e.latest_job_sales_revision = e.result_sales_revision AND
                               e.latest_job_product_revision = e.result_product_revision))
                            THEN 'completed'
                        WHEN e.result_id IS NOT NULL THEN 'stale'
                        WHEN e.latest_job_status IN ('queued', 'running', 'failed', 'superseded', 'cancelled')
                            THEN e.latest_job_status
                        ELSE 'no_forecast'
                    END,
                    'job', jsonb_build_object(
                        'job_id', e.latest_job_id,
                        'status', e.latest_job_status,
                        'safe_error_code', e.safe_error_code
                    ),
                    'last_saved_recommendation', CASE
                        WHEN e.saved_recommendation_id IS NULL THEN NULL
                        ELSE jsonb_build_object(
                            'recommendation_id', e.saved_recommendation_id,
                            'saved_at', e.saved_recommendation_created_at,
                            'model', e.saved_recommendation_model,
                            'predicted_demand', e.saved_recommendation_demand,
                            'suggested_restock', e.saved_restock_quantity,
                            'unit', e.saved_recommendation_unit
                        ) END,
                    'snapshot', CASE WHEN e.result_id IS NULL THEN NULL ELSE
                        jsonb_build_object(
                            'result_id', e.result_id,
                            'created_at', e.result_created_at,
                            'forecast_start_date', e.forecast_start_date,
                            'forecast_end_date', e.forecast_end_date,
                            'as_of_business_date', e.as_of_business_date,
                            'as_of_at', e.as_of_at,
                            'horizon_days', e.horizon_days,
                            'history_window_days', e.history_window_days,
                            'inventory_unit', e.inventory_unit,
                            'source_data_as_of', e.source_data_as_of,
                            'requested_model', e.output_bundle #> '{execution,requested_model}',
                            'request_input_digest', e.request_input_digest,
                            'source_revisions', jsonb_build_object(
                                'sales_revision', e.result_sales_revision,
                                'product_revision', e.result_product_revision
                            ),
                            'requested_forecast', jsonb_build_object(
                                'producer', e.output_bundle #> '{outputs,requested_forecasts,series,0,producer}',
                                'fallback_reason', e.output_bundle #> '{outputs,requested_forecasts,fallback_reason}',
                                'points', CASE WHEN p_include_bundle
                                    THEN e.output_bundle #> '{outputs,requested_forecasts,series,0,points}'
                                    ELSE NULL END
                            ),
                            'recommendation_forecast', jsonb_build_object(
                                'producer', e.output_bundle #> '{outputs,recommendation_forecasts,series,0,producer}',
                                'points', CASE WHEN p_include_bundle
                                    THEN e.output_bundle #> '{outputs,recommendation_forecasts,series,0,points}'
                                    ELSE NULL END
                            ),
                            'preliminary_forecast', jsonb_build_object(
                                'producer', e.output_bundle #> '{outputs,preliminary_forecasts,series,0,producer}',
                                'points', CASE WHEN p_include_bundle
                                    THEN e.output_bundle #> '{outputs,preliminary_forecasts,series,0,points}'
                                    ELSE NULL END
                            ),
                            'summary', CASE
                                WHEN p_include_bundle OR
                                     jsonb_typeof(e.output_bundle #> '{outputs,requested_forecasts,series,0,points}') IS DISTINCT FROM 'array'
                                    THEN NULL
                                ELSE (
                                    SELECT jsonb_build_object(
                                        'first_day_demand', SUM((point.value->>'quantity')::numeric)
                                            FILTER (WHERE point.ordinality = 1),
                                        'next_7_day_demand', SUM((point.value->>'quantity')::numeric)
                                            FILTER (WHERE point.ordinality <= 7),
                                        'next_28_day_demand', SUM((point.value->>'quantity')::numeric)
                                            FILTER (WHERE point.ordinality <= 28),
                                        'unit', e.inventory_unit,
                                        'daily', jsonb_agg(
                                            jsonb_build_object(
                                                'date', point.value->>'date',
                                                'quantity', (point.value->>'quantity')::numeric
                                            ) ORDER BY point.ordinality
                                        )
                                    )
                                    FROM jsonb_array_elements(
                                        e.output_bundle #> '{outputs,requested_forecasts,series,0,points}'
                                    ) WITH ORDINALITY AS point(value, ordinality)
                                ) END,
                            'bundle', CASE WHEN p_include_bundle THEN e.output_bundle ELSE NULL END
                        ) END
                ) ORDER BY lower(e.product_name), e.id
            ) FILTER (WHERE e.id IS NOT NULL), '[]'::jsonb
        )
    )
      INTO v_result
      FROM total
      LEFT JOIN enriched e ON true
     GROUP BY total.total_count;

    RETURN v_result;
END;
$function$;

ALTER FUNCTION public.forecast_snapshot_page_v2(
    uuid, uuid, text, integer, integer, text, text, boolean, text, uuid
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_snapshot_page_v2(
    uuid, uuid, text, integer, integer, text, text, boolean, text, uuid
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_snapshot_page_v2(
    uuid, uuid, text, integer, integer, text, text, boolean, text, uuid
) TO service_role;



NOTIFY pgrst,'reload schema';
COMMIT;
