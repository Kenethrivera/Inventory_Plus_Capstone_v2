-- SINGLE FORWARD MIGRATION: run after deployed stage_6g_applied_restock_records.sql.
-- Neither historical matching draft has previously been installed. Review/approval required.
-- Background-only capture; Restock Records is a STABLE read-only RPC.
-- Default historical request identity: blend / 28 days / same Manila business date.
-- This reconstructs an estimate, not evidence that an Admin saw/approved that estimate.
-- No source-table writes, no backfill on installation, no job execution.
BEGIN;
CREATE TABLE private.restock_forecast_evidence (
 transaction_id uuid PRIMARY KEY,
 location_id uuid NOT NULL,
 product_id uuid NOT NULL,
 approval_id uuid NOT NULL,
 result_id uuid NOT NULL,
 transaction_at timestamptz NOT NULL,
 result_created_at timestamptz NOT NULL,
 stock_before numeric NOT NULL CHECK (stock_before >= 0),
 actual_stock_in numeric NOT NULL CHECK (actual_stock_in > 0),
 payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
 supporting_series jsonb NOT NULL,
 captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK (result_created_at < transaction_at)
);
-- No cascading foreign keys: evidence must survive operational/source cleanup.
ALTER TABLE private.restock_forecast_evidence OWNER TO postgres;
ALTER TABLE private.restock_forecast_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.restock_forecast_evidence FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION private.reject_restock_evidence_mutation_v1()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
 RAISE EXCEPTION 'Historical restock evidence is immutable' USING ERRCODE='55000';
END; $$;
ALTER FUNCTION private.reject_restock_evidence_mutation_v1() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.reject_restock_evidence_mutation_v1() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER restock_evidence_immutable BEFORE UPDATE OR DELETE
 ON private.restock_forecast_evidence FOR EACH ROW
 EXECUTE FUNCTION private.reject_restock_evidence_mutation_v1();
CREATE TRIGGER restock_evidence_no_truncate BEFORE TRUNCATE
 ON private.restock_forecast_evidence FOR EACH STATEMENT
 EXECUTE FUNCTION private.reject_restock_evidence_mutation_v1();

-- Validate the actual preliminary role, never substitute requested Blend values.
-- Malformed older bundles are ineligible; they do not break valid stock records.
CREATE FUNCTION private.historical_preliminary_evidence_v1(
 p_bundle jsonb, p_day date, p_unit text, p_stock numeric
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE s jsonb; point jsonb; q numeric; demand numeric := 0;
 n integer := 0; provisional boolean := false; suggested numeric;
BEGIN
 IF p_day IS NULL OR p_unit IS NULL OR p_stock IS NULL OR p_stock < 0
    OR p_stock::text IN ('NaN','Infinity','-Infinity')
    OR p_bundle->>'schema_version' IS DISTINCT FROM '1'
    OR p_bundle #>> '{outputs,preliminary_forecasts,status}' IS DISTINCT FROM 'available'
    OR jsonb_typeof(p_bundle #> '{outputs,preliminary_forecasts,series}') IS DISTINCT FROM 'array'
 THEN RETURN NULL; END IF;
 IF jsonb_array_length(p_bundle #> '{outputs,preliminary_forecasts,series}') <> 1 THEN RETURN NULL; END IF;
 s := p_bundle #> '{outputs,preliminary_forecasts,series,0}';
 IF (s->>'forecast_start_date')::date IS DISTINCT FROM p_day
    OR (s->>'forecast_end_date')::date IS DISTINCT FROM p_day+27
    OR jsonb_typeof(s->'points') IS DISTINCT FROM 'array'
    OR nullif(s #>> '{producer,key}','') IS NULL
    OR nullif(s #>> '{producer,model_name}','') IS NULL
    OR nullif(s #>> '{producer,version}','') IS NULL
    OR (s #>> '{input,history_window_days}')::integer <= 0
    OR (s #>> '{input,history_window_days}') IS NULL
 THEN RETURN NULL; END IF;
 IF jsonb_array_length(s->'points') <> 28 THEN RETURN NULL; END IF;
 FOR point IN SELECT value FROM jsonb_array_elements(s->'points') LOOP
  IF (point->>'date')::date IS DISTINCT FROM p_day+n
     OR lower(btrim(point->>'unit')) IS DISTINCT FROM lower(btrim(p_unit))
     OR jsonb_typeof(point->'quantity') NOT IN ('number','string')
     OR point->>'quantity' IS NULL
     OR jsonb_typeof(point->'metadata') IS DISTINCT FROM 'object'
     OR point #>> '{metadata,cold_start_reason}' = 'no_history'
     OR jsonb_typeof(point #> '{metadata,is_cold_start}') IS DISTINCT FROM 'boolean'
  THEN RETURN NULL; END IF;
  q := (point->>'quantity')::numeric;
  IF q < 0 OR q::text IN ('NaN','Infinity','-Infinity') THEN RETURN NULL; END IF;
  demand := demand+q;
  provisional := provisional OR (point #>> '{metadata,is_cold_start}')::boolean
                 OR point #>> '{metadata,cold_start_reason}' IS NOT NULL;
  n := n+1;
 END LOOP;
 suggested := greatest(0,ceil(demand-p_stock));
 RETURN jsonb_build_object(
  'forecast_period_start',p_day,'forecast_period_end',p_day+27,
  'predicted_demand',demand,'available_inventory',p_stock,'suggested_quantity',suggested,
  'forecast_model',s #>> '{producer,model_name}',
  'forecast_version',s #>> '{producer,version}',
  'training_history_days',(s #>> '{input,history_window_days}')::integer,
  'evidence_source','historical_preliminary_match',
  'reliability',CASE WHEN provisional THEN 'provisional' ELSE 'normal' END,
  'assumptions',jsonb_build_array(
   'Reconstructed from a saved preliminary forecast available before this stock-in; not an approval-linked suggestion.',
   'Stock before = recorded resulting stock minus the applied stock-in quantity.',
   CASE WHEN provisional THEN 'Limited-history supporting estimate; administrator review was required.'
   ELSE 'Supporting forecast had no recorded cold-start condition.' END));
EXCEPTION WHEN data_exception THEN RETURN NULL;
END; $$;
ALTER FUNCTION private.historical_preliminary_evidence_v1(jsonb,date,text,numeric) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.historical_preliminary_evidence_v1(jsonb,date,text,numeric)
 FROM PUBLIC,anon,authenticated,service_role;

-- Server-only bounded evidence capture. No model execution or inventory mutations.
CREATE FUNCTION public.capture_restock_forecast_evidence_v1(
 p_location_id uuid, p_after uuid DEFAULT NULL, p_limit integer DEFAULT 25
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_ids uuid[]; v_count integer; v_inserted integer;
BEGIN
 PERFORM private.forecast_maintenance_scope_v1(p_location_id);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN
  RAISE EXCEPTION 'Invalid capture batch size' USING ERRCODE='22023';
 END IF;
 -- Visit bounded transaction IDs, including unmatched records, so missing evidence
 -- cannot starve later transactions. Wrap the durable cursor after each full sweep.
 SELECT array_agg(q.id ORDER BY q.id) INTO v_ids FROM (
  SELECT t.id FROM public.transaction_history t
  WHERE t.location_id=p_location_id AND t.transaction_type='stock_in'
   AND t.quantity_change>0 AND (p_after IS NULL OR t.id>p_after)
  ORDER BY t.id LIMIT p_limit
 ) q;
 v_count := coalesce(cardinality(v_ids),0);
 -- Snapshot only valid evidence. A PK conflict keeps the first captured match unchanged.
 INSERT INTO private.restock_forecast_evidence (
  transaction_id,location_id,product_id,approval_id,result_id,transaction_at,
  result_created_at,stock_before,actual_stock_in,payload,supporting_series)
 SELECT t.id,t.location_id,t.product_id,a.id,r.id,t.created_at,r.created_at,
        t.new_quantity-t.quantity_change,t.quantity_change,
        r.evidence || jsonb_build_object('matched_result_id',r.id,
         'requested_model_key',r.requested_model_key,
         'matched_result_created_at',r.created_at,
         'publication_completed_at',r.publication_completed_at,
         'matched_received_quantity',t.quantity_change,
         'signed_quantity_difference',t.quantity_change-(r.evidence->>'suggested_quantity')::numeric,
         'absolute_difference',abs(t.quantity_change-(r.evidence->>'suggested_quantity')::numeric)),
        r.output_bundle #> '{outputs,preliminary_forecasts,series,0}'
 FROM public.transaction_history t
 JOIN LATERAL (
  SELECT a.* FROM public.approval_requests a
  WHERE a.transaction_id=t.id AND a.location_id=t.location_id AND a.product_id=t.product_id
   AND a.status='approved' AND a.request_type='restock' AND a.requested_quantity=t.quantity_change
  ORDER BY a.reviewed_at,a.id LIMIT 1
 ) a ON true
 JOIN LATERAL (
  SELECT er.*,published.completed_at AS publication_completed_at,ev.evidence
  FROM private.forecast_execution_results er
  JOIN private.forecast_jobs published ON published.id=er.job_id
   AND published.status='succeeded' AND published.completed_at<t.created_at
   AND published.location_id=er.location_id AND published.product_id=er.product_id
  CROSS JOIN LATERAL (SELECT private.historical_preliminary_evidence_v1(
    er.output_bundle,(t.created_at AT TIME ZONE 'Asia/Manila')::date,
    a.unit,t.new_quantity-t.quantity_change) AS evidence) ev
  WHERE er.product_id=t.product_id AND er.location_id=t.location_id
   AND er.created_at<t.created_at
   AND er.as_of_business_date=(t.created_at AT TIME ZONE 'Asia/Manila')::date
   AND er.requested_model_key='blend' AND er.horizon_days=28
   AND lower(btrim(er.inventory_unit))=lower(btrim(a.unit))
   AND ev.evidence IS NOT NULL
  ORDER BY er.created_at DESC,er.id DESC LIMIT 1
 ) r ON true
 WHERE t.location_id=p_location_id AND t.id=ANY(v_ids)
  AND t.transaction_type='stock_in' AND t.quantity_change>0
  AND t.new_quantity IS NOT NULL AND t.new_quantity-t.quantity_change>=0
  AND NOT EXISTS (SELECT 1 FROM private.restock_forecast_evidence e WHERE e.transaction_id=t.id)
  AND NOT EXISTS (SELECT 1 FROM public.forecast_recommendation_snapshots h
   WHERE h.request_id=a.id AND h.location_id_snapshot=t.location_id
    AND h.product_id_snapshot=t.product_id AND h.inventory_unit_snapshot=a.unit
    AND h.created_at<=t.created_at)
 ON CONFLICT (transaction_id) DO NOTHING;

 GET DIAGNOSTICS v_inserted = ROW_COUNT;
 RETURN jsonb_build_object('visited',v_count,'captured',v_inserted,
  'done',v_count<p_limit,'next_after',CASE WHEN v_count<p_limit THEN NULL ELSE v_ids[v_count] END);
END; $$;
ALTER FUNCTION public.capture_restock_forecast_evidence_v1(uuid,uuid,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.capture_restock_forecast_evidence_v1(uuid,uuid,integer)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.capture_restock_forecast_evidence_v1(uuid,uuid,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.forecast_applied_restocks_v1(p_session_token text, p_product_id uuid)
RETURNS SETOF jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE actor record;
BEGIN
 SELECT * INTO actor FROM private.require_app_session_v1(p_session_token);
 IF NOT FOUND OR actor.role IS DISTINCT FROM 'admin' OR actor.location_id IS NULL THEN
  RAISE EXCEPTION 'Admin session required' USING ERRCODE='42501';
 END IF;
 RETURN QUERY
 SELECT pg_catalog.jsonb_build_object(
  'transaction_id', t.id, 'recommendation_id', h.id,
  'product_id_snapshot', t.product_id, 'product_name_snapshot', a.product_name,
  'product_sku_snapshot', coalesce(a.product_sku,''), 'inventory_unit', a.unit,
  'recommendation_date', t.created_at,
  'forecast_period_start', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.forecast_period_start) ELSE e.payload->'forecast_period_start' END,
  'forecast_period_end', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.forecast_period_end) ELSE e.payload->'forecast_period_end' END,
  'predicted_demand', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.predicted_demand) ELSE e.payload->'predicted_demand' END,
  'available_inventory', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.available_inventory) ELSE e.payload->'available_inventory' END,
  'suggested_quantity', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.recommended_restock_quantity) ELSE e.payload->'suggested_quantity' END,
  'forecast_model', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.forecast_model) ELSE e.payload->'forecast_model' END,
  'forecast_version', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.forecast_version) ELSE e.payload->'forecast_version' END,
  'training_history_days', CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.training_history_days) ELSE e.payload->'training_history_days' END,
  'signed_quantity_difference', CASE WHEN h.id IS NOT NULL THEN to_jsonb(t.quantity_change-h.recommended_restock_quantity) ELSE e.payload->'signed_quantity_difference' END,
  'absolute_difference', CASE WHEN h.id IS NOT NULL THEN to_jsonb(abs(t.quantity_change-h.recommended_restock_quantity)) ELSE e.payload->'absolute_difference' END,
  'reliability', CASE WHEN h.id IS NULL THEN e.payload->'reliability' ELSE NULL END,
  'evidence_source', CASE WHEN h.id IS NOT NULL THEN 'approval_snapshot'
                         WHEN e.transaction_id IS NOT NULL THEN 'historical_preliminary_match' ELSE NULL END,
  'matched_result_id', CASE WHEN h.id IS NULL THEN e.result_id ELSE NULL END,
  'evaluation_status', 'applied', 'matched_received_quantity', t.quantity_change,
  'first_receipt_date', t.created_at, 'last_receipt_date', t.created_at, 'receipt_count', 1,
  -- Keep the array separate from the object. Never concatenate payload into assumptions.
  'assumptions', CASE
   WHEN h.id IS NOT NULL THEN jsonb_build_array('Suggestion from the original saved approval snapshot.')
   WHEN e.transaction_id IS NOT NULL THEN jsonb_build_array(
    'Reconstructed historical estimate from a saved preliminary forecast published before stock-in; not an approval-linked suggestion.',
    'Stock before = recorded resulting stock minus the applied stock-in quantity.',
    CASE WHEN e.payload->>'reliability'='provisional'
      THEN 'Limited-history supporting estimate; needs administrator review.'
      ELSE 'Historical supporting forecast and inventory evidence; not a procurement approval.' END)
   ELSE jsonb_build_array('Approved and applied inventory transaction; historical suggestion not recorded.')
  END)

 FROM public.transaction_history t
 JOIN LATERAL (
  SELECT r.* FROM public.approval_requests r
  WHERE r.transaction_id=t.id AND r.location_id=t.location_id
   AND r.product_id=t.product_id AND r.status='approved' AND r.request_type='restock'
   AND r.requested_quantity=t.quantity_change
  ORDER BY r.reviewed_at,r.id LIMIT 1
 ) a ON true
 LEFT JOIN private.restock_forecast_evidence e
  ON e.transaction_id=t.id AND e.location_id=t.location_id AND e.product_id=t.product_id
 LEFT JOIN public.forecast_recommendation_snapshots h
  ON h.request_id=a.id AND h.location_id_snapshot=t.location_id
  AND h.product_id_snapshot=t.product_id AND h.inventory_unit_snapshot=a.unit
  AND h.created_at<=t.created_at
 WHERE t.location_id=actor.location_id AND t.product_id=p_product_id
  AND t.transaction_type='stock_in' AND t.quantity_change>0 AND t.new_quantity IS NOT NULL
 ORDER BY t.created_at DESC,t.id DESC;
END; $$;
ALTER FUNCTION public.forecast_applied_restocks_v1(text,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.forecast_applied_restocks_v1(text,uuid) FROM PUBLIC,anon,authenticated;
-- App sessions are independently checked inside the RPC, matching existing opaque-session RPCs.
GRANT EXECUTE ON FUNCTION public.forecast_applied_restocks_v1(text,uuid) TO anon,service_role;
COMMIT;
