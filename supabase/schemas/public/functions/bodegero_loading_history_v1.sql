CREATE OR REPLACE FUNCTION public.bodegero_loading_history_v1(
  p_session_token text,
  p_page integer DEFAULT 1,
  p_search text DEFAULT '',
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_actor record;
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_search text := lower(trim(coalesce(p_search, '')));
  v_total integer;
  v_records jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM private.require_app_session_v1(p_session_token);
  IF NOT FOUND OR v_actor.role <> 'bodegero' THEN
    RAISE EXCEPTION 'Bodegero session required' USING errcode = '42501';
  END IF;

  WITH scoped AS (
    SELECT proof.order_id, proof.truck_plate, proof.captured_at,
      orders.status, orders.items
    FROM public.order_loading_proofs proof
    JOIN public.orders orders ON orders.id = proof.order_id
    WHERE proof.location_id = v_actor.location_id
      AND orders.location_id = v_actor.location_id
      AND proof.bodegero_id = v_actor.profile_id
      AND (
        v_search = ''
        OR strpos(lower(proof.order_id::text), v_search) > 0
        OR strpos(lower(proof.truck_plate), v_search) > 0
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(coalesce(orders.items::jsonb, '[]'::jsonb)) item
          WHERE coalesce(item ->> 'requires_loading', 'false') = 'true'
            AND strpos(lower(coalesce(item ->> 'product_name', '')), v_search) > 0
        )
      )
  ), page_rows AS (
    SELECT * FROM scoped
    ORDER BY captured_at DESC, order_id DESC
    OFFSET (v_page::bigint - 1) * v_page_size LIMIT v_page_size
  )
  SELECT
    (SELECT count(*) FROM scoped),
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'order_id', row.order_id,
        'truck_plate', row.truck_plate,
        'captured_at', row.captured_at,
        'status', row.status,
        'items', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'product_name', coalesce(item ->> 'product_name', 'Unknown product'),
            'quantity', item -> 'quantity'
          ))
          FROM jsonb_array_elements(coalesce(row.items::jsonb, '[]'::jsonb)) item
          WHERE coalesce(item ->> 'requires_loading', 'false') = 'true'
        ), '[]'::jsonb)
      ) ORDER BY row.captured_at DESC, row.order_id DESC)
      FROM page_rows row
    ), '[]'::jsonb)
  INTO v_total, v_records;

  RETURN jsonb_build_object(
    'records', v_records,
    'total_count', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.bodegero_loading_history_v1(text, integer, text, integer)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.bodegero_loading_history_v1(text, integer, text, integer)
  TO anon, service_role;
