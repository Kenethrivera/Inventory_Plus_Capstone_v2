-- psql ONLY against an isolated testing clone with Stage 6 AND Stage 6A installed.
-- Supply -v failed_job_id=<current-date failed fixture UUID> -v operator_id=<existing Admin BIGINT>.
-- No forecast model runs. Every change below is rolled back.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('test.failed_job_id', :'failed_job_id', true);
SELECT set_config('test.operator_id', :'operator_id', true);
DO $$
DECLARE j private.forecast_jobs%ROWTYPE; before_row jsonb; a jsonb; b jsonb;
 token uuid; failure text; operator_id bigint := current_setting('test.operator_id')::bigint;
BEGIN
 SELECT * INTO STRICT j FROM private.forecast_jobs WHERE id=current_setting('test.failed_job_id')::uuid;
 IF j.status<>'failed' THEN RAISE EXCEPTION 'Fixture must be terminal failed'; END IF;
 IF j.max_attempts<2 THEN RAISE EXCEPTION 'Retry fixture requires max_attempts >= 2'; END IF;
 before_row:=to_jsonb(j);
 EXECUTE 'SET LOCAL ROLE service_role';
 a:=public.recover_forecast_job_v1(j.location_id,j.id,gen_random_uuid(),operator_id,
 'publication_serialization_corrected',j.requested_implementation_digest);
 b:=public.recover_forecast_job_v1(j.location_id,j.id,gen_random_uuid(),operator_id,
 'publication_serialization_corrected',j.requested_implementation_digest);
 EXECUTE 'RESET ROLE';
 IF a->>'job_id' IS DISTINCT FROM b->>'job_id' OR b->>'duplicate' IS DISTINCT FROM 'true' THEN
  RAISE EXCEPTION 'Recovery was not idempotent'; END IF;
 IF before_row IS DISTINCT FROM (SELECT to_jsonb(q) FROM private.forecast_jobs q WHERE q.id=j.id) THEN
  RAISE EXCEPTION 'Original failure was modified'; END IF;
 IF (SELECT recovery_operator_id FROM private.forecast_jobs WHERE id=(a->>'job_id')::uuid) IS DISTINCT FROM operator_id THEN
  RAISE EXCEPTION 'Profile audit identity was not preserved'; END IF;
 IF (SELECT count(*) FROM private.forecast_jobs WHERE recovery_parent_id=j.id)<>1 THEN
  RAISE EXCEPTION 'Duplicate recovery'; END IF;
 BEGIN
  PERFORM public.recover_forecast_job_v1(j.location_id,j.id,NULL,operator_id,
   'publication_serialization_corrected',j.requested_implementation_digest);
  RAISE EXCEPTION 'Null approval accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN
  PERFORM public.recover_forecast_job_v1(j.location_id,j.id,gen_random_uuid(),NULL::bigint,
   'publication_serialization_corrected',j.requested_implementation_digest);
  RAISE EXCEPTION 'Null profile accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.recover_forecast_job_v1(j.location_id,j.id,gen_random_uuid(),operator_id,
   'publication_serialization_corrected',j.requested_implementation_digest);
  RAISE EXCEPTION 'Client role accepted';
 EXCEPTION WHEN insufficient_privilege THEN EXECUTE 'RESET ROLE'; END;
 b:=public.claim_forecast_job_v1('isolated-recovery-test',300,(a->>'job_id')::uuid);
 token:=(b->>'lease_token')::uuid;
 IF token IS NULL THEN RAISE EXCEPTION 'Recovery was not claimable'; END IF;
 IF public.claim_forecast_job_v1('other-worker',300,(a->>'job_id')::uuid) IS NOT NULL THEN
  RAISE EXCEPTION 'Job double claimed'; END IF;
 failure:=public.fail_forecast_job_v1((a->>'job_id')::uuid,token,'transient_network_failure',true,15);
 IF failure IS DISTINCT FROM 'retry_queued' THEN RAISE EXCEPTION 'Existing retry contract failed'; END IF;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
ROLLBACK;

-- Read-only installation checks (also safe on approved testing database).
SELECT p.proname,p.prosecdef,p.proowner::regrole,p.proconfig,
 has_function_privilege('anon',p.oid,'EXECUTE') AS anon_exec,
 has_function_privilege('authenticated',p.oid,'EXECUTE') AS client_exec,
 has_function_privilege('service_role',p.oid,'EXECUTE') AS server_exec
FROM pg_proc p WHERE p.oid='public.recover_forecast_job_v1(uuid,uuid,uuid,bigint,text,text)'::regprocedure;
