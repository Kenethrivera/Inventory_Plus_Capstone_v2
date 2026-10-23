CREATE OR REPLACE FUNCTION private.approval_request_json_v1 (
  p_request public.approval_requests
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
  select jsonb_build_object(
    'id', p_request.id,
    'location_id', p_request.location_id,
    'request_type', p_request.request_type,
    'status', p_request.status,
    'requested_by_id', p_request.requested_by_id,
    'requested_by_name', p_request.requested_by_name,
    'requested_by_role', p_request.requested_by_role,
    'requested_at', p_request.requested_at,
    'reviewed_by_id', p_request.reviewed_by_id,
    'reviewed_by_name', p_request.reviewed_by_name,
    'reviewed_at', p_request.reviewed_at,
    'product_id', p_request.product_id,
    'product_name', p_request.product_name,
    'product_sku', p_request.product_sku,
    'unit', p_request.unit,
    'requested_quantity', p_request.requested_quantity,
    'stock_at_request', p_request.stock_at_request,
    'current_stock', coalesce((
      select product.product_quantity
      from public.products product
      where product.id = p_request.product_id
        and product.location_id = p_request.location_id
    ), p_request.stock_at_request),
    'reason', p_request.reason,
    'note', p_request.note,
    'review_note', p_request.review_note,
    'transaction_id', p_request.transaction_id
  )
$function$;

REVOKE ALL ON FUNCTION "private"."approval_request_json_v1"(public.approval_requests) FROM PUBLIC;
