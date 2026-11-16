-- Stage 6A: forward-only correction for the INSTALLED Stage 6 migration.
-- Review/approve before installation. No jobs are created by this migration.
-- UUID approval references remain unchanged. Never infer a profile from a UUID.
BEGIN;
SET LOCAL lock_timeout = '10s';
LOCK TABLE private.forecast_jobs IN ACCESS EXCLUSIVE MODE;
DO $$
BEGIN
 IF (SELECT a.atttypid FROM pg_attribute a
     WHERE a.attrelid='public.profiles'::regclass AND a.attname='id'
       AND NOT a.attisdropped) IS DISTINCT FROM 'bigint'::regtype THEN
  RAISE EXCEPTION 'Expected public.profiles.id to be BIGINT';
 END IF;
 IF EXISTS (SELECT 1 FROM private.forecast_jobs WHERE recovery_operator_id IS NOT NULL) THEN
  RAISE EXCEPTION 'Existing UUID operator audit must be preserved; explicit identity mapping review required';
 END IF;
END $$;
-- Verified deployed state has zero recovery rows. The lock makes the guard
-- atomic with the type correction. Abort rather than erase any later UUID audit.
ALTER TABLE private.forecast_jobs
 ALTER COLUMN recovery_operator_id TYPE bigint USING recovery_operator_id::text::bigint;
COMMENT ON COLUMN private.forecast_jobs.recovery_operator_id IS
 'Approving public.profiles.id, checked by the service-only recovery RPC; retained as historical audit identity.';
-- Remove the old overload to avoid ambiguous PostgREST dispatch or UUID callers.
-- No CASCADE: unexpected dependencies fail and roll back the entire migration.
DROP FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,uuid,text,text);

CREATE OR REPLACE FUNCTION public.recover_forecast_job_v1(
 p_location_id uuid,p_job_id uuid,p_approval_id uuid,p_operator_id bigint,
 p_reason text,p_expected_implementation_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j private.forecast_jobs%ROWTYPE; child private.forecast_jobs%ROWTYPE; v_id uuid;
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF p_approval_id IS NULL OR p_operator_id IS NULL OR p_reason IS NULL
 OR p_reason NOT IN ('publication_serialization_corrected','dependency_corrected','input_adapter_corrected','execution_environment_corrected') THEN
  RAISE EXCEPTION 'Explicit recovery approval metadata is required' USING ERRCODE='22023';
 END IF;
 -- The service credential authorizes the call; the profile identifies the
 -- approving Admin. Do not accept arbitrary identifiers or another location.
 PERFORM 1 FROM public.profiles p
 WHERE p.id=p_operator_id AND p.is_active IS TRUE AND p.role='admin'
 AND p.location_id=p_location_id FOR SHARE;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'Recovery operator must be an active Admin in the allowed location'
   USING ERRCODE='42501';
 END IF;
 SELECT * INTO j FROM private.forecast_jobs WHERE id=p_job_id AND location_id=p_location_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Forecast job unavailable in scope' USING ERRCODE='22023'; END IF;
 -- Match enqueue lock order: revision before job. No model execution in transaction.
 PERFORM 1 FROM private.forecast_input_revisions r WHERE r.location_id=j.location_id AND r.product_id=j.product_id
 AND r.sales_revision=j.sales_revision AND r.product_revision=j.product_revision FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Forecast revisions changed; prepare current inputs' USING ERRCODE='40001'; END IF;
 SELECT * INTO j FROM private.forecast_jobs WHERE id=p_job_id FOR UPDATE;
 SELECT * INTO child FROM private.forecast_jobs WHERE recovery_parent_id=j.id;
 IF FOUND THEN RETURN jsonb_build_object('job_id',child.id,'status',child.status,'duplicate',true); END IF;
 IF j.status<>'failed' OR j.recovery_generation>=3 OR j.lease_token IS NOT NULL
 OR j.as_of_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date
 OR j.requested_implementation_digest IS DISTINCT FROM p_expected_implementation_digest
 OR NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=j.product_id AND p.location_id=j.location_id AND p.is_active IS TRUE)
 THEN RAISE EXCEPTION 'Job is not eligible for same-identity recovery' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM private.forecast_execution_results r WHERE
 ROW(r.location_id,r.product_id,r.requested_model_key,r.requested_model_version,r.requested_model_config_digest,r.requested_implementation_digest,r.horizon_days,r.history_window_days,r.as_of_at,r.as_of_business_date,r.sales_revision,r.product_revision,r.request_input_digest)=ROW(j.location_id,j.product_id,j.requested_model_key,j.requested_model_version,j.requested_model_config_digest,j.requested_implementation_digest,j.horizon_days,j.history_window_days,j.as_of_at,j.as_of_business_date,j.sales_revision,j.product_revision,j.request_input_digest)) THEN
  RAISE EXCEPTION 'Forecast already has an immutable successful result' USING ERRCODE='23514';
 END IF;
 INSERT INTO private.forecast_jobs (location_id, product_id, requested_model_key, requested_model_version, requested_model_config_digest, requested_implementation_digest, horizon_days, history_window_days, as_of_at, as_of_business_date, sales_revision, product_revision, request_input_digest,idempotency_key,priority,max_attempts,
 recovery_generation,recovery_parent_id,recovery_approval_id,recovery_operator_id,recovery_reason)
 SELECT j.location_id,j.product_id,j.requested_model_key,j.requested_model_version,j.requested_model_config_digest,j.requested_implementation_digest,j.horizon_days,j.history_window_days,j.as_of_at,j.as_of_business_date,j.sales_revision,j.product_revision,j.request_input_digest,p_approval_id,j.priority,j.max_attempts,
 j.recovery_generation+1,j.id,p_approval_id,p_operator_id,p_reason RETURNING id INTO v_id;
 RETURN jsonb_build_object('job_id',v_id,'status','queued','duplicate',false);
END $$;
ALTER FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,bigint,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,bigint,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,bigint,text,text) TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
