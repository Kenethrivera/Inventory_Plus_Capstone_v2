-- Stage 6B, forward-only. Approval required; do not run from application startup.
-- Uses the existing Stage 3 contribution extractor and Stage 5C allowlist.
-- No jobs, forecasts, sales or inventory changes are performed on installation.
BEGIN;
SET LOCAL lock_timeout = '10s';
-- Fail closed if the installed Stage 3 trigger/extractor contract has drifted.
DO $$
BEGIN
 IF to_regprocedure('private.forecast_order_demand_contributions_v1(uuid,text,jsonb,timestamp with time zone,timestamp with time zone)') IS NULL
  OR NOT EXISTS (SELECT 1 FROM pg_trigger
   WHERE tgrelid='public.order_history'::regclass AND NOT tgisinternal
    AND tgfoid=to_regprocedure('private.track_order_history_demand_revision_v1()')
    AND tgenabled IN ('O','A')) THEN
  RAISE EXCEPTION 'Installed demand contribution/trigger contract muast be verified before Stage 6B';
 END IF;
END $$;
ALTER TABLE private.forecast_input_revisions
 ADD COLUMN sales_event_revision bigint NOT NULL DEFAULT 0 CHECK (sales_event_revision>=0),
 ADD COLUMN initial_forecast_pending boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN private.forecast_input_revisions.sales_event_revision IS
 'Demand-changing order-row events since Stage 6B, including intraday sales. sales_revision remains the revision for inputs before today Manila midnight.';
CREATE INDEX forecast_initial_pending_idx ON private.forecast_input_revisions(location_id,product_id)
 WHERE initial_forecast_pending;

-- Retain the existing trigger and contribution comparison. Only demand before
-- the frozen midnight cutoff invalidates jobs/results. Date identity picks up
-- today's completed sales tomorrow; sales_event_revision still tracks every event.
CREATE OR REPLACE FUNCTION private.track_order_history_demand_revision_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,private,public AS $$
DECLARE
 old_location uuid; new_location uuid; old_status text; new_status text;
 old_items jsonb; new_items jsonb; old_completed timestamptz; new_completed timestamptz;
 old_returned timestamptz; new_returned timestamptz; changed record;
 business_today date := (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date;
 v_sales bigint; v_product bigint;
BEGIN
 IF TG_OP<>'INSERT' THEN
  old_location:=OLD.location_id; old_status:=OLD.status; old_items:=OLD.items;
  old_completed:=OLD.completed_at; old_returned:=OLD.returned_at;
 END IF;
 IF TG_OP<>'DELETE' THEN
  new_location:=NEW.location_id; new_status:=NEW.status; new_items:=NEW.items;
  new_completed:=NEW.completed_at; new_returned:=NEW.returned_at;
 END IF;
 IF TG_OP='UPDATE' AND ROW(old_location,old_status,old_items,old_completed,old_returned)
  IS NOT DISTINCT FROM ROW(new_location,new_status,new_items,new_completed,new_returned)
 THEN RETURN NEW; END IF;
 FOR changed IN
  WITH old_rows AS (
   SELECT * FROM private.forecast_order_demand_contributions_v1(old_location,old_status,old_items,old_completed,old_returned)
  ), new_rows AS (
   SELECT * FROM private.forecast_order_demand_contributions_v1(new_location,new_status,new_items,new_completed,new_returned)
  ), differences AS (
   SELECT coalesce(o.location_id,n.location_id) location_id,coalesce(o.product_id,n.product_id) product_id,
    coalesce(o.business_date < business_today,false) OR coalesce(n.business_date < business_today,false) affects_frozen_history
   FROM old_rows o FULL OUTER JOIN new_rows n ON n.location_id=o.location_id AND n.product_id=o.product_id
    AND n.business_date=o.business_date AND n.unit=o.unit
   WHERE o.total_quantity IS DISTINCT FROM n.total_quantity OR o.product_name IS DISTINCT FROM n.product_name
  )
  SELECT location_id,product_id,bool_or(affects_frozen_history) affects_frozen_history
  FROM differences WHERE location_id IS NOT NULL GROUP BY location_id,product_id
 LOOP
  INSERT INTO private.forecast_input_revisions AS target
   (location_id,product_id,sales_revision,product_revision,inventory_revision,configuration_revision,sales_event_revision,updated_at)
  SELECT p.location_id,p.id,CASE WHEN changed.affects_frozen_history THEN 1 ELSE 0 END,0,0,0,1,clock_timestamp()
  FROM public.products p WHERE p.id=changed.product_id AND p.location_id=changed.location_id
  ON CONFLICT (location_id,product_id) DO UPDATE SET
   sales_revision=target.sales_revision+EXCLUDED.sales_revision,
   sales_event_revision=target.sales_event_revision+1,updated_at=clock_timestamp()
  RETURNING sales_revision,product_revision INTO v_sales,v_product;
  IF FOUND AND changed.affects_frozen_history THEN
   UPDATE private.forecast_jobs j SET status='superseded',completed_at=clock_timestamp(),
    safe_error_code='demand_inputs_superseded',updated_at=clock_timestamp()
   WHERE j.location_id=changed.location_id AND j.product_id=changed.product_id AND j.status='queued'
    AND (j.sales_revision IS DISTINCT FROM v_sales OR j.product_revision IS DISTINCT FROM v_product);
  END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

-- Durable, lightweight discovery signal. No model, demand loading, or job creation
-- in a product transaction. Existing product-input revision trigger stays intact.
CREATE FUNCTION private.signal_initial_forecast_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NEW.location_id IS NOT NULL THEN
  INSERT INTO private.forecast_input_revisions(location_id,product_id)
  VALUES (NEW.location_id,NEW.id) ON CONFLICT(location_id,product_id) DO NOTHING;
  -- Serialize with enqueue/recovery before reading job existence. Computing
  -- NOT EXISTS in an upsert's VALUES could retain a pre-wait snapshot and
  -- restore pending=true after a concurrent enqueue already acknowledged it.
  PERFORM 1 FROM private.forecast_input_revisions r
   WHERE r.location_id=NEW.location_id AND r.product_id=NEW.id FOR UPDATE;
  UPDATE private.forecast_input_revisions r SET initial_forecast_pending=
   (NEW.is_active IS TRUE AND NOT EXISTS(
    SELECT 1 FROM private.forecast_jobs j WHERE j.location_id=NEW.location_id AND j.product_id=NEW.id))
   WHERE r.location_id=NEW.location_id AND r.product_id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER signal_initial_forecast_v1 AFTER INSERT OR UPDATE OF is_active,location_id,unit
 ON public.products FOR EACH ROW EXECUTE FUNCTION private.signal_initial_forecast_v1();

CREATE FUNCTION private.acknowledge_initial_forecast_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 UPDATE private.forecast_input_revisions SET initial_forecast_pending=false
 WHERE location_id=NEW.location_id AND product_id=NEW.product_id AND initial_forecast_pending;
 RETURN NEW;
END $$;
CREATE TRIGGER acknowledge_initial_forecast_v1 AFTER INSERT ON private.forecast_jobs
 FOR EACH ROW EXECUTE FUNCTION private.acknowledge_initial_forecast_v1();

CREATE FUNCTION public.forecast_initial_pending_page_v1(
 p_location_id uuid,p_business_date date,p_after uuid DEFAULT NULL,p_limit integer DEFAULT 10
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date
  OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 25 THEN
  RAISE EXCEPTION 'Invalid initial forecast page' USING ERRCODE='22023';
 END IF;
 WITH pending AS MATERIALIZED (
  SELECT p.id,p.location_id,p.product_name,p.sku,p.unit,p.created_at,r.sales_revision,r.product_revision,
   'missing'::text state,NULL::text safe_error_code
  FROM private.forecast_input_revisions r JOIN public.products p ON p.id=r.product_id AND p.location_id=r.location_id
  WHERE r.location_id=p_location_id AND r.initial_forecast_pending AND p.is_active IS TRUE
   AND nullif(btrim(p.unit),'') IS NOT NULL
 ), page AS (SELECT * FROM pending WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY id) FROM page),'[]'::jsonb),
  'coverage',jsonb_build_object('missing',(SELECT count(*) FROM pending)),
  'active_products',(SELECT count(*) FROM pending),
  'revision_fingerprint',clock_timestamp()::text) INTO result;
 -- Fingerprint is a cache invalidation token, not a fabricated forecast digest.
 -- Frozen-input SHA-256 still comes from the real historical dataset in Python.
 RETURN result;
END $$;

ALTER FUNCTION private.track_order_history_demand_revision_v1() OWNER TO postgres;
ALTER FUNCTION private.signal_initial_forecast_v1() OWNER TO postgres;
ALTER FUNCTION private.acknowledge_initial_forecast_v1() OWNER TO postgres;
ALTER FUNCTION public.forecast_initial_pending_page_v1(uuid,date,uuid,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.track_order_history_demand_revision_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION private.signal_initial_forecast_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION private.acknowledge_initial_forecast_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.forecast_initial_pending_page_v1(uuid,date,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.forecast_initial_pending_page_v1(uuid,date,uuid,integer) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
