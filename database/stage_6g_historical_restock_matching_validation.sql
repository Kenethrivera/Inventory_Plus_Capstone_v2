-- ISOLATED ONLY. Run through tests/test_historical_restock_postgres.py, which
-- creates an empty disposable schema, installs the ONE migration, inserts fixtures,
-- runs these checks and rolls the whole transaction back. Never run on production.
DO $$
DECLARE b jsonb; points jsonb; evidence jsonb; altered jsonb;
BEGIN
 SELECT jsonb_agg(jsonb_build_object('date',date '2026-11-16'+n,
  'quantity','3.0','unit','pcs','metadata',jsonb_build_object(
  'is_cold_start',false,'cold_start_reason',NULL)) ORDER BY n)
 INTO points FROM generate_series(0,27) n;
 b := jsonb_build_object('schema_version',1,'outputs',jsonb_build_object(
  'preliminary_forecasts',jsonb_build_object('status','available','series',jsonb_build_array(
  jsonb_build_object('forecast_start_date','2026-11-16','forecast_end_date','2026-12-13',
  'producer',jsonb_build_object('key','lightgbm','model_name','LightGBM','version','1'),
  'input',jsonb_build_object('history_window_days',365),'points',points)))));
 evidence := private.historical_preliminary_evidence_v1(b,'2026-11-16','pcs',49-5);
 IF (evidence->>'predicted_demand')::numeric IS DISTINCT FROM 84
 OR (evidence->>'suggested_quantity')::numeric IS DISTINCT FROM 40
 OR evidence->>'forecast_model' IS DISTINCT FROM 'LightGBM'
 THEN RAISE EXCEPTION 'supporting-role calculation failed'; END IF;
 IF private.historical_preliminary_evidence_v1(b,'2026-11-17','pcs',44) IS NOT NULL
 OR private.historical_preliminary_evidence_v1(b,'2026-11-16','bag',44) IS NOT NULL
 OR private.historical_preliminary_evidence_v1(b,'2026-11-16','pcs',-1) IS NOT NULL
 OR private.historical_preliminary_evidence_v1(b,'2026-11-16','pcs',NULL) IS NOT NULL
 THEN RAISE EXCEPTION 'invalid scope or inventory accepted'; END IF;
 altered := jsonb_set(b,'{outputs,preliminary_forecasts,series,0,points,0,metadata,cold_start_reason}','"no_history"');
 IF private.historical_preliminary_evidence_v1(altered,'2026-11-16','pcs',44) IS NOT NULL
 THEN RAISE EXCEPTION 'no-history output accepted'; END IF;
 altered := jsonb_set(b,'{outputs,preliminary_forecasts,series,0,points,0,quantity}','"bad"');
 IF private.historical_preliminary_evidence_v1(altered,'2026-11-16','pcs',44) IS NOT NULL
 THEN RAISE EXCEPTION 'malformed quantity accepted'; END IF;
 altered := jsonb_set(b,'{outputs,preliminary_forecasts,series,0,points,0,metadata,is_cold_start}','true');
 IF private.historical_preliminary_evidence_v1(altered,'2026-11-16','pcs',44)->>'reliability'
 IS DISTINCT FROM 'provisional' THEN RAISE EXCEPTION 'provisional attribution lost'; END IF;
 IF (private.historical_preliminary_evidence_v1(b,'2026-11-16','pcs',100)->>'suggested_quantity')::numeric
 IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'legitimate zero not preserved'; END IF;
 RAISE NOTICE 'PASS: supporting series, stock before, dates, units, missing inventory, no-history, malformed values, provisional and zero';
END; $$;

DO $$ BEGIN
 IF has_function_privilege('anon','public.capture_restock_forecast_evidence_v1(uuid,uuid,integer)','EXECUTE')
 OR has_function_privilege('authenticated','public.capture_restock_forecast_evidence_v1(uuid,uuid,integer)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.capture_restock_forecast_evidence_v1(uuid,uuid,integer)','EXECUTE')
 OR has_table_privilege('service_role','private.restock_forecast_evidence','INSERT')
 THEN RAISE EXCEPTION 'capture permissions failed'; END IF;
 IF (SELECT provolatile FROM pg_proc WHERE oid='public.forecast_applied_restocks_v1(text,uuid)'::regprocedure)
 IS DISTINCT FROM 's' THEN RAISE EXCEPTION 'read RPC must be STABLE'; END IF;
END $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
 BEGIN
  PERFORM public.capture_restock_forecast_evidence_v1('11111111-1111-1111-1111-111111111111');
  RAISE EXCEPTION 'anon capture permitted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM public.forecast_applied_restocks_v1('expired','00000000-0000-4000-8000-000000000010');
  RAISE EXCEPTION 'invalid session permitted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM public.forecast_applied_restocks_v1('fixture-staff','00000000-0000-4000-8000-000000000010');
  RAISE EXCEPTION 'staff permitted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT FROM public.forecast_applied_restocks_v1('fixture-other','00000000-0000-4000-8000-000000000010'))
 THEN RAISE EXCEPTION 'cross-location disclosure'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$ DECLARE r jsonb; cursor_id uuid; pass integer; pages integer; first_captured integer := 0;
BEGIN
 BEGIN
  PERFORM public.capture_restock_forecast_evidence_v1('22222222-2222-2222-2222-222222222222');
  RAISE EXCEPTION 'cross-location capture permitted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 FOR pass IN 1..2 LOOP
  cursor_id := NULL; pages := 0;
  LOOP
   r := public.capture_restock_forecast_evidence_v1('11111111-1111-1111-1111-111111111111',cursor_id,2);
   IF pass=1 THEN first_captured := first_captured+(r->>'captured')::integer;
   ELSIF (r->>'captured')::integer<>0 THEN RAISE EXCEPTION 'repeat duplicated capture'; END IF;
   pages := pages+1;
   EXIT WHEN (r->>'done')::boolean;
   IF pages>10 THEN RAISE EXCEPTION 'cursor did not terminate'; END IF;
   cursor_id := (r->>'next_after')::uuid;
  END LOOP;
 END LOOP;
 IF first_captured<>2 THEN RAISE EXCEPTION 'expected exactly evidence-only and both-source captures'; END IF;
END $$;
RESET ROLE;
-- Isolated fixture only: ensure a real approval-linked snapshot wins even if evidence exists.
INSERT INTO public.forecast_recommendation_snapshots VALUES
 (2,'00000000-0000-4000-8000-000000000104','11111111-1111-1111-1111-111111111111','00000000-0000-4000-8000-000000000010',
 'pcs','2026-11-16 02:00:00+00','2026-11-16','2026-12-13',90,54,36,'Original snapshot','1',365);
SET LOCAL ROLE anon;
DO $$ DECLARE r jsonb; n integer := 0;
BEGIN
 FOR r IN SELECT * FROM public.forecast_applied_restocks_v1('fixture-admin','00000000-0000-4000-8000-000000000010') LOOP
  n := n+1;
  IF jsonb_typeof(r->'assumptions') IS DISTINCT FROM 'array'
   OR EXISTS(SELECT FROM jsonb_array_elements(r->'assumptions') a WHERE jsonb_typeof(a.value)<>'string')
  THEN RAISE EXCEPTION 'assumptions contains non-string payload'; END IF;
  CASE r->>'transaction_id'
   WHEN '00000000-0000-4000-8000-000000000101' THEN
    IF (r->>'predicted_demand')::numeric IS DISTINCT FROM 72.71923863537
     OR (r->>'available_inventory')::numeric IS DISTINCT FROM 44
     OR (r->>'suggested_quantity')::numeric IS DISTINCT FROM 29
     OR (r->>'signed_quantity_difference')::numeric IS DISTINCT FROM -24
     OR (r->>'absolute_difference')::numeric IS DISTINCT FROM 24
     OR r->>'recommendation_id' IS NOT NULL
     OR r->>'evidence_source' IS DISTINCT FROM 'historical_preliminary_match'
     OR r->>'forecast_model' IS DISTINCT FROM 'LightGBM'
     OR jsonb_typeof(r->'predicted_demand') IS DISTINCT FROM 'number'
    THEN RAISE EXCEPTION 'evidence top-level response failed'; END IF;
   WHEN '00000000-0000-4000-8000-000000000102' THEN
    IF r->>'suggested_quantity' IS NOT NULL OR r->>'predicted_demand' IS NOT NULL
     OR r->>'forecast_model' IS NOT NULL OR r->>'recommendation_id' IS NOT NULL
    THEN RAISE EXCEPTION 'earlier +10 incorrectly matched later forecast'; END IF;
   WHEN '00000000-0000-4000-8000-000000000103' THEN
    IF (r->>'suggested_quantity')::numeric IS DISTINCT FROM 31 OR r->>'recommendation_id' IS DISTINCT FROM '1'
    THEN RAISE EXCEPTION 'snapshot-only response failed'; END IF;
   WHEN '00000000-0000-4000-8000-000000000104' THEN
    IF (r->>'suggested_quantity')::numeric IS DISTINCT FROM 36 OR r->>'recommendation_id' IS DISTINCT FROM '2'
    THEN RAISE EXCEPTION 'snapshot precedence failed'; END IF;
   ELSE RAISE EXCEPTION 'unexpected transaction';
  END CASE;
 END LOOP;
 IF n<>4 THEN RAISE EXCEPTION 'duplicate/missing record or write-off included'; END IF;
END $$;
RESET ROLE;
DO $$ DECLARE e private.restock_forecast_evidence; n integer;
BEGIN
 SELECT * INTO STRICT e FROM private.restock_forecast_evidence WHERE transaction_id='00000000-0000-4000-8000-000000000101';
 IF e.result_id IS DISTINCT FROM '00000000-0000-4000-8000-000000000003'::uuid THEN RAISE EXCEPTION 'failed publication selected'; END IF;
 INSERT INTO private.restock_forecast_evidence SELECT (e).* ON CONFLICT (transaction_id) DO NOTHING;
 GET DIAGNOSTICS n = ROW_COUNT;
 IF n<>0 THEN RAISE EXCEPTION 'duplicate inserted'; END IF;
 BEGIN
  UPDATE private.restock_forecast_evidence SET payload='{}' WHERE transaction_id=e.transaction_id;
  RAISE EXCEPTION 'update allowed';
 EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
 BEGIN
  DELETE FROM private.restock_forecast_evidence WHERE transaction_id=e.transaction_id;
  RAISE EXCEPTION 'delete allowed';
 EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
 BEGIN
  TRUNCATE private.restock_forecast_evidence;
  RAISE EXCEPTION 'truncate allowed';
 EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
 IF (SELECT count(*) FROM private.restock_forecast_evidence)<>2 THEN RAISE EXCEPTION 'read or mutation changed evidence'; END IF;
END $$;
-- The harness forwards these ACTUAL RPC rows to the same Python/Dart contract checks.
SELECT jsonb_agg(value ORDER BY value->>'transaction_id') FROM
 public.forecast_applied_restocks_v1('fixture-admin','00000000-0000-4000-8000-000000000010') AS r(value);
