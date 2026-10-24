CREATE OR REPLACE FUNCTION public.history_export_sales_v1 (
  p_session_token text,
  p_period_start  timestamp with time zone,
  p_period_end    timestamp with time zone
)
  RETURNS SETOF jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_role text;
  v_location_id uuid;
begin
  if p_period_start is null or p_period_end is null
    or p_period_end <= p_period_start then
    raise exception 'Invalid export period';
  end if;
  select session_profile.role, session_profile.location_id
    into v_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then raise exception 'History session is invalid or expired'; end if;
  if v_role <> 'admin' then
    raise exception 'Sales export is not allowed for this profile';
  end if;

  return query
    select jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'discount_amount', o.discount_amount,
      'cash_given', o.cash_given, 'change_amount', o.change_amount,
      'payment_mode', o.payment_mode,
      'payment_reference', (
        select current_order.payment_reference
        from public.orders current_order
        where current_order.id = o.order_id::uuid
      ),
      'created_by_name', o.created_by_name,
      'prepared_by_name', o.prepared_by_name,
      'completed_by_name', o.completed_by_name,
      'cancelled_by_name', o.cancelled_by_name,
      'prepared_at', o.prepared_at, 'completed_at', o.completed_at,
      'cancelled_at', o.cancelled_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity',
          'price', coalesce(item -> 'price', item -> 'unit_price')
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    from public.order_history o
    where o.location_id = v_location_id and lower(o.status) = 'completed'
      and coalesce(o.completed_at, o.prepared_at, o.created_at) >= p_period_start
      and coalesce(o.completed_at, o.prepared_at, o.created_at) < p_period_end
    order by coalesce(o.completed_at, o.prepared_at, o.created_at) desc,
      o.order_id desc;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."history_export_sales_v1"(text, timestamp WITH time zone, timestamp WITH time zone) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."history_export_sales_v1"(text, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."history_export_sales_v1"(text, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."history_export_sales_v1"(text, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."history_export_sales_v1"(text, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "authenticated";
