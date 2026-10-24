CREATE OR REPLACE FUNCTION public.create_customer_order_v1 (
  p_session_token                text,
  p_items                        jsonb,
  p_total_amount                 numeric,
  p_discount_amount              numeric,
  p_discount_mode                text,
  p_discount_value               numeric,
  p_discount_reason              text,
  p_checkout_token               text,
  p_discount_approval_request_id uuid,
  p_solo_handled                 boolean,
  p_assigned_helper_id           text,
  p_assigned_helper_name         text,
  p_assigned_at                  timestamp with time zone,
  p_assigned_by_admin_id         text,
  p_assigned_by_admin_name       text,
  p_payment_mode                 text,
  p_cash_given                   double precision,
  p_change_amount                double precision
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_snapshot record;
  v_request public.approval_requests;
  v_order public.orders;
  v_limit numeric;
  v_requires_approval boolean;
  v_expected_total numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Checkout session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot create orders';
  end if;

  select * into v_snapshot
  from private.discount_cart_snapshot_v1(
    v_profile.location_id, p_items, p_discount_mode, p_discount_value,
    p_discount_reason, p_checkout_token
  );
  v_expected_total := v_snapshot.subtotal_amount - v_snapshot.discount_amount;
  if abs(round(coalesce(p_discount_amount, 0), 2)
      - v_snapshot.discount_amount) > 0.01
      or abs(round(coalesce(p_total_amount, 0), 2)
      - v_expected_total) > 0.01 then
    raise exception 'Cart pricing changed. Review the discount and try again';
  end if;

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10)
    into v_limit
  from public.store_settings settings
  where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
  v_requires_approval := v_profile.role <> 'admin'
    and v_snapshot.effective_percentage > v_limit;

  if v_requires_approval then
    if p_discount_approval_request_id is null then
      raise exception 'Admin approval is required for this discount';
    end if;
    select request.* into v_request
    from public.approval_requests request
    where request.id = p_discount_approval_request_id
    for update;
    if not found
        or v_request.request_type <> 'discount'
        or v_request.status <> 'approved'
        or v_request.location_id <> v_profile.location_id
        or v_request.requested_by_id <> v_profile.profile_id
        or v_request.used_at is not null
        or v_request.checkout_token <> trim(p_checkout_token)
        or v_request.cart_fingerprint <> v_snapshot.cart_fingerprint
        or v_request.discount_mode <> lower(trim(p_discount_mode))
        or v_request.discount_value <> p_discount_value
        or v_request.discount_amount <> v_snapshot.discount_amount
        or v_request.subtotal_amount <> v_snapshot.subtotal_amount
        or coalesce(trim(v_request.reason), '') <>
          coalesce(trim(p_discount_reason), '') then
      raise exception 'Discount approval does not match the current checkout';
    end if;
  end if;

  insert into public.orders (
    location_id, status, total_amount, discount_amount, payment_mode,
    cash_given, change_amount, items, created_by, created_by_id,
    created_by_name, assigned_helper_id, assigned_helper_name, assigned_at,
    assigned_by_admin_id, assigned_by_admin_name,
    discount_approval_request_id
  ) values (
    v_profile.location_id,
    case when coalesce(p_solo_handled, false)
      then 'solo_picking' else 'pending' end,
    v_expected_total, v_snapshot.discount_amount,
    coalesce(nullif(trim(p_payment_mode), ''), 'Cash'),
    p_cash_given, p_change_amount, v_snapshot.normalized_items,
    v_profile.profile_id, v_profile.profile_id::text,
    v_profile.profile_name,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_helper_name end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_at end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_id end,
    case when coalesce(p_solo_handled, false) then null
      else p_assigned_by_admin_name end,
    case when v_requires_approval then p_discount_approval_request_id
      else null end
  ) returning * into v_order;

  if v_requires_approval then
    update public.approval_requests
    set used_at = now(), used_order_id = v_order.id
    where id = v_request.id;
  end if;

  return to_jsonb(v_order);
end;
$function$;

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v1"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "anon";

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v1"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "service_role";

REVOKE ALL
  ON FUNCTION "public"."create_customer_order_v1"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  FROM "postgres";

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v1"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "postgres";

REVOKE ALL
  ON FUNCTION "public"."create_customer_order_v1"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  FROM PUBLIC, "authenticated";
