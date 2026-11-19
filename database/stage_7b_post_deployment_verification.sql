-- Run only AFTER approval/installation. All verification transactions are read-only.
-- No fixtures, jobs, inventory writes, or result mutations.
BEGIN READ ONLY;
SELECT p.oid::regprocedure::text signature,pg_get_userbyid(p.proowner) owner,
 p.prosecdef security_definer,p.proconfig,
 has_function_privilege('service_role',p.oid,'EXECUTE') service_execute,
 has_function_privilege('anon',p.oid,'EXECUTE') anon_execute,
 has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_execute
FROM pg_proc p WHERE p.oid IN (
 'public.forecast_snapshot_page_v2(uuid,uuid,text,integer,integer,text,text,boolean,text,uuid)'::regprocedure,
 'public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid)'::regprocedure);
SELECT md5(pg_get_functiondef('public.forecast_snapshot_page_v1(uuid,uuid,text,integer,integer,text,text,boolean)'::regprocedure))
 = '043bac224858bec4faea7561196e3bc6' AS v1_snapshot_unchanged,
 md5(pg_get_functiondef('public.forecast_daily_demand_v1(text,timestamptz,timestamptz,text)'::regprocedure))
 = 'bb5c8679ebf2020194c35029a0ae3dc7' AS daily_demand_unchanged;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL ROLE service_role;
DO $check$
DECLARE c jsonb; p jsonb; model text;
BEGIN
 FOREACH model IN ARRAY ARRAY['blend','mean28','lightgbm','seasonal_experimental'] LOOP
  c:=public.forecast_history_coverage_v2('11111111-1111-1111-1111-111111111111',model,NULL,NULL,NULL,NULL);
  IF (c->>'total')::bigint IS DISTINCT FROM
     (c->>'no_sales')::bigint+(c->>'limited')::bigint+(c->>'sufficient')::bigint+(c->>'not_evaluated')::bigint
   OR ((c->>'sales_evidence_complete')::boolean IS NOT TRUE AND (c->>'no_sales')::bigint<>0) THEN
   RAISE EXCEPTION 'Coverage invariant failed: %',model;
  END IF;
  p:=public.forecast_snapshot_page_v2('11111111-1111-1111-1111-111111111111',NULL,model,1,25,NULL,NULL,false,NULL,NULL);
  IF jsonb_array_length(p->'items')>25 THEN RAISE EXCEPTION 'Page bound failed'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p->'items') item
    WHERE item #>> '{product,location_id}' IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
      OR (item->'snapshot' IS DISTINCT FROM 'null'::jsonb AND item #> '{snapshot,bundle}' IS DISTINCT FROM 'null'::jsonb))
   THEN RAISE EXCEPTION 'Scope/compactness invariant failed'; END IF;
  RAISE NOTICE 'Verified model %, coverage %',model,c;
 END LOOP;
 p:=public.forecast_snapshot_page_v2('00000000-0000-0000-0000-000000000000',NULL,'blend',1,25,NULL,NULL,false,NULL,NULL);
 IF (p->>'total_count')::integer<>0 THEN RAISE EXCEPTION 'Empty location leaked data'; END IF;
END;
$check$;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL ROLE anon;
DO $denial$
BEGIN
 BEGIN
  PERFORM public.forecast_history_coverage_v2('11111111-1111-1111-1111-111111111111','blend',NULL,NULL,NULL,NULL);
  RAISE EXCEPTION 'anon unexpectedly executed coverage';
 EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'anon coverage denied'; END;
 BEGIN
  PERFORM public.forecast_snapshot_page_v2('11111111-1111-1111-1111-111111111111',NULL,'blend',1,1,NULL,NULL,false,NULL,NULL);
  RAISE EXCEPTION 'anon unexpectedly executed page';
 EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'anon page denied'; END;
END;
$denial$;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL ROLE authenticated;
DO $denial$
BEGIN
 BEGIN
  PERFORM public.forecast_history_coverage_v2('11111111-1111-1111-1111-111111111111','blend',NULL,NULL,NULL,NULL);
  RAISE EXCEPTION 'authenticated unexpectedly executed coverage';
 EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'authenticated coverage denied'; END;
 BEGIN
  PERFORM public.forecast_snapshot_page_v2('11111111-1111-1111-1111-111111111111',NULL,'blend',1,1,NULL,NULL,false,NULL,NULL);
  RAISE EXCEPTION 'authenticated unexpectedly executed page';
 EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'authenticated page denied'; END;
END;
$denial$;
ROLLBACK;
