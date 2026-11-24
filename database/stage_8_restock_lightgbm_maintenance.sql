-- REVIEW ONLY. Install separately before enabling --restock-lightgbm.
-- Adds a LightGBM coverage read; leaves the 03:00 Blend RPC and all jobs intact.
BEGIN;
SET LOCAL lock_timeout = '10s';

DO $$
DECLARE installed text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.locations
    WHERE id = '11111111-1111-1111-1111-111111111111'::uuid
      AND store_key = 'BINAN-001' AND location_name = 'SPRJ Paint Center'
  ) THEN
    RAISE EXCEPTION 'Authorized BINAN-001 maintenance store identity is unavailable';
  END IF;
  IF to_regprocedure('public.forecast_maintenance_lightgbm_page_v1(uuid,date,text,text,uuid,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'LightGBM maintenance page already exists; review the installed definition';
  END IF;
  IF to_regprocedure('private.forecast_maintenance_scope_v1(uuid)') IS NULL
     OR to_regprocedure('public.forecast_maintenance_page_v1(uuid,date,text,text,uuid,integer)') IS NULL
     OR to_regprocedure('public.forecast_enqueue_jobs_v1(uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Forecast maintenance dependencies are unavailable';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.forecast_enqueue_jobs_v1(uuid,jsonb)')) INTO installed;
  IF position('lightgbm' IN installed) = 0 THEN
    RAISE EXCEPTION 'Installed enqueue RPC does not allow LightGBM';
  END IF;
  PERFORM private.forecast_maintenance_scope_v1('11111111-1111-1111-1111-111111111111'::uuid);
END $$;

CREATE FUNCTION public.forecast_maintenance_lightgbm_page_v1(
    p_location_id uuid, p_business_date date, p_config_digest text,
    p_implementation_digest text, p_after uuid DEFAULT NULL, p_limit integer DEFAULT 10
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $function$
DECLARE v_result jsonb;
BEGIN
  PERFORM private.forecast_maintenance_scope_v1(p_location_id);
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 25
     OR p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date
     OR p_config_digest IS NULL OR p_config_digest !~ '^[0-9a-f]{64}$'
     OR p_implementation_digest IS NULL OR p_implementation_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid LightGBM maintenance page' USING ERRCODE='22023';
  END IF;
  WITH scoped AS MATERIALIZED (
    SELECT p.id, p.location_id, p.product_name, p.sku, p.unit, p.created_at,
           coalesce(r.sales_revision,0) sales_revision,
           coalesce(r.product_revision,0) product_revision,
           CASE WHEN nullif(btrim(p.unit),'') IS NULL THEN 'excluded'
                WHEN j.id IS NULL THEN CASE WHEN EXISTS (
                  SELECT 1 FROM private.forecast_jobs old
                  WHERE old.location_id=p.location_id AND old.product_id=p.id
                    AND old.requested_model_key='lightgbm'
                ) THEN 'stale' ELSE 'missing' END
                WHEN j.status='succeeded' THEN 'current'
                WHEN j.status='queued' AND j.attempt_count>0 THEN 'retry_pending'
                ELSE j.status END state,
           j.safe_error_code
    FROM public.products p
    LEFT JOIN private.forecast_input_revisions r
      ON r.location_id=p.location_id AND r.product_id=p.id
    LEFT JOIN LATERAL (
      SELECT q.* FROM private.forecast_jobs q
      WHERE q.location_id=p.location_id AND q.product_id=p.id
        AND q.requested_model_key='lightgbm' AND q.requested_model_version='1'
        AND q.requested_model_config_digest=p_config_digest
        AND q.requested_implementation_digest=p_implementation_digest
        AND q.horizon_days=28 AND q.history_window_days=365
        AND q.as_of_business_date=p_business_date
        AND q.sales_revision=coalesce(r.sales_revision,0)
        AND q.product_revision=coalesce(r.product_revision,0)
      ORDER BY q.created_at DESC,q.id DESC LIMIT 1
    ) j ON true
    WHERE p.location_id=p_location_id AND p.is_active IS TRUE
  ), page AS (
    SELECT * FROM scoped WHERE p_after IS NULL OR id>p_after
    ORDER BY id LIMIT p_limit
  ), counts AS (
    SELECT state,count(*) n FROM scoped GROUP BY state
  )
  SELECT jsonb_build_object(
    'items',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY id) FROM page),'[]'::jsonb),
    'coverage',coalesce((SELECT jsonb_object_agg(state,n) FROM counts),'{}'::jsonb),
    'revision_fingerprint',(SELECT md5(coalesce(string_agg(
      id::text||':'||sales_revision::text||':'||product_revision::text,
      ',' ORDER BY id),'')) FROM scoped),
    'active_products',(SELECT count(*) FROM scoped)
  ) INTO v_result;
  RETURN v_result;
END $function$;

ALTER FUNCTION public.forecast_maintenance_lightgbm_page_v1(uuid,date,text,text,uuid,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_maintenance_lightgbm_page_v1(uuid,date,text,text,uuid,integer)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.forecast_maintenance_lightgbm_page_v1(uuid,date,text,text,uuid,integer)
  TO service_role;
COMMIT;
