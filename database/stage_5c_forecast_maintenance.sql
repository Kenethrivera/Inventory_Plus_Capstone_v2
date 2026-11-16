

-- Approval required. No execution or scheduling on installation.
BEGIN;
-- Explicit testing-location allowlist. Review this literal before deployment.
CREATE OR REPLACE FUNCTION private.forecast_maintenance_scope_v1(p_location_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
 IF p_location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'::uuid THEN
  RAISE EXCEPTION 'Maintenance location is not allowed' USING ERRCODE = '42501';
 END IF;
END $$;
REVOKE ALL ON FUNCTION private.forecast_maintenance_scope_v1(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.forecast_maintenance_demand_v1(
    p_location_id uuid,
    p_business_date date,
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
    PERFORM private.forecast_maintenance_scope_v1(p_location_id);
    IF p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN
        RAISE EXCEPTION 'Maintenance requires the current business date' USING ERRCODE = '22023';
    END IF;
    v_start := ((p_business_date - 365)::timestamp AT TIME ZONE v_tz);
    v_end := (p_business_date::timestamp AT TIME ZONE v_tz);

    -- Keep the existing demand extractor's fail-closed validation semantics.
    IF p_offset = 0 THEN
        FOR v_order IN
            SELECT h.order_id, h.items
              FROM public.order_history AS h
             WHERE h.location_id = p_location_id
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
         WHERE h.location_id = p_location_id
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

CREATE OR REPLACE FUNCTION public.forecast_maintenance_page_v1(
 p_location_id uuid, p_business_date date, p_config_digest text,
 p_implementation_digest text, p_after uuid DEFAULT NULL, p_limit integer DEFAULT 10
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 25
 OR p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date
 OR p_config_digest IS NULL OR p_config_digest !~ '^[0-9a-f]{64}$'
 OR p_implementation_digest IS NULL OR p_implementation_digest !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Invalid maintenance page' USING ERRCODE='22023';
 END IF;
 WITH scoped AS MATERIALIZED (
 SELECT p.id, p.location_id, p.product_name, p.sku, p.unit, p.created_at,
 coalesce(r.sales_revision,0) sales_revision, coalesce(r.product_revision,0) product_revision,
 CASE WHEN nullif(btrim(p.unit),'') IS NULL THEN 'excluded'
 WHEN j.id IS NULL THEN CASE WHEN EXISTS (
  SELECT 1 FROM private.forecast_jobs old WHERE old.location_id=p.location_id AND old.product_id=p.id
   AND old.requested_model_key='blend') THEN 'stale' ELSE 'missing' END
 WHEN j.status='succeeded' THEN 'current'
 WHEN j.status='queued' AND j.attempt_count>0 THEN 'retry_pending'
 ELSE j.status END state, j.safe_error_code
 FROM public.products p
 LEFT JOIN private.forecast_input_revisions r ON r.location_id=p.location_id AND r.product_id=p.id
 LEFT JOIN LATERAL (
 SELECT q.* FROM private.forecast_jobs q WHERE q.location_id=p.location_id AND q.product_id=p.id
 AND q.requested_model_key='blend' AND q.requested_model_version='1'
 AND q.requested_model_config_digest=p_config_digest AND q.requested_implementation_digest=p_implementation_digest
 AND q.horizon_days=28 AND q.history_window_days=365 AND q.as_of_business_date=p_business_date
 AND q.sales_revision=coalesce(r.sales_revision,0) AND q.product_revision=coalesce(r.product_revision,0)
 ORDER BY q.created_at DESC,q.id DESC LIMIT 1
 ) j ON true
 WHERE p.location_id=p_location_id AND p.is_active IS TRUE
 ), page AS (SELECT * FROM scoped WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit),
 counts AS (SELECT state,count(*) n FROM scoped GROUP BY state)
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY id) FROM page),'[]'::jsonb),
 'coverage',coalesce((SELECT jsonb_object_agg(state,n) FROM counts),'{}'::jsonb),
 'revision_fingerprint',(SELECT md5(coalesce(string_agg(id::text||':'||sales_revision::text||':'||product_revision::text,',' ORDER BY id),'')) FROM scoped),
 'active_products',(SELECT count(*) FROM scoped)) INTO v_result;
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.forecast_maintenance_enqueue_v1(p_location_id uuid,p_jobs jsonb)
RETURNS TABLE(product_id uuid,job_id uuid,outcome text) LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF jsonb_typeof(p_jobs) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid job batch'; END IF;
 IF jsonb_array_length(p_jobs)>25 THEN RAISE EXCEPTION 'Job batch exceeds limit'; END IF;
 RETURN QUERY SELECT * FROM public.forecast_enqueue_jobs_v1(p_location_id,p_jobs);
END $$;

-- Only the already Admin-authorized backend calls this endpoint. It does not
-- authorize a Flutter caller; service_role EXECUTE is the trusted boundary.
CREATE OR REPLACE FUNCTION public.forecast_request_jobs_v1(p_location_id uuid,p_jobs jsonb)
RETURNS TABLE(product_id uuid,job_id uuid,outcome text,status text,safe_error_code text) LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_row record;
BEGIN
 IF jsonb_typeof(p_jobs) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid request'; END IF;
 IF jsonb_array_length(p_jobs)<>1 THEN RAISE EXCEPTION 'Exactly one product is required'; END IF;
 FOR v_row IN SELECT * FROM public.forecast_enqueue_jobs_v1(p_location_id,p_jobs) LOOP
  UPDATE private.forecast_jobs q SET priority=greatest(q.priority,10),updated_at=clock_timestamp()
   WHERE q.id=v_row.job_id AND q.location_id=p_location_id AND q.status='queued';
  product_id:=v_row.product_id; job_id:=v_row.job_id; outcome:=v_row.outcome;
  SELECT q.status,q.safe_error_code INTO status,safe_error_code FROM private.forecast_jobs q WHERE q.id=v_row.job_id AND q.location_id=p_location_id;
  RETURN NEXT;
 END LOOP;
END $$;

ALTER FUNCTION private.forecast_maintenance_scope_v1(uuid) OWNER TO postgres;
ALTER FUNCTION public.forecast_maintenance_demand_v1(uuid,date,integer,integer) OWNER TO postgres;
ALTER FUNCTION public.forecast_maintenance_page_v1(uuid,date,text,text,uuid,integer) OWNER TO postgres;
ALTER FUNCTION public.forecast_maintenance_enqueue_v1(uuid,jsonb) OWNER TO postgres;
ALTER FUNCTION public.forecast_request_jobs_v1(uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_maintenance_demand_v1(uuid,date,integer,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.forecast_maintenance_page_v1(uuid,date,text,text,uuid,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.forecast_maintenance_enqueue_v1(uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.forecast_request_jobs_v1(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_maintenance_demand_v1(uuid,date,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.forecast_maintenance_page_v1(uuid,date,text,text,uuid,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.forecast_maintenance_enqueue_v1(uuid,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.forecast_request_jobs_v1(uuid,jsonb) TO service_role;
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
         ORDER BY (j.priority + floor(extract(epoch FROM (v_now-j.created_at))/60)) DESC, j.available_at, j.created_at, j.id
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


COMMIT;
