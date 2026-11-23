-- Read-only, service-role-only forecast job monitoring for the authenticated API.
-- Review against the live catalog before manual installation. This file is not
-- executed by the application or by Codex.
BEGIN;

CREATE OR REPLACE FUNCTION public.forecast_jobs_page_v1(
    p_location_id uuid,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 25,
    p_latest_only boolean DEFAULT true,
    p_search text DEFAULT NULL,
    p_model_key text DEFAULT NULL,
    p_status text DEFAULT NULL,
    p_from_business_date date DEFAULT NULL,
    p_to_business_date date DEFAULT NULL
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
       OR p_page IS NULL OR p_page < 1 OR p_page > 10000
       OR p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 50
       OR p_latest_only IS NULL
       OR length(p_search) > 120
       OR (p_model_key IS NOT NULL AND p_model_key NOT IN
           ('blend', 'lightgbm', 'mean28', 'seasonal_experimental'))
       OR (p_status IS NOT NULL AND p_status NOT IN
           ('queued', 'retry_pending', 'running', 'succeeded', 'failed',
            'cancelled', 'superseded'))
       OR (p_from_business_date IS NOT NULL AND p_to_business_date IS NOT NULL
           AND p_from_business_date > p_to_business_date) THEN
        RAISE EXCEPTION 'Forecast jobs query is invalid' USING ERRCODE = '22023';
    END IF;

    WITH scoped AS MATERIALIZED (
        SELECT j.id AS job_id,
               j.product_id,
               p.product_name,
               p.sku,
               j.requested_model_key AS model_key,
               j.requested_model_version AS model_version,
               j.as_of_business_date,
               j.horizon_days,
               j.status,
               CASE WHEN j.status = 'queued' AND j.attempt_count > 0
                    THEN 'retry_pending' ELSE j.status END AS display_status,
               j.created_at,
               j.started_at,
               j.completed_at,
               j.updated_at,
               j.attempt_count,
               j.max_attempts,
               CASE WHEN j.safe_error_code ~ '^[a-z][a-z0-9_]{0,63}$'
                    THEN j.safe_error_code ELSE NULL END AS safe_error_code,
               r.id AS result_id,
               r.created_at AS result_created_at,
               row_number() OVER (
                   PARTITION BY j.product_id, j.requested_model_key
                   ORDER BY j.created_at DESC, j.id DESC
               ) AS latest_rank
          FROM private.forecast_jobs AS j
          LEFT JOIN public.products AS p
            ON p.id = j.product_id AND p.location_id = j.location_id
          LEFT JOIN LATERAL (
              SELECT er.id, er.created_at
                FROM private.forecast_execution_results AS er
               WHERE er.job_id = j.id AND er.location_id = j.location_id
               ORDER BY er.created_at DESC, er.id DESC
               LIMIT 1
          ) AS r ON true
         WHERE j.location_id = p_location_id
           AND (p_model_key IS NULL OR j.requested_model_key = p_model_key)
    ),
    filtered AS MATERIALIZED (
        SELECT s.*
          FROM scoped AS s
         WHERE (NOT p_latest_only OR s.latest_rank = 1)
           AND (p_search IS NULL OR btrim(p_search) = ''
                OR s.product_name ILIKE ('%' || btrim(p_search) || '%')
                OR s.sku ILIKE ('%' || btrim(p_search) || '%'))
           AND (p_status IS NULL OR s.display_status = p_status)
           AND (p_from_business_date IS NULL OR s.created_at >=
                (p_from_business_date::timestamp AT TIME ZONE 'Asia/Manila'))
           AND (p_to_business_date IS NULL OR s.created_at <
                ((p_to_business_date + 1)::timestamp AT TIME ZONE 'Asia/Manila'))
    )
    SELECT jsonb_build_object(
        'page', p_page,
        'generated_at', clock_timestamp(),
        'page_size', p_page_size,
        'latest_only', p_latest_only,
        'total_count', (SELECT count(*)::integer FROM filtered),
        'page_count', (SELECT CASE WHEN count(*) = 0 THEN 0
                            ELSE ceil(count(*)::numeric / p_page_size)::integer
                       END FROM filtered),
        'counts', (SELECT jsonb_build_object(
            'total_jobs', count(*)::integer,
            'queued', count(*) FILTER (WHERE display_status = 'queued'),
            'retry_pending', count(*) FILTER (WHERE display_status = 'retry_pending'),
            'running', count(*) FILTER (WHERE display_status = 'running'),
            'succeeded', count(*) FILTER (WHERE display_status = 'succeeded'),
            'failed', count(*) FILTER (WHERE display_status = 'failed'),
            'cancelled', count(*) FILTER (WHERE display_status = 'cancelled'),
            'superseded', count(*) FILTER (WHERE display_status = 'superseded')
        ) FROM filtered),
        'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'job_id', page.job_id,
            'product_id', page.product_id,
            'product_name', page.product_name,
            'sku', page.sku,
            'model_key', page.model_key,
            'model_version', page.model_version,
            'as_of_business_date', page.as_of_business_date,
            'horizon_days', page.horizon_days,
            'status', page.status,
            'display_status', page.display_status,
            'created_at', page.created_at,
            'started_at', page.started_at,
            'completed_at', page.completed_at,
            'updated_at', page.updated_at,
            'duration_seconds', CASE
                WHEN page.attempt_count = 1 AND page.started_at IS NOT NULL
                 AND page.completed_at >= page.started_at
                THEN round(extract(epoch FROM
                     (page.completed_at - page.started_at))::numeric, 3)
                ELSE NULL END,
            'attempt_count', page.attempt_count,
            'max_attempts', page.max_attempts,
            'safe_error_code', page.safe_error_code,
            'result_id', page.result_id,
            'result_created_at', page.result_created_at
        ) ORDER BY page.created_at DESC, page.job_id DESC), '[]'::jsonb)
          FROM (SELECT * FROM filtered
                 ORDER BY created_at DESC, job_id DESC
                 LIMIT p_page_size OFFSET ((p_page - 1) * p_page_size)) AS page)
    ) INTO v_result;

    RETURN v_result;
END;
$function$;

ALTER FUNCTION public.forecast_jobs_page_v1(
    uuid, integer, integer, boolean, text, text, text, date, date
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_jobs_page_v1(
    uuid, integer, integer, boolean, text, text, text, date, date
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_jobs_page_v1(
    uuid, integer, integer, boolean, text, text, text, date, date
) TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
