-- Phase 2C repair for already-deployed discount approvals.
-- Apply through the normal migration process only. Do not execute from Flutter.

alter table public.approval_requests
  add column if not exists cart_items jsonb;

alter table public.approval_requests
  drop constraint if exists approval_request_discount_fields_check;

-- The first Phase 2C deployment used "fixed" while Flutter has always sent
-- "amount". Keep one canonical stored/RPC value from this patch forward.
update public.approval_requests
set discount_mode = 'amount'
where request_type = 'discount' and discount_mode = 'fixed';

alter table public.approval_requests
  add constraint approval_request_discount_fields_check check (
    request_type <> 'discount' or (
      discount_mode in ('percentage', 'amount')
      and discount_value is not null and discount_value >= 0
      and discount_amount is not null and discount_amount >= 0
      and discount_effective_percentage is not null
      and discount_effective_percentage >= 0
      and discount_effective_percentage <= 100
      and subtotal_amount is not null and subtotal_amount >= 0
      and (
        cart_items is null or (
          jsonb_typeof(cart_items) = 'array'
          and jsonb_array_length(cart_items) > 0
        )
      )
      and cart_fingerprint is not null
      and checkout_token is not null
      and nullif(trim(reason), '') is not null
    )
  );

create or replace function private.discount_cart_snapshot_v1(
  p_location_id uuid,
  p_items jsonb,
  p_discount_mode text,
  p_discount_value numeric,
  p_checkout_token text
) returns table (
  normalized_items jsonb,
  subtotal_amount numeric,
  discount_amount numeric,
  effective_percentage numeric,
  cart_fingerprint text
)
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_mode text := lower(trim(coalesce(p_discount_mode, '')));
  v_value numeric := coalesce(p_discount_value, 0);
  v_requested_count integer;
  v_unique_count integer;
  v_matched_count integer;
  v_quantities_valid boolean;
  v_items jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_effective numeric;
  v_fingerprint text;
begin
  if p_location_id is null then raise exception 'Location is required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The cart cannot be empty';
  end if;
  if v_mode not in ('percentage', 'amount') then
    raise exception 'Unsupported discount mode';
  end if;
  if v_value < 0 then raise exception 'Discount cannot be negative'; end if;
  if v_mode = 'percentage' and v_value > 100 then
    raise exception 'Percentage discount cannot exceed 100%%';
  end if;
  if length(trim(coalesce(p_checkout_token, ''))) < 16 then
    raise exception 'Checkout snapshot token is invalid';
  end if;

  with requested as (
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) entry
  )
  select count(*), count(distinct product_id), bool_and(quantity > 0)
    into v_requested_count, v_unique_count, v_quantities_valid
  from requested;

  if v_requested_count <> jsonb_array_length(p_items)
      or v_unique_count <> v_requested_count
      or not coalesce(v_quantities_valid, false) then
    raise exception 'Cart items or quantities are invalid';
  end if;

  with requested as (
    select
      (entry.value ->> 'product_id')::uuid as product_id,
      (entry.value ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) entry
  ), scoped as (
    select product.id, product.product_name, product.unit,
      product.product_price, requested.quantity
    from requested
    join public.products product on product.id = requested.product_id
    where product.location_id = p_location_id
      and coalesce(product.is_active, true)
      and requested.quantity <= product.product_quantity
  )
  select
    count(*),
    jsonb_agg(
      jsonb_build_object(
        'product_id', scoped.id,
        'product_name', scoped.product_name,
        'quantity', scoped.quantity,
        'unit', coalesce(nullif(trim(scoped.unit), ''), 'pcs'),
        'unit_price', scoped.product_price,
        'line_total', round(scoped.product_price * scoped.quantity, 2)
      ) order by scoped.id
    ),
    round(sum(scoped.product_price * scoped.quantity), 2)
  into v_matched_count, v_items, v_subtotal
  from scoped;

  if v_matched_count <> v_requested_count then
    raise exception 'A cart item is unavailable or exceeds current stock';
  end if;

  v_subtotal := coalesce(v_subtotal, 0);
  v_discount := round(case v_mode
    when 'percentage' then v_subtotal * (v_value / 100)
    else v_value
  end, 2);
  if v_discount > v_subtotal then
    raise exception 'Discount cannot exceed subtotal';
  end if;
  v_effective := case when v_subtotal <= 0 then 0
    else round((v_discount / v_subtotal) * 100, 6) end;
  v_fingerprint := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'items', v_items,
      'subtotal', v_subtotal,
      'discount_mode', v_mode,
      'discount_value', v_value,
      'discount_amount', v_discount,
      'effective_percentage', v_effective,
      'checkout_token', trim(p_checkout_token)
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');

  return query select v_items, v_subtotal, v_discount, v_effective,
    v_fingerprint;
end;
$$;

-- Compatibility for installations where the later six-argument helper was
-- already created. Both signatures now produce the same exact-cart identity.
create or replace function private.discount_cart_snapshot_v1(
  p_location_id uuid,
  p_items jsonb,
  p_discount_mode text,
  p_discount_value numeric,
  p_reason text,
  p_checkout_token text
) returns table (
  normalized_items jsonb,
  subtotal_amount numeric,
  discount_amount numeric,
  effective_percentage numeric,
  cart_fingerprint text
)
language sql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
  select * from private.discount_cart_snapshot_v1(
    p_location_id, p_items, p_discount_mode, p_discount_value,
    p_checkout_token
  )
$$;

revoke all on function private.discount_cart_snapshot_v1(
  uuid, jsonb, text, numeric, text
) from public, anon, authenticated;
revoke all on function private.discount_cart_snapshot_v1(
  uuid, jsonb, text, numeric, text, text
) from public, anon, authenticated;

create or replace function private.approval_request_json_v1(
  p_request public.approval_requests
) returns jsonb
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  select jsonb_build_object(
    'id', p_request.id,
    'location_id', p_request.location_id,
    'location_name', (
      select location.location_name
      from public.locations location
      where location.id = p_request.location_id
    ),
    'request_type', p_request.request_type,
    'status', p_request.status,
    'requested_by_id', p_request.requested_by_id,
    'requested_by_name', p_request.requested_by_name,
    'requested_by_role', p_request.requested_by_role,
    'requested_at', p_request.requested_at,
    'reviewed_by_id', p_request.reviewed_by_id,
    'reviewed_by_name', p_request.reviewed_by_name,
    'reviewed_at', p_request.reviewed_at,
    'product_id', p_request.product_id,
    'product_name', p_request.product_name,
    'product_sku', p_request.product_sku,
    'unit', p_request.unit,
    'requested_quantity', p_request.requested_quantity,
    'stock_at_request', p_request.stock_at_request,
    'current_stock', case when p_request.product_id is null then null else (
      select product.product_quantity
      from public.products product
      where product.id = p_request.product_id
        and product.location_id = p_request.location_id
    ) end,
    'reason', p_request.reason,
    'note', p_request.note,
    'review_note', p_request.review_note,
    'transaction_id', p_request.transaction_id,
    'proof_storage_path', to_jsonb(p_request) ->> 'proof_storage_path',
    'proof_file_name', to_jsonb(p_request) ->> 'proof_file_name',
    'proof_mime_type', to_jsonb(p_request) ->> 'proof_mime_type',
    'discount_mode', p_request.discount_mode,
    'discount_value', p_request.discount_value,
    'discount_amount', p_request.discount_amount,
    'discount_effective_percentage',
      p_request.discount_effective_percentage,
    'subtotal_amount', p_request.subtotal_amount,
    'cart_items', p_request.cart_items,
    'cart_fingerprint', p_request.cart_fingerprint,
    'checkout_token', p_request.checkout_token,
    'used_at', p_request.used_at,
    'used_order_id', p_request.used_order_id
  )
$$;

revoke all on function private.approval_request_json_v1(
  public.approval_requests
) from public, anon, authenticated;

create or replace function public.create_discount_approval_request_v1(
  p_session_token text,
  p_items jsonb,
  p_discount_mode text,
  p_discount_value numeric,
  p_reason text,
  p_checkout_token text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
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
  ) returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);
  return private.approval_request_json_v1(v_request);
end;
$$;

revoke all on function public.create_discount_approval_request_v1(
  text, jsonb, text, numeric, text, text
) from public, authenticated;
grant execute on function public.create_discount_approval_request_v1(
  text, jsonb, text, numeric, text, text
) to anon;
