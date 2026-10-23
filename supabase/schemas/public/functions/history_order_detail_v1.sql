CREATE OR REPLACE FUNCTION public.history_order_detail_v1 (
  p_session_token text,
  p_order_id      text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_account_id text;
  v_role text;
  v_location_id uuid;
  v_order jsonb;
begin
  select session_profile.profile_id::text, session_profile.role,
      session_profile.location_id
    into v_account_id, v_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then raise exception 'History session is invalid or expired'; end if;

  select case
    when v_role = 'helper' then jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'assigned_helper_id', o.assigned_helper_id, 'assigned_at', o.assigned_at,
      'prepared_by_id', o.prepared_by_id, 'prepared_at', o.prepared_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity'
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    when v_role in ('staff', 'cashier') then jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'created_by_id', o.created_by_id,
      'assigned_helper_id', o.assigned_helper_id, 'assigned_at', o.assigned_at,
      'prepared_by_id', o.prepared_by_id, 'prepared_at', o.prepared_at,
      'completed_by_id', o.completed_by_id, 'completed_at', o.completed_at,
      'cancelled_by_id', o.cancelled_by_id, 'cancelled_at', o.cancelled_at,
      'returned_by_id', o.returned_by_id, 'returned_at', o.returned_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
          'product_name', coalesce(
            item ->> 'product_name', item ->> 'productName', 'Unknown'),
          'quantity', item -> 'quantity'
        ))
        from jsonb_array_elements(coalesce(o.items::jsonb, '[]'::jsonb)) item
      ), '[]'::jsonb)
    )
    else jsonb_build_object(
      'id', o.order_id, 'status', o.status, 'created_at', o.created_at,
      'total_amount', o.total_amount, 'discount_amount', o.discount_amount,
      'cash_given', o.cash_given, 'change_amount', o.change_amount,
      'payment_mode', o.payment_mode,
      'created_by_name', coalesce(o.created_by_name, (
        select name from public.profiles
        where id::text = o.created_by_id::text
      )),
      'prepared_by_name', coalesce(o.prepared_by_name, (
        select name from public.profiles
        where id::text = o.prepared_by_id::text
      )),
      'completed_by_name', coalesce(o.completed_by_name, (
        select name from public.profiles
        where id::text = o.completed_by_id::text
      )),
      'cancelled_by_name', coalesce(o.cancelled_by_name, (
        select name from public.profiles
        where id::text = o.cancelled_by_id::text
      )),
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
  end into v_order
  from public.order_history o
  where o.location_id = v_location_id and o.order_id = p_order_id and (
    v_role = 'admin'
    or (v_role = 'helper' and (
      o.assigned_helper_id = v_account_id
      or o.prepared_by_id = v_account_id))
    or (v_role in ('staff', 'cashier') and (
      o.created_by_id = v_account_id
      or o.completed_by_id = v_account_id
      or o.cancelled_by_id = v_account_id
      or o.returned_by_id = v_account_id))
  );
  return v_order;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."history_order_detail_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."history_order_detail_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."history_order_detail_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."history_order_detail_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."history_order_detail_v1"(text, text) FROM PUBLIC, "authenticated";
