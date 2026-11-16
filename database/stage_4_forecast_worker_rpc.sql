-- Stage 4 worker RPCs. Draft only: review and authorize before applying.
-- Adds no tables and never grants clients direct access to private tables.
BEGIN;

CREATE OR REPLACE FUNCTION public.claim_forecast_job_v1(
    p_worker_id text,
    p_lease_seconds integer,
    p_job_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
DECLARE
    v_job private.forecast_jobs%ROWTYPE;
    v_now timestamptz := clock_timestamp();
    v_vector jsonb;
BEGIN
    IF p_worker_id IS NULL OR length(btrim(p_worker_id)) NOT BETWEEN 1 AND 96
       OR p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 30 AND 900 THEN
        RAISE EXCEPTION 'Invalid worker claim parameters' USING ERRCODE = '22023';
    END IF;

    LOOP
        SELECT j.* INTO v_job
          FROM private.forecast_jobs AS j
         WHERE (p_job_id IS NULL OR j.id = p_job_id)
           AND (
                (j.status = 'queued' AND j.available_at <= v_now)
                OR (j.status = 'running' AND j.lease_expires_at <= v_now)
           )
         ORDER BY j.priority DESC, j.available_at, j.created_at, j.id
         LIMIT 1
         FOR UPDATE SKIP LOCKED;
        IF NOT FOUND THEN
            RETURN NULL;
        END IF;

        IF v_job.attempt_count >= v_job.max_attempts THEN
            UPDATE private.forecast_jobs
               SET status = 'failed', completed_at = v_now,
                   safe_error_code = 'attempt_limit_reached',
                   lease_owner = NULL, lease_token = NULL,
                   lease_expires_at = NULL, updated_at = v_now
             WHERE id = v_job.id;
            IF p_job_id IS NOT NULL THEN RETURN NULL; END IF;
            CONTINUE;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM private.forecast_input_revisions AS r
             WHERE r.location_id = v_job.location_id
               AND r.product_id = v_job.product_id
               AND r.sales_revision = v_job.sales_revision
               AND r.product_revision = v_job.product_revision
        ) THEN
            UPDATE private.forecast_jobs
               SET status = 'superseded', completed_at = v_now,
                   safe_error_code = 'forecast_inputs_superseded',
                   lease_owner = NULL, lease_token = NULL,
                   lease_expires_at = NULL, updated_at = v_now
             WHERE id = v_job.id;
            IF p_job_id IS NOT NULL THEN RETURN NULL; END IF;
            CONTINUE;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.products AS p
             WHERE p.id = v_job.product_id
               AND p.location_id = v_job.location_id
               AND p.is_active IS TRUE
        ) THEN
            UPDATE private.forecast_jobs
               SET status = 'superseded', completed_at = v_now,
                   safe_error_code = 'forecast_product_inactive',
                   lease_owner = NULL, lease_token = NULL,
                   lease_expires_at = NULL, updated_at = v_now
             WHERE id = v_job.id;
            IF p_job_id IS NOT NULL THEN RETURN NULL; END IF;
            CONTINUE;
        END IF;

        UPDATE private.forecast_jobs AS j
           SET status = 'running', attempt_count = j.attempt_count + 1,
               lease_owner = p_worker_id, lease_token = gen_random_uuid(),
               lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
               started_at = coalesce(j.started_at, v_now),
               completed_at = NULL, safe_error_code = NULL, updated_at = v_now
         WHERE j.id = v_job.id
         RETURNING j.* INTO v_job;

        SELECT coalesce(
                   jsonb_agg(
                       jsonb_build_array(r.product_id::text, r.sales_revision, r.product_revision)
                       ORDER BY r.product_id
                   ), '[]'::jsonb
               ) INTO v_vector
          FROM private.forecast_input_revisions AS r
         WHERE r.location_id = v_job.location_id;
        RETURN to_jsonb(v_job) || jsonb_build_object('scope_revision_vector', v_vector);
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.renew_forecast_job_lease_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_lease_seconds integer
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
DECLARE
    v_job private.forecast_jobs%ROWTYPE;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 30 AND 900 THEN
        RAISE EXCEPTION 'Invalid lease duration' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_job FROM private.forecast_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND OR v_job.status <> 'running'
       OR v_job.lease_token IS DISTINCT FROM p_lease_token
       OR v_job.lease_expires_at <= v_now THEN
        RETURN 'lease_lost';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM private.forecast_input_revisions AS r
         WHERE r.location_id = v_job.location_id AND r.product_id = v_job.product_id
           AND r.sales_revision = v_job.sales_revision
           AND r.product_revision = v_job.product_revision
    ) THEN
        UPDATE private.forecast_jobs
           SET status = 'superseded', completed_at = v_now,
               safe_error_code = 'forecast_inputs_superseded',
               lease_owner = NULL, lease_token = NULL,
               lease_expires_at = NULL, updated_at = v_now
         WHERE id = p_job_id;
        RETURN 'stale';
    END IF;
    UPDATE private.forecast_jobs
       SET lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
           updated_at = v_now
     WHERE id = p_job_id;
    RETURN 'active';
END;
$function$;

CREATE OR REPLACE FUNCTION public.supersede_forecast_job_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_safe_error_code text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
BEGIN
    IF p_safe_error_code IS NULL OR p_safe_error_code NOT IN (
        'queued_input_digest_mismatch', 'queued_history_bounds_mismatch',
        'forecast_inputs_superseded'
    ) THEN
        RAISE EXCEPTION 'Invalid supersede reason' USING ERRCODE = '22023';
    END IF;
    UPDATE private.forecast_jobs
       SET status = 'superseded', completed_at = clock_timestamp(),
           safe_error_code = p_safe_error_code,
           lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE id = p_job_id AND status = 'running'
       AND lease_token = p_lease_token
       AND lease_expires_at > clock_timestamp();
    RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fail_forecast_job_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_safe_error_code text,
    p_retryable boolean,
    p_retry_delay_seconds integer
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
DECLARE
    v_job private.forecast_jobs%ROWTYPE;
    v_retry boolean;
BEGIN
    IF p_safe_error_code IS NULL OR p_safe_error_code NOT IN (
        'transient_network_failure', 'transient_rpc_failure',
        'upstream_rpc_rejected', 'transient_io_failure',
        'forecast_input_unavailable', 'forecast_execution_invalid',
        'forecast_execution_failed', 'worker_shutdown'
    ) OR p_retryable IS NULL OR p_retry_delay_seconds IS NULL
       OR p_retry_delay_seconds NOT BETWEEN 1 AND 600 THEN
        RAISE EXCEPTION 'Invalid forecast failure metadata' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_job FROM private.forecast_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND OR v_job.status <> 'running'
       OR v_job.lease_token IS DISTINCT FROM p_lease_token
       OR v_job.lease_expires_at <= clock_timestamp() THEN
        RETURN 'lease_lost';
    END IF;
    v_retry := p_retryable AND v_job.attempt_count < v_job.max_attempts;
    UPDATE private.forecast_jobs
       SET status = CASE WHEN v_retry THEN 'queued' ELSE 'failed' END,
           available_at = CASE WHEN v_retry
               THEN clock_timestamp() + make_interval(secs => p_retry_delay_seconds)
               ELSE available_at END,
           completed_at = CASE WHEN v_retry THEN NULL ELSE clock_timestamp() END,
           safe_error_code = p_safe_error_code,
           lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE id = p_job_id;
    RETURN CASE WHEN v_retry THEN 'retry_queued' ELSE 'failed' END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.publish_forecast_execution_result_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_output_bundle jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
DECLARE
    v_job private.forecast_jobs%ROWTYPE;
    v_result_id uuid;
    v_now timestamptz := clock_timestamp();
BEGIN
    SELECT * INTO v_job FROM private.forecast_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Forecast job does not exist' USING ERRCODE = 'P0002'; END IF;

    -- A repeated publish after a lost HTTP response returns the committed result.
    IF v_job.status = 'succeeded' THEN
        SELECT id INTO v_result_id FROM private.forecast_execution_results WHERE job_id = p_job_id;
        IF v_result_id IS NOT NULL THEN
            RETURN jsonb_build_object('status', 'succeeded', 'result_id', v_result_id, 'duplicate', true);
        END IF;
        RAISE EXCEPTION 'Succeeded forecast job is missing its result' USING ERRCODE = '23514';
    END IF;

    IF v_job.status <> 'running' OR v_job.lease_token IS DISTINCT FROM p_lease_token
       OR v_job.lease_expires_at <= v_now THEN
        RAISE EXCEPTION 'Forecast worker lease is no longer valid' USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM private.forecast_input_revisions AS r
         WHERE r.location_id = v_job.location_id AND r.product_id = v_job.product_id
           AND r.sales_revision = v_job.sales_revision
           AND r.product_revision = v_job.product_revision
         FOR SHARE
    ) THEN
        UPDATE private.forecast_jobs
           SET status = 'superseded', completed_at = v_now,
               safe_error_code = 'forecast_inputs_superseded',
               lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
               updated_at = v_now
         WHERE id = p_job_id;
        RETURN jsonb_build_object('status', 'superseded');
    END IF;

    IF jsonb_typeof(p_output_bundle) IS DISTINCT FROM 'object'
       OR p_output_bundle #>> '{execution,requested_model,key}' IS DISTINCT FROM v_job.requested_model_key
       OR p_output_bundle #>> '{execution,requested_model,version}' IS DISTINCT FROM v_job.requested_model_version
       OR p_output_bundle #>> '{execution,requested_model,config_digest}' IS DISTINCT FROM v_job.requested_model_config_digest
       OR p_output_bundle #>> '{execution,requested_model,implementation_digest}' IS DISTINCT FROM v_job.requested_implementation_digest THEN
        RAISE EXCEPTION 'Forecast output does not match claimed job identity' USING ERRCODE = '23514';
    END IF;

    INSERT INTO private.forecast_execution_results (
        job_id, location_id, product_id,
        requested_model_key, requested_model_version,
        requested_model_config_digest, requested_implementation_digest,
        horizon_days, history_window_days, as_of_business_date, as_of_at,
        sales_revision, product_revision, request_input_digest,
        forecast_start_date, forecast_end_date, inventory_unit,
        source_data_as_of, bundle_schema_version, output_bundle
    ) VALUES (
        v_job.id, v_job.location_id, v_job.product_id,
        v_job.requested_model_key, v_job.requested_model_version,
        v_job.requested_model_config_digest, v_job.requested_implementation_digest,
        v_job.horizon_days, v_job.history_window_days, v_job.as_of_business_date,
        v_job.as_of_at, v_job.sales_revision, v_job.product_revision,
        v_job.request_input_digest,
        (p_output_bundle #>> '{execution,forecast_start_date}')::date,
        (p_output_bundle #>> '{execution,forecast_end_date}')::date,
        p_output_bundle #>> '{execution,inventory_unit}',
        (p_output_bundle #>> '{execution,source_data_as_of}')::timestamptz,
        (p_output_bundle->>'schema_version')::smallint,
        p_output_bundle
    ) RETURNING id INTO v_result_id;

    -- Result validation sees a running job with its live lease. The deferred
    -- job/result constraint observes succeeded plus result together at commit.
    UPDATE private.forecast_jobs
       SET status = 'succeeded', completed_at = v_now,
           lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
           safe_error_code = NULL, updated_at = v_now
     WHERE id = p_job_id;
    RETURN jsonb_build_object('status', 'succeeded', 'result_id', v_result_id, 'duplicate', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.forecast_worker_daily_demand_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_offset integer DEFAULT 0,
    p_limit integer DEFAULT 1000
) RETURNS TABLE(
    business_date date, location_id uuid, product_id uuid, sku text,
    product_name text, unit text, quantity numeric, completed_order_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, private, pg_temp
AS $function$
DECLARE
    v_job private.forecast_jobs%ROWTYPE;
    v_tz constant text := 'Asia/Manila';
    v_start timestamptz;
    v_end timestamptz;
    v_order record;
    v_item jsonb;
    v_product_id_text text;
    v_quantity_text text;
BEGIN
    IF p_offset IS NULL OR p_offset < 0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'Invalid demand page bounds' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_job FROM private.forecast_jobs WHERE id = p_job_id;
    IF NOT FOUND OR v_job.status <> 'running'
       OR v_job.lease_token IS DISTINCT FROM p_lease_token
       OR v_job.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Forecast worker lease is no longer valid' USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM private.forecast_input_revisions AS r
         WHERE r.location_id = v_job.location_id AND r.product_id = v_job.product_id
           AND r.sales_revision = v_job.sales_revision
           AND r.product_revision = v_job.product_revision
    ) THEN
        RAISE EXCEPTION 'Forecast demand revisions are stale' USING ERRCODE = '40001';
    END IF;
    v_start := ((v_job.as_of_business_date - v_job.history_window_days)::timestamp AT TIME ZONE v_tz);
    v_end := v_job.as_of_at;

    -- Keep the existing demand extractor's fail-closed validation semantics.
    IF p_offset = 0 THEN
        FOR v_order IN
            SELECT h.order_id, h.items
              FROM public.order_history AS h
             WHERE h.location_id = v_job.location_id
               AND lower(trim(h.status)) = 'completed'
               AND h.completed_at >= v_start AND h.completed_at < v_end
               AND h.returned_at IS NULL
        LOOP
            IF jsonb_typeof(v_order.items) IS DISTINCT FROM 'array' THEN
                RAISE EXCEPTION 'Completed demand order has invalid item data' USING ERRCODE = '22000';
            END IF;
            IF jsonb_array_length(v_order.items) = 0 THEN
                RAISE EXCEPTION 'Completed demand order has invalid item data' USING ERRCODE = '22000';
            END IF;
            FOR v_item IN SELECT value FROM jsonb_array_elements(v_order.items)
            LOOP
                v_product_id_text := coalesce(v_item->>'product_id', v_item->>'productId');
                v_quantity_text := v_item->>'quantity';
                IF v_product_id_text IS NULL OR v_quantity_text IS NULL
                   OR v_quantity_text !~ '^[0-9]+([.][0-9]+)?$'
                   OR v_quantity_text::numeric <= 0 THEN
                    RAISE EXCEPTION 'Completed demand order has an invalid item line' USING ERRCODE = '22000';
                END IF;
                BEGIN
                    PERFORM v_product_id_text::uuid;
                EXCEPTION WHEN invalid_text_representation THEN
                    RAISE EXCEPTION 'Completed demand order has an invalid product identifier' USING ERRCODE = '22000';
                END;
            END LOOP;
        END LOOP;
    END IF;

    RETURN QUERY
    WITH completed_orders AS (
        SELECT h.order_id, h.location_id, h.completed_at, h.items
          FROM public.order_history AS h
         WHERE h.location_id = v_job.location_id
           AND lower(trim(h.status)) = 'completed'
           AND h.completed_at >= v_start AND h.completed_at < v_end
           AND h.returned_at IS NULL
    ), expanded AS (
        SELECT o.order_id, o.location_id,
               (o.completed_at AT TIME ZONE v_tz)::date AS business_date,
               coalesce(i.value->>'product_id', i.value->>'productId')::uuid AS product_id,
               coalesce(nullif(trim(i.value->>'product_name'), ''),
                        nullif(trim(i.value->>'productName'), ''), 'Unknown product') AS product_name,
               coalesce(nullif(trim(i.value->>'unit'), ''), 'pcs') AS unit,
               (i.value->>'quantity')::numeric AS quantity
          FROM completed_orders AS o
          CROSS JOIN LATERAL jsonb_array_elements(o.items) AS i(value)
    )
    SELECT e.business_date, e.location_id, e.product_id, p.sku,
           max(e.product_name)::text, e.unit, sum(e.quantity),
           count(DISTINCT e.order_id)
      FROM expanded AS e
      LEFT JOIN public.products AS p
        ON p.id = e.product_id AND p.location_id = e.location_id
     GROUP BY e.business_date, e.location_id, e.product_id, p.sku, e.unit
     ORDER BY e.business_date, e.product_id
     LIMIT p_limit OFFSET p_offset;
END;
$function$;

ALTER FUNCTION public.claim_forecast_job_v1(text, integer, uuid) OWNER TO postgres;
ALTER FUNCTION public.renew_forecast_job_lease_v1(uuid, uuid, integer) OWNER TO postgres;
ALTER FUNCTION public.supersede_forecast_job_v1(uuid, uuid, text) OWNER TO postgres;
ALTER FUNCTION public.fail_forecast_job_v1(uuid, uuid, text, boolean, integer) OWNER TO postgres;
ALTER FUNCTION public.publish_forecast_execution_result_v1(uuid, uuid, jsonb) OWNER TO postgres;
ALTER FUNCTION public.forecast_worker_daily_demand_v1(uuid, uuid, integer, integer) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.claim_forecast_job_v1(text, integer, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_forecast_job_lease_v1(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.supersede_forecast_job_v1(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_forecast_job_v1(uuid, uuid, text, boolean, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_forecast_execution_result_v1(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.forecast_worker_daily_demand_v1(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_forecast_job_v1(text, integer, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.renew_forecast_job_lease_v1(uuid, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.supersede_forecast_job_v1(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_forecast_job_v1(uuid, uuid, text, boolean, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.publish_forecast_execution_result_v1(uuid, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.forecast_worker_daily_demand_v1(uuid, uuid, integer, integer) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
