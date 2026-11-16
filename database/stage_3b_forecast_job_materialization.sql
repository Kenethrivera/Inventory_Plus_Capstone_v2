BEGIN;

-- Authenticated clients can enumerate active products only through the same
-- app-session boundary used by Forecasting. The function returns identifiers
-- for the authenticated Admin's location and no inventory or sales values.
CREATE OR REPLACE FUNCTION public.forecast_active_products_v1(
    p_session_token text
)
RETURNS TABLE(product_id uuid, location_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_profile record;
BEGIN
    SELECT * INTO v_profile
      FROM private.require_app_session_v1(p_session_token);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Forecasting session is invalid or expired';
    END IF;
    IF v_profile.role <> 'admin' THEN
        RAISE EXCEPTION 'Forecast job preparation is restricted to Admin profiles';
    END IF;

    RETURN QUERY
    SELECT p.id, p.location_id
      FROM public.products p
     WHERE p.location_id = v_profile.location_id
       AND p.is_active IS TRUE
     ORDER BY p.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.forecast_active_products_v1(text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_active_products_v1(text)
    TO anon, authenticated;

-- Bootstrap missing revision rows at zero, and return the exact revision
-- values that the materializer must re-check before enqueueing.
CREATE OR REPLACE FUNCTION public.forecast_initialize_revisions_v1(
    p_location_id uuid,
    p_product_ids uuid[]
)
RETURNS TABLE(product_id uuid, sales_revision bigint, product_revision bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_product_id uuid;
BEGIN
    IF p_location_id IS NULL OR p_product_ids IS NULL THEN
        RAISE EXCEPTION 'Location and product identifiers are required';
    END IF;
    IF cardinality(p_product_ids) > 1000 THEN
        RAISE EXCEPTION 'Forecast revision initialization is limited to 1000 products';
    END IF;

    FOR v_product_id IN
        SELECT DISTINCT item.product_id
          FROM unnest(p_product_ids) AS item(product_id)
         WHERE item.product_id IS NOT NULL
         ORDER BY item.product_id
    LOOP
        INSERT INTO private.forecast_input_revisions (
            location_id, product_id, sales_revision, product_revision,
            inventory_revision, configuration_revision, updated_at
        )
        SELECT p.location_id, p.id, 0, 0, 0, 0, clock_timestamp()
          FROM public.products p
         WHERE p.id = v_product_id
           AND p.location_id = p_location_id
           AND p.is_active IS TRUE
        -- The RETURNS TABLE output parameter `product_id` makes an unqualified
        -- conflict target ambiguous in PL/pgSQL. Name the real primary key.
        ON CONFLICT ON CONSTRAINT forecast_input_revisions_pkey DO NOTHING;
    END LOOP;

    RETURN QUERY
    SELECT r.product_id, r.sales_revision, r.product_revision
      FROM private.forecast_input_revisions r
      JOIN public.products p
        ON p.id = r.product_id AND p.location_id = r.location_id
     WHERE r.location_id = p_location_id
       AND r.product_id = ANY(p_product_ids)
       AND p.is_active IS TRUE
     ORDER BY r.product_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.forecast_initialize_revisions_v1(uuid, uuid[])
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_initialize_revisions_v1(uuid, uuid[])
    TO service_role;

-- Re-check revision freshness and publish a bounded batch of queued jobs in one
-- transaction. This performs no forecasting work and never changes a running
-- lease. A stale prepared input receives a result status but no job row.
CREATE OR REPLACE FUNCTION public.forecast_enqueue_jobs_v1(
    p_location_id uuid,
    p_jobs jsonb
)
RETURNS TABLE(product_id uuid, job_id uuid, outcome text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
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
           OR v_item.requested_model_key IS DISTINCT FROM 'blend'
           OR v_item.requested_model_version IS DISTINCT FROM '1'
           OR v_item.horizon_days IS DISTINCT FROM 28
           OR v_item.history_window_days IS DISTINCT FROM 365
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
               AND j.request_input_digest = v_item.request_input_digest;
            job_id := v_existing_id;
            outcome := 'duplicate';
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.forecast_enqueue_jobs_v1(uuid, jsonb)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_enqueue_jobs_v1(uuid, jsonb)
    TO service_role;

COMMIT;
