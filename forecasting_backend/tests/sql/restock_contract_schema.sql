-- ISOLATED EMPTY DATABASE ONLY. Minimal dependency contract, not a production migration.
DO $$ BEGIN
 IF to_regclass('public.transaction_history') IS NOT NULL OR to_regclass('private.forecast_jobs') IS NOT NULL
 THEN RAISE EXCEPTION 'Disposable empty database required'; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA private;
GRANT USAGE ON SCHEMA public TO anon,authenticated,service_role;
CREATE TABLE public.transaction_history(id uuid PRIMARY KEY,created_at timestamptz,product_id uuid,
 location_id uuid,transaction_type text,quantity_change numeric,new_quantity numeric);
CREATE TABLE public.approval_requests(id uuid PRIMARY KEY,transaction_id uuid,location_id uuid,product_id uuid,
 status text,request_type text,requested_quantity numeric,reviewed_at timestamptz,product_name text,product_sku text,unit text);
CREATE TABLE public.forecast_recommendation_snapshots(id bigint PRIMARY KEY,request_id uuid,location_id_snapshot uuid,
 product_id_snapshot uuid,inventory_unit_snapshot text,created_at timestamptz,forecast_period_start date,forecast_period_end date,
 predicted_demand numeric,available_inventory numeric,recommended_restock_quantity numeric,forecast_model text,
 forecast_version text,training_history_days integer,UNIQUE(location_id_snapshot,request_id));
CREATE TABLE private.forecast_jobs(id uuid PRIMARY KEY,location_id uuid,product_id uuid,status text,completed_at timestamptz);
CREATE TABLE private.forecast_execution_results(id uuid PRIMARY KEY,job_id uuid,location_id uuid,product_id uuid,
 created_at timestamptz,as_of_business_date date,requested_model_key text,horizon_days integer,inventory_unit text,output_bundle jsonb);
CREATE FUNCTION private.forecast_maintenance_scope_v1(p_location_id uuid) RETURNS void
 LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN
 IF p_location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'::uuid THEN
 RAISE EXCEPTION 'scope denied' USING ERRCODE='42501'; END IF; END $$;
CREATE FUNCTION private.require_app_session_v1(p_session_token text)
 RETURNS TABLE(profile_id bigint,role text,location_id uuid,profile_name text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT 1::bigint, CASE WHEN p_session_token='fixture-staff' THEN 'staff' ELSE 'admin' END,
 CASE WHEN p_session_token='fixture-other' THEN '22222222-2222-2222-2222-222222222222'::uuid
 ELSE '11111111-1111-1111-1111-111111111111'::uuid END,'Fixture Admin'::text
 WHERE p_session_token IN ('fixture-admin','fixture-staff','fixture-other'); $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
