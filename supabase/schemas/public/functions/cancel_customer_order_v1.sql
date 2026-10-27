CREATE OR REPLACE FUNCTION public.cancel_customer_order_v1 (
  p_session_token text,
  p_order_id      uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_order public.orders;
  v_item record;
  v_new_quantity numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Cancellation session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot cancel orders';
  end if;

  select customer_order.* into v_order
  from public.orders customer_order
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
  for update;
  if not found then raise exception 'order_cannot_be_cancelled'; end if;

  if v_order.status = 'cancelled' then
    return jsonb_build_object('order', to_jsonb(v_order), 'reused', true);
  end if;
  if v_order.status = 'completed' then
    raise exception 'order_cannot_be_cancelled';
  end if;
  if v_order.status not in ('pending', 'prepared', 'solo_picking') then
    raise exception 'order_cannot_be_cancelled';
  end if;

  perform product.id
  from public.products product
  join (
    select (entry.value ->> 'product_id')::uuid as product_id
    from jsonb_array_elements(v_order.items) entry
    group by (entry.value ->> 'product_id')::uuid
  ) requested on requested.product_id = product.id
  where product.location_id = v_profile.location_id
  order by product.id
  for update of product;

  for v_item in
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      sum((entry.value ->> 'quantity')::numeric) as quantity
    from jsonb_array_elements(v_order.items) entry
    group by (entry.value ->> 'product_id')::uuid
    order by (entry.value ->> 'product_id')::uuid
  loop
    update public.products product
    set product_quantity = product.product_quantity + v_item.quantity
    where product.id = v_item.product_id
      and product.location_id = v_profile.location_id
    returning product.product_quantity into v_new_quantity;
    if not found then raise exception 'inventory_changed'; end if;

    insert into public.transaction_history (
      product_id, transaction_type, quantity_change, new_quantity,
      location_id, user_id, user_name, operation_id
    ) values (
      v_item.product_id, 'order_cancelled', v_item.quantity, v_new_quantity,
      v_profile.location_id, v_profile.profile_id, v_profile.profile_name,
      'cancel:' || v_order.id::text
    );
  end loop;

  update public.orders customer_order
  set status = 'cancelled',
      cancelled_by_id = v_profile.profile_id::text,
      cancelled_by_name = v_profile.profile_name,
      cancelled_at = now()
  where customer_order.id = v_order.id
  returning customer_order.* into v_order;

  return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."cancel_customer_order_v1"(text, uuid) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."cancel_customer_order_v1"(text, uuid) TO "service_role";

REVOKE ALL ON FUNCTION "public"."cancel_customer_order_v1"(text, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."cancel_customer_order_v1"(text, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "public"."cancel_customer_order_v1"(text, uuid) FROM PUBLIC, "authenticated";
