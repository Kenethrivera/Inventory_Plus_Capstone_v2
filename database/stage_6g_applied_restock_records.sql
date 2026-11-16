-- REVIEW ONLY. Additive read RPC; no inventory/history mutation.
-- All application relations/functions are qualified; no writable schema is searched.
-- CREATE intentionally fails if already installed: review rather than silently replace.
BEGIN;
CREATE FUNCTION public.forecast_applied_restocks_v1(p_session_token text, p_product_id uuid)
RETURNS SETOF jsonb LANGUAGE plpgsql SECURITY DEFINER
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
  'forecast_period_start', h.forecast_period_start, 'forecast_period_end', h.forecast_period_end,
  'predicted_demand', h.predicted_demand, 'available_inventory', h.available_inventory, 'suggested_quantity', h.recommended_restock_quantity,
  'evaluation_status', 'applied', 'matched_received_quantity', t.quantity_change,
  'first_receipt_date', t.created_at, 'last_receipt_date', t.created_at, 'receipt_count', 1,
  'forecast_model', coalesce(h.forecast_model,'Not recorded'), 'forecast_version', coalesce(h.forecast_version,''), 'training_history_days', h.training_history_days,
  'assumptions', pg_catalog.jsonb_build_array(CASE WHEN h.id IS NULL THEN 'Approved and applied inventory transaction; historical suggestion not recorded.' ELSE 'Approved and applied inventory transaction; suggestion from the original saved approval snapshot.' END))
 FROM public.transaction_history t
 JOIN LATERAL (
  SELECT r.* FROM public.approval_requests r
  WHERE r.transaction_id=t.id AND r.location_id=t.location_id
   AND r.product_id=t.product_id AND r.status='approved' AND r.request_type='restock'
   AND r.requested_quantity=t.quantity_change
  ORDER BY r.reviewed_at,r.id LIMIT 1
 ) a ON true
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
