-- Deploy the period-scoped Analytics summary before the updated app.
BEGIN;

CREATE INDEX IF NOT EXISTS orders_analytics_period_idx ON public.orders USING btree (location_id, created_at DESC) INCLUDE (status, total_amount);
CREATE INDEX IF NOT EXISTS transaction_history_checkout_analytics_idx ON public.transaction_history USING btree (location_id, product_id, created_at DESC) INCLUDE (quantity_change) WHERE transaction_type = 'checkout';

CREATE OR REPLACE FUNCTION public.analytics_summary_v1(
  p_session_token text,
  p_period_start timestamp with time zone,
  p_period_end timestamp with time zone,
  p_previous_start timestamp with time zone,
  p_month_start timestamp with time zone
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_profile record;
  v_result jsonb;
BEGIN
  SELECT * INTO v_profile FROM private.require_app_session_v1(p_session_token);
  IF NOT FOUND OR v_profile.role <> 'admin' THEN
    RAISE EXCEPTION 'Analytics session is invalid or unauthorized';
  END IF;
  IF p_period_start IS NULL OR p_period_end <= p_period_start
     OR p_previous_start IS NULL OR p_previous_start >= p_period_start
     OR p_month_start IS NULL OR p_month_start > p_period_end THEN
    RAISE EXCEPTION 'Invalid analytics period';
  END IF;

  WITH scoped_orders AS (
    SELECT o.id, o.created_at, o.total_amount, o.items
    FROM public.orders o
    WHERE o.location_id = v_profile.location_id
      AND o.status IN ('completed', 'prepared', 'pending', 'solo_picking')
      AND o.created_at >= LEAST(p_previous_start, p_month_start)
      AND o.created_at < GREATEST(p_period_end, now() + interval '1 microsecond')
  ),
  order_totals AS (
    SELECT
      COALESCE(SUM(total_amount) FILTER (
        WHERE created_at >= p_period_start AND created_at < p_period_end), 0) AS revenue,
      COUNT(*) FILTER (WHERE created_at >= p_period_start
        AND created_at < p_period_end) AS order_count,
      COALESCE(SUM(total_amount) FILTER (
        WHERE created_at >= p_previous_start AND created_at < p_period_start), 0) AS previous_revenue
    FROM scoped_orders
  ),
  order_items AS (
    SELECT o.id AS order_id, o.created_at, o.total_amount, item.value AS item,
      NULLIF(COALESCE(item.value ->> 'product_id', item.value ->> 'productId'), '') AS product_id,
      COALESCE(NULLIF(item.value ->> 'quantity', '')::numeric, 0) AS quantity,
      COALESCE(
        NULLIF(item.value ->> 'line_total', '')::numeric,
        COALESCE(NULLIF(item.value ->> 'quantity', '')::numeric, 0) *
        COALESCE(NULLIF(item.value ->> 'unit_price', '')::numeric,
          NULLIF(item.value ->> 'price', '')::numeric, p.product_price, 0)
      ) AS line_amount
    FROM scoped_orders o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) item(value)
    LEFT JOIN public.products p
      ON p.id::text = COALESCE(item.value ->> 'product_id', item.value ->> 'productId')
      AND p.location_id = v_profile.location_id
    WHERE o.created_at >= p_period_start AND o.created_at < p_period_end
  ),
  priced_items AS (
    SELECT i.*, SUM(i.line_amount) OVER
      (PARTITION BY i.order_id) AS raw_amount,
      COUNT(*) OVER (PARTITION BY i.order_id) AS item_count
    FROM order_items i
  ),
  category_totals AS (
    SELECT COALESCE(NULLIF(TRIM(p.category), ''), 'Other') AS category,
      SUM(CASE WHEN i.raw_amount > 0
        THEN i.total_amount * i.line_amount / i.raw_amount
        ELSE i.total_amount / GREATEST(i.item_count, 1) END) AS amount
    FROM priced_items i
    LEFT JOIN public.products p ON p.id::text = i.product_id
      AND p.location_id = v_profile.location_id
    WHERE i.created_at >= p_period_start AND i.created_at < p_period_end
    GROUP BY 1
  ),
  monthly AS (
    SELECT date_trunc('month', created_at AT TIME ZONE 'Asia/Manila') AS month,
      SUM(total_amount) AS revenue
    FROM scoped_orders
    WHERE created_at >= p_month_start
    GROUP BY 1
  ),
  movement AS (
    SELECT t.product_id, MAX(t.created_at) AS last_sale,
      COALESCE(SUM(ABS(t.quantity_change)) FILTER (
        WHERE t.created_at >= now() - interval '28 days'), 0) AS sold_28_days
    FROM public.transaction_history t
    WHERE t.location_id = v_profile.location_id
      AND t.transaction_type = 'checkout'
    GROUP BY t.product_id
  )
  SELECT jsonb_build_object(
    'revenue', totals.revenue,
    'order_count', totals.order_count,
    'previous_revenue', totals.previous_revenue,
    'units_sold', COALESCE((SELECT SUM(quantity) FROM order_items
      WHERE created_at >= p_period_start AND created_at < p_period_end), 0),
    'categories', COALESCE((SELECT jsonb_object_agg(category, amount)
      FROM category_totals), '{}'::jsonb),
    'monthly', COALESCE((SELECT jsonb_object_agg(to_char(month, 'YYYY-MM'), revenue)
      FROM monthly), '{}'::jsonb),
    'stock', COALESCE((SELECT jsonb_object_agg(product_id::text,
      jsonb_build_object('sold_28_days', sold_28_days, 'last_sale', last_sale))
      FROM movement WHERE product_id IS NOT NULL), '{}'::jsonb)
  ) INTO v_result
  FROM order_totals totals;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.analytics_summary_v1(text, timestamp with time zone,
  timestamp with time zone, timestamp with time zone, timestamp with time zone)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_summary_v1(text, timestamp with time zone,
  timestamp with time zone, timestamp with time zone, timestamp with time zone)
  TO anon, service_role, postgres;

COMMIT;
