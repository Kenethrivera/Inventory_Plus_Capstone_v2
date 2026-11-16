-- Isolated fixtures only. Values use the user-verified Claw Hammer arithmetic.
INSERT INTO private.forecast_jobs VALUES
 ('00000000-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','00000000-0000-4000-8000-000000000010','succeeded','2026-11-16 02:00:00+00'),
 ('00000000-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','00000000-0000-4000-8000-000000000010','failed','2026-11-16 02:30:00+00');
INSERT INTO private.forecast_execution_results
SELECT '00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000001',
 '11111111-1111-1111-1111-111111111111','00000000-0000-4000-8000-000000000010',
 '2026-11-16 01:59:59+00','2026-11-16','blend',28,'pcs',
 jsonb_build_object('schema_version',1,'outputs',jsonb_build_object('preliminary_forecasts',
 jsonb_build_object('status','available','series',jsonb_build_array(jsonb_build_object(
 'forecast_start_date','2026-11-16','forecast_end_date','2026-12-13',
 'producer',jsonb_build_object('key','lightgbm','model_name','LightGBM','version','1'),
 'input',jsonb_build_object('history_window_days',365),
 'points',(SELECT jsonb_agg(jsonb_build_object('date',date '2026-11-16'+n,'quantity',
 CASE WHEN n=27 THEN 72.71923863537-27*2.5 ELSE 2.5 END,'unit','pcs',
 'metadata',jsonb_build_object('is_cold_start',false,'cold_start_reason',NULL)) ORDER BY n)
 FROM generate_series(0,27)n))))));
-- Newer failed and future publications must not replace the earlier valid source.
INSERT INTO private.forecast_execution_results
SELECT '00000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000002',
 location_id,product_id,'2026-11-16 02:30:00+00',as_of_business_date,requested_model_key,horizon_days,inventory_unit,output_bundle
FROM private.forecast_execution_results WHERE id='00000000-0000-4000-8000-000000000003';
INSERT INTO public.transaction_history VALUES
 ('00000000-0000-4000-8000-000000000101','2026-11-16 03:00:00+00','00000000-0000-4000-8000-000000000010','11111111-1111-1111-1111-111111111111','stock_in',5,49),
 ('00000000-0000-4000-8000-000000000102','2026-11-16 00:00:00+00','00000000-0000-4000-8000-000000000010','11111111-1111-1111-1111-111111111111','stock_in',10,44),
 ('00000000-0000-4000-8000-000000000103','2026-11-16 03:01:00+00','00000000-0000-4000-8000-000000000010','11111111-1111-1111-1111-111111111111','stock_in',5,54),
 ('00000000-0000-4000-8000-000000000104','2026-11-16 03:02:00+00','00000000-0000-4000-8000-000000000010','11111111-1111-1111-1111-111111111111','stock_in',5,59),
 ('00000000-0000-4000-8000-000000000105','2026-11-16 03:03:00+00','00000000-0000-4000-8000-000000000010','11111111-1111-1111-1111-111111111111','write_off',-1,58);
INSERT INTO public.approval_requests
SELECT t.id,t.id,t.location_id,t.product_id,'approved',CASE WHEN t.quantity_change>0 THEN 'restock' ELSE 'write_off' END,
 abs(t.quantity_change),t.created_at,'Fixture Hammer','', 'pcs' FROM public.transaction_history t;
-- Snapshot-only case; the both-sources snapshot will be inserted after capture.
INSERT INTO public.forecast_recommendation_snapshots VALUES
 (1,'00000000-0000-4000-8000-000000000103','11111111-1111-1111-1111-111111111111','00000000-0000-4000-8000-000000000010',
 'pcs','2026-11-16 02:00:00+00','2026-11-16','2026-12-13',80,49,31,'Original snapshot','1',365);
