-- Persist verified helper picks on the order so all store sessions receive
-- progress through the existing orders realtime publication.
CREATE OR REPLACE FUNCTION public.mark_order_item_picked_v1(
  p_session_token text,
  p_order_id uuid,
  p_product_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_profile record;
  v_order public.orders%rowtype;
  v_product_id text := nullif(trim(coalesce(p_product_id, '')), '');
  v_item jsonb;
  v_updated_items jsonb;
BEGIN
  SELECT * INTO v_profile
  FROM private.require_app_session_v1(p_session_token);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Picking session is invalid or expired';
  END IF;
  IF v_profile.role <> 'helper' OR v_product_id IS NULL THEN
    RAISE EXCEPTION 'order_picking_not_allowed';
  END IF;

  SELECT * INTO v_order
  FROM public.orders customer_order
  WHERE customer_order.id = p_order_id
    AND customer_order.location_id = v_profile.location_id
    AND customer_order.status = 'pending'
    AND customer_order.assigned_helper_id = v_profile.profile_id::text
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_picking_conflict';
  END IF;

  SELECT entry.item INTO v_item
  FROM jsonb_array_elements(v_order.items) AS entry(item)
  WHERE coalesce(entry.item->>'product_id', entry.item->>'productId') = v_product_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_item_not_found';
  END IF;
  IF v_item->>'picked' = 'true' THEN
    RETURN to_jsonb(v_order);
  END IF;

  SELECT jsonb_agg(
    CASE
      WHEN coalesce(entry.item->>'product_id', entry.item->>'productId') = v_product_id
        THEN entry.item || jsonb_build_object('picked', true)
      ELSE entry.item
    END ORDER BY entry.position
  ) INTO v_updated_items
  FROM jsonb_array_elements(v_order.items) WITH ORDINALITY AS entry(item, position);

  UPDATE public.orders customer_order
  SET items = v_updated_items,
      updated_at = now()
  WHERE customer_order.id = p_order_id
  RETURNING customer_order.* INTO v_order;

  RETURN to_jsonb(v_order);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_order_item_picked_v1(text, uuid, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.mark_order_item_picked_v1(text, uuid, text)
  FROM PUBLIC, authenticated;
