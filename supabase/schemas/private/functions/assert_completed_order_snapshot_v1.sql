CREATE OR REPLACE FUNCTION private.assert_completed_order_snapshot_v1()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
DECLARE
  v_item jsonb;
  v_product_id text;
  v_quantity text;
BEGIN
  IF lower(trim(coalesce(NEW.status, ''))) <> 'completed' THEN
    RETURN NEW;
  END IF;
  IF NEW.completed_at IS NULL THEN
    RAISE EXCEPTION 'completed_order_timestamp_required';
  END IF;
  IF jsonb_typeof(NEW.items) IS DISTINCT FROM 'array'
      OR jsonb_array_length(NEW.items) = 0 THEN
    RAISE EXCEPTION 'order_item_snapshot_invalid';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(NEW.items)
  LOOP
    v_product_id := coalesce(
      v_item ->> 'product_id', v_item ->> 'productId', '');
    v_quantity := coalesce(v_item ->> 'quantity', '');
    IF v_product_id
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        OR v_quantity !~ '^[0-9]+([.][0-9]+)?$' THEN
      RAISE EXCEPTION 'order_item_snapshot_invalid';
    END IF;
    IF v_quantity::numeric <= 0 THEN
      RAISE EXCEPTION 'order_item_snapshot_invalid';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.assert_completed_order_snapshot_v1()
  FROM PUBLIC, anon, authenticated, service_role;
