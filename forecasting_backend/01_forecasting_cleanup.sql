-- SPRJ Paint Center (BINAN-001), existing Supabase project. Manual execution.
-- Only early-stage SIM-FC-* sales in this store are removable. Existing store
-- sales, inventory, profiles, configurations, forecasts, and immutable evidence
-- for other products are preserved. A completed simulation cannot be reset.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('inventory-plus-forecast-simulation',0));

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.locations WHERE id='11111111-1111-1111-1111-111111111111'
                 AND store_key='BINAN-001' AND location_name='SPRJ Paint Center') THEN
    RAISE EXCEPTION 'BINAN-001 identity mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE sku LIKE 'SIM-FC-%'
             AND (location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
                  OR description IS DISTINCT FROM 'Synthetic forecast fixture')) THEN
    RAISE EXCEPTION 'SIM-FC SKU identity conflict';
  END IF;
END
$guard$;

CREATE TEMP TABLE sim_target_products ON COMMIT DROP AS
SELECT id FROM public.products WHERE location_id='11111111-1111-1111-1111-111111111111'
  AND sku LIKE 'SIM-FC-%' AND description='Synthetic forecast fixture';

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM public.forecast_recommendation_snapshots s
             JOIN sim_target_products p ON p.id=s.product_id_snapshot)
     OR EXISTS (SELECT 1 FROM public.approval_requests a
                JOIN sim_target_products p ON p.id=a.product_id)
     OR EXISTS (SELECT 1 FROM private.forecast_execution_results r
                JOIN sim_target_products p ON p.id=r.product_id)
     OR EXISTS (SELECT 1 FROM private.forecast_jobs j
                JOIN sim_target_products p ON p.id=j.product_id) THEN
    RAISE EXCEPTION 'SIM-FC forecast jobs, results, approvals, or immutable recommendations exist; preserve them';
  END IF;
  IF EXISTS (SELECT 1 FROM public.transaction_history t
             JOIN sim_target_products p ON p.id=t.product_id
             WHERE t.operation_scope IS DISTINCT FROM 'simulation_checkout') THEN
    RAISE EXCEPTION 'SIM-FC inventory has non-simulation movements';
  END IF;
END
$guard$;

CREATE TEMP TABLE sim_target_orders ON COMMIT DROP AS
SELECT o.id FROM public.orders o
WHERE o.location_id='11111111-1111-1111-1111-111111111111'
  AND o.completed_by_name='Forecast Simulation'
  AND o.status='completed'
  AND jsonb_typeof(o.items)='array'
  AND jsonb_array_length(o.items)=1
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(o.items) item
              JOIN sim_target_products p ON p.id::text=item->>'product_id');

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM public.orders o
             WHERE o.location_id='11111111-1111-1111-1111-111111111111'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(
                              CASE WHEN jsonb_typeof(o.items)='array' THEN o.items ELSE '[]'::jsonb END) item
                           JOIN sim_target_products p ON p.id::text=item->>'product_id')
               AND NOT EXISTS (SELECT 1 FROM sim_target_orders t WHERE t.id=o.id)) THEN
    RAISE EXCEPTION 'SIM-FC product appears in an unrelated order';
  END IF;
END
$guard$;

-- No FK references order_history or transaction_history in the live schema.
-- Delete history first because the orders trigger only synchronizes on INSERT/UPDATE.
DELETE FROM public.order_history h
USING sim_target_orders t
WHERE h.order_id = t.id::text;
DELETE FROM public.transaction_history h USING sim_target_products p
 WHERE h.product_id=p.id AND h.operation_scope='simulation_checkout';
DELETE FROM public.orders o USING sim_target_orders t WHERE o.id=t.id;

-- Product rows and replenishment settings are retained for an idempotent seed.
-- Demand revision tracking remains enabled; no private revisions are erased.
COMMIT;
