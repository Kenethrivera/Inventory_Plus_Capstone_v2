
-- REVIEW ONLY. Forward patch based on the installed Stage 6 recovery-aware enqueue RPC.
-- Preserves recovery-generation uniqueness, service-role boundary and historical rows.
-- Requires separate SQL approval; no database operation is part of this source edit.
BEGIN;
CREATE OR REPLACE FUNCTION public.forecast_enqueue_jobs_v1(p_location_id uuid, p_jobs jsonb)
 RETURNS TABLE(product_id uuid, job_id uuid, outcome text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_item record;
    v_sales_revision bigint;
    v_product_revision bigint;
    v_inserted_id uuid;
    v_existing_id uuid;
BEGIN
    IF p_location_id IS NULL THEN
        RAISE EXCEPTION 'Location is required';
    END IF;
    IF jsonb_typeof(p_jobs) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Location and a JSON array of jobs are required';
    END IF;
    IF jsonb_array_length(p_jobs) > 1000 THEN
        RAISE EXCEPTION 'Forecast job insertion is limited to 1000 products';
    END IF;

    FOR v_item IN
        SELECT *
          FROM jsonb_to_recordset(p_jobs) AS item(
              product_id uuid,
              requested_model_key text,
              requested_model_version text,
              requested_model_config_digest text,
              requested_implementation_digest text,
              horizon_days integer,
              history_window_days integer,
              as_of_business_date date,
              as_of_at timestamptz,
              sales_revision bigint,
              product_revision bigint,
              request_input_digest text,
              idempotency_key uuid
          )
         ORDER BY item.product_id
    LOOP
        product_id := v_item.product_id;
        job_id := NULL;
        outcome := 'invalid_product';

        IF v_item.product_id IS NULL
           OR v_item.requested_model_key IS NULL
           OR v_item.requested_model_key NOT IN ('mean28','lightgbm','blend','seasonal_experimental')
           OR v_item.requested_model_version IS DISTINCT FROM '1'
           OR v_item.horizon_days IS DISTINCT FROM 28
           OR v_item.history_window_days IS DISTINCT FROM
              (CASE
                  WHEN v_item.requested_model_key = 'seasonal_experimental' THEN 1095
                  ELSE 365
               END)
           OR v_item.as_of_business_date IS NULL
           OR v_item.as_of_at IS DISTINCT FROM
              (v_item.as_of_business_date::timestamp AT TIME ZONE 'Asia/Manila')
           OR v_item.sales_revision IS NULL OR v_item.sales_revision < 0
           OR v_item.product_revision IS NULL OR v_item.product_revision < 0
           OR v_item.idempotency_key IS NULL
           OR v_item.requested_model_config_digest IS NULL
           OR v_item.requested_implementation_digest IS NULL
           OR v_item.request_input_digest IS NULL
           OR v_item.requested_model_config_digest !~ '^[0-9a-f]{64}$'
           OR v_item.requested_implementation_digest !~ '^[0-9a-f]{64}$'
           OR v_item.request_input_digest !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'Forecast job identity is invalid';
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM public.products p
             WHERE p.id = v_item.product_id
               AND p.location_id = p_location_id
               AND p.is_active IS TRUE
        ) THEN
            outcome := 'invalid_product';
            RETURN NEXT;
            CONTINUE;
        END IF;

        SELECT r.sales_revision, r.product_revision
          INTO v_sales_revision, v_product_revision
          FROM private.forecast_input_revisions r
         WHERE r.location_id = p_location_id
           AND r.product_id = v_item.product_id
         FOR UPDATE;
        IF NOT FOUND
           OR v_sales_revision IS DISTINCT FROM v_item.sales_revision
           OR v_product_revision IS DISTINCT FROM v_item.product_revision THEN
            outcome := 'stale_revision';
            RETURN NEXT;
            CONTINUE;
        END IF;

        UPDATE private.forecast_jobs j
           SET status = 'superseded',
               completed_at = clock_timestamp(),
               safe_error_code = 'forecast_inputs_superseded',
               updated_at = clock_timestamp()
         WHERE j.location_id = p_location_id
           AND j.product_id = v_item.product_id
           AND j.requested_model_key = v_item.requested_model_key
           AND j.horizon_days = v_item.horizon_days
           AND j.history_window_days = v_item.history_window_days
           AND j.status = 'queued'
           AND ROW(
                j.requested_model_version,
                j.requested_model_config_digest,
                j.requested_implementation_digest,
                j.as_of_business_date,
                j.sales_revision,
                j.product_revision,
                j.request_input_digest
           ) IS DISTINCT FROM ROW(
                v_item.requested_model_version,
                v_item.requested_model_config_digest,
                v_item.requested_implementation_digest,
                v_item.as_of_business_date,
                v_item.sales_revision,
                v_item.product_revision,
                v_item.request_input_digest
           );

        v_inserted_id := NULL;
        v_existing_id := NULL;
        INSERT INTO private.forecast_jobs (
            idempotency_key, location_id, product_id,
            requested_model_key, requested_model_version,
            requested_model_config_digest, requested_implementation_digest,
            horizon_days, history_window_days, as_of_business_date, as_of_at,
            sales_revision, product_revision, request_input_digest
        ) VALUES (
            v_item.idempotency_key, p_location_id, v_item.product_id,
            v_item.requested_model_key, v_item.requested_model_version,
            v_item.requested_model_config_digest,
            v_item.requested_implementation_digest,
            v_item.horizon_days, v_item.history_window_days,
            v_item.as_of_business_date, v_item.as_of_at,
            v_item.sales_revision, v_item.product_revision,
            v_item.request_input_digest
        )
        ON CONFLICT ON CONSTRAINT forecast_jobs_logical_identity_uq DO NOTHING
        RETURNING id INTO v_inserted_id;

        IF v_inserted_id IS NOT NULL THEN
            job_id := v_inserted_id;
            outcome := 'queued';
        ELSE
            SELECT j.id INTO v_existing_id
              FROM private.forecast_jobs j
             WHERE j.location_id = p_location_id
               AND j.product_id = v_item.product_id
               AND j.requested_model_key = v_item.requested_model_key
               AND j.requested_model_version = v_item.requested_model_version
               AND j.requested_model_config_digest = v_item.requested_model_config_digest
               AND j.requested_implementation_digest = v_item.requested_implementation_digest
               AND j.horizon_days = v_item.horizon_days
               AND j.history_window_days = v_item.history_window_days
               AND j.as_of_at = v_item.as_of_at
               AND j.as_of_business_date = v_item.as_of_business_date
               AND j.sales_revision = v_item.sales_revision
               AND j.product_revision = v_item.product_revision
               AND j.request_input_digest = v_item.request_input_digest
             ORDER BY j.recovery_generation DESC LIMIT 1;
            job_id := v_existing_id;
            outcome := 'duplicate';
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$
;
ALTER FUNCTION public.forecast_enqueue_jobs_v1(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_enqueue_jobs_v1(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_enqueue_jobs_v1(uuid,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
