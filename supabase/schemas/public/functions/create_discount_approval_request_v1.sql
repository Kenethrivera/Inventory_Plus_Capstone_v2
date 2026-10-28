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

  select coalesce(settings.cashier_auto_approved_discount_limit_pct, 10)
    into v_limit
  from public.store_settings settings
  where settings.location_id = v_profile.location_id;
  v_limit := coalesce(v_limit, 10);
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
