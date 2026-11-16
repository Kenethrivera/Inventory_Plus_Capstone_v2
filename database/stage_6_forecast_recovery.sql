-- Phase 6 draft: install only after approval. PostgreSQL 17. Single transaction.
BEGIN;
ALTER TABLE private.forecast_jobs
 ADD COLUMN recovery_generation smallint NOT NULL DEFAULT 0 CHECK (recovery_generation BETWEEN 0 AND 3),
 ADD COLUMN recovery_parent_id uuid REFERENCES private.forecast_jobs(id) ON DELETE RESTRICT,
 ADD COLUMN recovery_approval_id uuid,
 ADD COLUMN recovery_operator_id uuid,
 ADD COLUMN recovery_reason text,
 ADD CONSTRAINT forecast_jobs_recovery_parent_uq UNIQUE(recovery_parent_id),
 ADD CONSTRAINT forecast_jobs_recovery_approval_uq UNIQUE(recovery_approval_id),
 ADD CONSTRAINT forecast_jobs_recovery_metadata_ck CHECK (
 (recovery_generation=0 AND recovery_parent_id IS NULL AND recovery_approval_id IS NULL AND recovery_operator_id IS NULL AND recovery_reason IS NULL)
 OR (recovery_generation>0 AND recovery_parent_id IS NOT NULL AND recovery_approval_id IS NOT NULL AND recovery_operator_id IS NOT NULL
 AND recovery_reason IS NOT NULL AND recovery_reason IN ('publication_serialization_corrected','dependency_corrected','input_adapter_corrected','execution_environment_corrected')));
ALTER TABLE private.forecast_jobs DROP CONSTRAINT forecast_jobs_logical_identity_uq;
ALTER TABLE private.forecast_jobs ADD CONSTRAINT forecast_jobs_logical_identity_uq UNIQUE (location_id, product_id, requested_model_key, requested_model_version, requested_model_config_digest, requested_implementation_digest, horizon_days, history_window_days, as_of_at, as_of_business_date, sales_revision, product_revision, request_input_digest, recovery_generation);

CREATE OR REPLACE FUNCTION private.guard_forecast_recovery_v1()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE parent private.forecast_jobs%ROWTYPE;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF ROW(NEW.recovery_generation,NEW.recovery_parent_id,NEW.recovery_approval_id,NEW.recovery_operator_id,NEW.recovery_reason)
   IS DISTINCT FROM ROW(OLD.recovery_generation,OLD.recovery_parent_id,OLD.recovery_approval_id,OLD.recovery_operator_id,OLD.recovery_reason) THEN
   RAISE EXCEPTION 'Recovery audit is immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
 END IF;
 IF NEW.recovery_generation=0 THEN RETURN NEW; END IF;
 SELECT * INTO parent FROM private.forecast_jobs WHERE id=NEW.recovery_parent_id FOR UPDATE;
 IF NOT FOUND OR parent.status<>'failed' OR NEW.recovery_generation<>parent.recovery_generation+1
 OR ROW(NEW.location_id,NEW.product_id,NEW.requested_model_key,NEW.requested_model_version,NEW.requested_model_config_digest,NEW.requested_implementation_digest,NEW.horizon_days,NEW.history_window_days,NEW.as_of_at,NEW.as_of_business_date,NEW.sales_revision,NEW.product_revision,NEW.request_input_digest)
 IS DISTINCT FROM ROW(parent.location_id,parent.product_id,parent.requested_model_key,parent.requested_model_version,parent.requested_model_config_digest,parent.requested_implementation_digest,parent.horizon_days,parent.history_window_days,parent.as_of_at,parent.as_of_business_date,parent.sales_revision,parent.product_revision,parent.request_input_digest) THEN
  RAISE EXCEPTION 'Recovery must preserve failed parent identity' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
ALTER FUNCTION private.guard_forecast_recovery_v1() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.guard_forecast_recovery_v1() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER forecast_jobs_recovery_guard BEFORE INSERT OR UPDATE ON private.forecast_jobs
FOR EACH ROW EXECUTE FUNCTION private.guard_forecast_recovery_v1();

CREATE OR REPLACE FUNCTION public.recover_forecast_job_v1(
 p_location_id uuid,p_job_id uuid,p_approval_id uuid,p_operator_id uuid,
 p_reason text,p_expected_implementation_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j private.forecast_jobs%ROWTYPE; child private.forecast_jobs%ROWTYPE; v_id uuid;
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF p_approval_id IS NULL OR p_operator_id IS NULL OR p_reason IS NULL
 OR p_reason NOT IN ('publication_serialization_corrected','dependency_corrected','input_adapter_corrected','execution_environment_corrected') THEN
  RAISE EXCEPTION 'Explicit recovery approval metadata is required' USING ERRCODE='22023';
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
ALTER FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,uuid,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.recover_forecast_job_v1(uuid,uuid,uuid,uuid,text,text) TO service_role;

-- Return the latest recovery on normal enqueue deduplication.
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
COMMIT;
