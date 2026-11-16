-- Remove individual cashier discount limits while preserving existing RPC signatures.
-- Apply this migration to existing databases after deploying the app update.
BEGIN;
CREATE OR REPLACE FUNCTION public.create_customer_order_v2 (
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
  v_item record;
  v_new_quantity numeric;
  v_limit numeric;
  v_max_approved numeric;
  v_gcash_enabled boolean;
  v_requires_approval boolean;
  v_expected_total numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Checkout session is invalid or expired'; end if;
  if v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'This account cannot create orders';
  end if;
  if length(trim(coalesce(p_checkout_token, ''))) < 16 then
    raise exception 'checkout_operation_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'checkout:' || trim(p_checkout_token),
    0
  ));
  select customer_order.* into v_order
  from public.orders customer_order
  where customer_order.checkout_operation_id = trim(p_checkout_token);
  if found then
    if v_order.location_id is distinct from v_profile.location_id
        or v_order.created_by is distinct from v_profile.profile_id then
      raise exception 'checkout_operation_conflict';
    end if;
    return to_jsonb(v_order);
  end if;

  perform product.id
  from public.products product
  join (
    select distinct (entry.value ->> 'product_id')::uuid as product_id
    from jsonb_array_elements(p_items) entry
  ) requested on requested.product_id = product.id
  where product.location_id = v_profile.location_id
  order by product.id
  for update of product;

  begin
    select * into v_snapshot
    from private.discount_cart_snapshot_v1(
      v_profile.location_id, p_items, p_discount_mode, p_discount_value,
      p_discount_reason, p_checkout_token
    );
  exception when others then
    if sqlerrm = 'A cart item is unavailable or exceeds current stock' then
      raise exception 'checkout_inventory_changed';
    end if;
    raise;
  end;

  v_expected_total := v_snapshot.subtotal_amount - v_snapshot.discount_amount;
  if abs(round(coalesce(p_discount_amount, 0), 2)
      - v_snapshot.discount_amount) > 0.01
      or abs(round(coalesce(p_total_amount, 0), 2)
      - v_expected_total) > 0.01 then
    raise exception 'Cart pricing changed. Review the discount and try again';
  end if;

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10),
         coalesce(settings.max_approved_discount_pct, 25),
         coalesce(settings.gcash_enabled, true)
    into v_limit, v_max_approved, v_gcash_enabled
    from public.store_settings settings
   where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
  v_max_approved := coalesce(v_max_approved, 25);
  v_gcash_enabled := coalesce(v_gcash_enabled, true);
  if lower(trim(coalesce(p_payment_mode, ''))) = 'gcash'
      and not v_gcash_enabled then
    raise exception 'GCash payments are disabled for this store';
  end if;
  if v_profile.role <> 'admin'
      and v_snapshot.effective_percentage > v_max_approved then
    raise exception 'Discount exceeds the store maximum';
  end if;
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
    discount_approval_request_id, checkout_operation_id
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
      else null end,
    trim(p_checkout_token)
  ) returning * into v_order;

  for v_item in
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(v_snapshot.normalized_items) entry
    order by (entry.value ->> 'product_id')::uuid
  loop
    update public.products product
    set product_quantity = product.product_quantity - v_item.quantity
    where product.id = v_item.product_id
      and product.location_id = v_profile.location_id
    returning product.product_quantity into v_new_quantity;
    if not found then raise exception 'checkout_inventory_changed'; end if;

    insert into public.transaction_history (
      product_id, transaction_type, quantity_change, new_quantity,
      location_id, user_id, user_name, operation_id, operation_scope
    ) values (
      v_item.product_id, 'checkout', -v_item.quantity, v_new_quantity,
      v_profile.location_id, v_profile.profile_id, v_profile.profile_name,
      trim(p_checkout_token), 'checkout'
    );
  end loop;

  if v_requires_approval then
    update public.approval_requests
    set used_at = now(), used_order_id = v_order.id
    where id = v_request.id;
  end if;

  return to_jsonb(v_order);
end;
$function$;

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v2"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "anon";

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v2"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "service_role";

REVOKE ALL
  ON FUNCTION "public"."create_customer_order_v2"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  FROM "postgres";

GRANT EXECUTE
  ON FUNCTION "public"."create_customer_order_v2"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  TO "postgres";

REVOKE ALL
  ON FUNCTION "public"."create_customer_order_v2"(text, jsonb, numeric, numeric, text, numeric, text, text, uuid, boolean, text, text, timestamp
    WITH time zone, text, text, text, double precision, double precision)
  FROM PUBLIC, "authenticated";

CREATE OR REPLACE FUNCTION public.create_discount_approval_request_v1 (
  p_session_token  text,
  p_items          jsonb,
  p_discount_mode  text,
  p_discount_value numeric,
  p_reason         text,
  p_checkout_token text
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
  v_limit numeric;
  v_max_approved numeric;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;
  if v_profile.role not in ('staff', 'cashier') then
    raise exception 'Only Cashier accounts may request discount approval';
  end if;
  if v_reason is null then
    raise exception 'A reason is required for discount approval';
  end if;

  select * into v_snapshot
  from private.discount_cart_snapshot_v1(
    v_profile.location_id, p_items, p_discount_mode, p_discount_value,
    p_checkout_token
  );

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10),
         coalesce(settings.max_approved_discount_pct, 25)
    into v_limit, v_max_approved
    from public.store_settings settings
   where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
  v_max_approved := coalesce(v_max_approved, 25);
  if v_snapshot.effective_percentage > v_max_approved then
    raise exception 'Discount exceeds the store maximum';
  end if;
  if v_snapshot.effective_percentage <= v_limit then
    raise exception 'This discount is within the Cashier auto-approved limit';
  end if;

  select request.* into v_request
  from public.approval_requests request
  where request.location_id = v_profile.location_id
    and request.requested_by_id = v_profile.profile_id
    and request.request_type = 'discount'
    and request.checkout_token = trim(p_checkout_token)
    and request.cart_fingerprint = v_snapshot.cart_fingerprint
    and request.status in ('pending', 'approved')
    and request.used_at is null
  order by request.requested_at desc
  limit 1;

  if found then return private.approval_request_json_v1(v_request); end if;

  insert into public.approval_requests (
    location_id, request_type, requested_by_id, requested_by_name,
    requested_by_role, reason, discount_mode, discount_value,
    discount_amount, discount_effective_percentage, subtotal_amount,
    cart_items, cart_fingerprint, checkout_token
  ) values (
    v_profile.location_id, 'discount', v_profile.profile_id,
    v_profile.profile_name, v_profile.role, v_reason,
    lower(trim(p_discount_mode)), p_discount_value,
    v_snapshot.discount_amount, v_snapshot.effective_percentage,
    v_snapshot.subtotal_amount, v_snapshot.normalized_items,
    v_snapshot.cart_fingerprint, trim(p_checkout_token)
  )
  on conflict (location_id, requested_by_id, checkout_token, cart_fingerprint)
    where request_type = 'discount'
      and status in ('pending', 'approved')
      and used_at is null
  do nothing
  returning * into v_request;

  if not found then
    select request.* into v_request
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.requested_by_id = v_profile.profile_id
      and request.request_type = 'discount'
      and request.checkout_token = trim(p_checkout_token)
      and request.cart_fingerprint = v_snapshot.cart_fingerprint
      and request.status in ('pending', 'approved')
      and request.used_at is null
    order by request.requested_at desc
    limit 1;
  end if;
  if not found then raise exception 'discount_approval_conflict'; end if;

  perform private.upsert_inventory_approval_notification_v1(v_request);
  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."create_discount_approval_request_v1"(text, jsonb, text, numeric, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."create_discount_approval_request_v1"(text, jsonb, text, numeric, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_discount_approval_request_v1"(text, jsonb, text, numeric, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_discount_approval_request_v1"(text, jsonb, text, numeric, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."create_discount_approval_request_v1"(text, jsonb, text, numeric, text, text) FROM PUBLIC, "authenticated";

CREATE OR REPLACE FUNCTION public.update_settings_dashboard_v1 (
  p_session_token text,
  p_auto_assign_orders boolean,
  p_max_helper_orders integer,
  p_max_approved_discount numeric,
  p_default_cashier_limit numeric,
  p_gcash_enabled boolean,
  p_gcash_account_name text,
  p_gcash_number text,
  p_cashier_limits jsonb -- Retained for RPC compatibility; individual overrides are ignored.
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update store settings';
  end if;
  if p_auto_assign_orders is null or p_gcash_enabled is null
     or p_max_helper_orders is null or p_max_helper_orders not between 1 and 30
     or p_max_approved_discount is null or p_max_approved_discount not between 0 and 100
     or p_default_cashier_limit is null
     or p_default_cashier_limit not between 0 and p_max_approved_discount then
    raise exception 'Store settings contain invalid limits';
  end if;
  insert into public.store_settings (
    location_id,
    auto_assign_orders,
    max_active_orders_per_helper,
    max_approved_discount_pct,
    cashier_auto_approved_discount_limit_pct,
    gcash_enabled,
    gcash_account_name,
    gcash_number
  ) values (
    v_profile.location_id,
    p_auto_assign_orders,
    p_max_helper_orders,
    p_max_approved_discount,
    p_default_cashier_limit,
    p_gcash_enabled,
    trim(coalesce(p_gcash_account_name, '')),
    trim(coalesce(p_gcash_number, ''))
  )
  on conflict (location_id) do update set
    auto_assign_orders = excluded.auto_assign_orders,
    max_active_orders_per_helper = excluded.max_active_orders_per_helper,
    max_approved_discount_pct = excluded.max_approved_discount_pct,
    cashier_auto_approved_discount_limit_pct = excluded.cashier_auto_approved_discount_limit_pct,
    gcash_enabled = excluded.gcash_enabled,
    gcash_account_name = excluded.gcash_account_name,
    gcash_number = excluded.gcash_number;

  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.update_settings_dashboard_v1(
  text, boolean, integer, numeric, numeric, boolean, text, text, jsonb
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.update_settings_dashboard_v1(
  text, boolean, integer, numeric, numeric, boolean, text, text, jsonb
) FROM PUBLIC, authenticated;
-- Clear legacy overrides so older clients also use the store-wide limit.
UPDATE public.profiles
SET cashier_discount_limit_pct = NULL
WHERE cashier_discount_limit_pct IS NOT NULL;

COMMIT;