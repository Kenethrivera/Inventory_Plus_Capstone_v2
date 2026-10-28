-- Phase B2A: operational idempotency and cross-client race protection.
-- Manual deployment only. Run this file as one unit in the Supabase SQL editor.
-- The transaction makes the additive schema and RPC deployment atomic.

begin;

alter table public.approval_requests
  add column if not exists submission_operation_id text;

alter table public.products
  add column if not exists create_operation_id text;

do $preflight$
begin
  if exists (
    select 1
    from public.approval_requests request
    where request.request_type = 'discount'
      and request.status in ('pending', 'approved')
      and request.used_at is null
    group by request.location_id, request.requested_by_id,
      request.checkout_token, request.cart_fingerprint
    having count(*) > 1
  ) then
    raise exception
      'Existing duplicate active discount approvals must be resolved before Phase B2A deployment';
  end if;
end;
$preflight$;

create unique index if not exists approval_requests_discount_active_unique
  on public.approval_requests (
    location_id, requested_by_id, checkout_token, cart_fingerprint
  )
  where request_type = 'discount'
    and status in ('pending', 'approved')
    and used_at is null;

create unique index if not exists
  approval_requests_submission_operation_unique
  on public.approval_requests (submission_operation_id)
  where submission_operation_id is not null;

create unique index if not exists products_create_operation_unique
  on public.products (create_operation_id)
  where create_operation_id is not null;


CREATE OR REPLACE FUNCTION public.prepare_customer_order_v1 (
  p_session_token   text,
  p_order_id        uuid,
  p_expected_status text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_order public.orders;
  v_expected_status text := lower(trim(coalesce(p_expected_status, '')));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Preparation session is invalid or expired'; end if;
  if v_expected_status not in ('pending', 'solo_picking') then
    raise exception 'order_preparation_conflict';
  end if;

  update public.orders customer_order
  set status = 'prepared',
      prepared_by = v_profile.profile_id,
      prepared_by_id = v_profile.profile_id::text,
      prepared_by_name = v_profile.profile_name,
      prepared_at = now(),
      updated_at = now()
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and customer_order.status = v_expected_status
    and (v_expected_status <> 'pending'
      or v_profile.role <> 'helper'
      or customer_order.assigned_helper_id = v_profile.profile_id::text)
  returning customer_order.* into v_order;

  if not found then
    select customer_order.* into v_order
    from public.orders customer_order
    where customer_order.id = p_order_id
      and customer_order.location_id = v_profile.location_id;
    if not found
        or v_order.status <> 'prepared'
        or v_order.prepared_by_id is distinct from v_profile.profile_id::text then
      raise exception 'order_preparation_conflict';
    end if;
  end if;
  return to_jsonb(v_order);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.prepare_customer_order_v1(text, uuid, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.prepare_customer_order_v1(text, uuid, text)
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.assign_order_helper_v1 (
  p_session_token      text,
  p_order_id           uuid,
  p_helper_id          text,
  p_expected_helper_id text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_helper public.profiles;
  v_order public.orders;
  v_helper_id text := nullif(trim(coalesce(p_helper_id, '')), '');
  v_expected_helper_id text := nullif(trim(coalesce(p_expected_helper_id, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Assignment session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then raise exception 'assignment_not_allowed'; end if;

  select helper.* into v_helper
  from public.profiles helper
  where helper.id::text = v_helper_id
    and helper.location_id = v_profile.location_id
    and lower(helper.role) = 'helper';
  if not found then raise exception 'assignment_helper_unavailable'; end if;

  update public.orders customer_order
  set assigned_helper_id = v_helper.id::text,
      assigned_helper_name = v_helper.name,
      assigned_at = now(),
      assigned_by_admin_id = v_profile.profile_id::text,
      assigned_by_admin_name = v_profile.profile_name,
      updated_at = now()
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and customer_order.status = 'pending'
    and customer_order.assigned_helper_id is not distinct from v_expected_helper_id
  returning customer_order.* into v_order;

  if found then
    return jsonb_build_object('order', to_jsonb(v_order), 'reused', false);
  end if;
  raise exception 'order_assignment_conflict';
end;
$function$;

GRANT EXECUTE ON FUNCTION public.assign_order_helper_v1(text, uuid, text, text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.assign_order_helper_v1(text, uuid, text, text)
  FROM PUBLIC, authenticated;

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

CREATE OR REPLACE FUNCTION public.create_inventory_approval_request_v2 (
  p_session_token      text,
  p_operation_id       text,
  p_request_type       text,
  p_product_id         uuid,
  p_quantity           numeric,
  p_reason             text,
  p_note               text,
  p_proof_storage_path text,
  p_proof_file_name    text,
  p_proof_mime_type    text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_product record;
  v_upload private.approval_evidence_uploads;
  v_request public.approval_requests;
  v_operation_id text := nullif(trim(coalesce(p_operation_id, '')), '');
  v_type text := lower(trim(coalesce(p_request_type, '')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_proof_path text := nullif(trim(coalesce(p_proof_storage_path, '')), '');
  v_proof_name text := nullif(trim(coalesce(p_proof_file_name, '')), '');
  v_proof_mime text := lower(nullif(trim(coalesce(p_proof_mime_type, '')), ''));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may request stock changes';
  end if;
  if v_operation_id is null or length(v_operation_id) < 16 then
    raise exception 'approval_submission_invalid';
  end if;
  if v_type not in ('restock', 'write_off') then
    raise exception 'Unsupported approval request type';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'inventory-approval:' || v_operation_id,
    0
  ));
  select request.* into v_request
  from public.approval_requests request
  where request.submission_operation_id = v_operation_id;
  if found then
    if v_request.location_id is distinct from v_profile.location_id
        or v_request.requested_by_id is distinct from v_profile.profile_id
        or v_request.request_type is distinct from v_type
        or v_request.product_id is distinct from p_product_id then
      raise exception 'approval_submission_conflict';
    end if;
    return private.approval_request_json_v1(v_request);
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0';
  end if;
  select upload.* into v_upload
  from private.approval_evidence_uploads upload
  where upload.storage_path = v_proof_path
    and upload.location_id = v_profile.location_id
    and upload.requested_by_id = v_profile.profile_id
    and upload.file_name = v_proof_name
    and upload.mime_type = v_proof_mime
    and upload.expires_at > now()
  for update;
  if not found then raise exception 'Valid uploaded photo evidence is required'; end if;
  if not exists (
    select 1 from storage.objects evidence
    where evidence.bucket_id = 'approval_evidence'
      and evidence.name = v_upload.storage_path
  ) then
    raise exception 'Uploaded proof image was not found';
  end if;

  select product.id, product.location_id, product.product_name, product.sku,
      coalesce(product.unit, 'pcs') as unit,
      product.product_quantity, coalesce(product.is_active, true) as is_active
    into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id;
  if not found or not v_product.is_active then
    raise exception 'Item not found, disabled, or outside the active location';
  end if;
  if v_type = 'write_off' and v_reason is null then
    raise exception 'A write-off reason is required';
  end if;
  if v_type = 'write_off' and p_quantity > v_product.product_quantity then
    raise exception 'Cannot request more than the current stock';
  end if;

  insert into public.approval_requests (
    location_id, request_type, requested_by_id, requested_by_name,
    requested_by_role, product_id, product_name, product_sku, unit,
    requested_quantity, stock_at_request, reason, note,
    proof_storage_path, proof_file_name, proof_mime_type,
    submission_operation_id
  ) values (
    v_profile.location_id, v_type, v_profile.profile_id,
    v_profile.profile_name, v_profile.role, v_product.id,
    v_product.product_name, coalesce(v_product.sku, ''), v_product.unit,
    p_quantity, v_product.product_quantity, v_reason, v_note,
    v_upload.storage_path, v_upload.file_name, v_upload.mime_type,
    v_operation_id
  ) returning * into v_request;

  delete from private.approval_evidence_uploads where id = v_upload.id;
  perform private.upsert_inventory_approval_notification_v1(v_request);
  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.create_inventory_approval_request_v2(
  text, text, text, uuid, numeric, text, text, text, text, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.create_inventory_approval_request_v2(
  text, text, text, uuid, numeric, text, text, text, text, text
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.create_product_v1 (
  p_session_token       text,
  p_operation_id        text,
  p_sku                 text,
  p_product_name        text,
  p_category            text,
  p_product_price       numeric,
  p_product_quantity    numeric,
  p_description         text,
  p_image_url           text,
  p_manufacturer        text,
  p_model               text,
  p_product_size        text,
  p_shelf_level         text,
  p_bin_number          text,
  p_unit                text,
  p_max_quantity        numeric
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_product public.products;
  v_operation_id text := nullif(trim(coalesce(p_operation_id, '')), '');
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Product session is invalid or expired'; end if;
  if v_operation_id is null or length(v_operation_id) < 16 then
    raise exception 'product_submission_invalid';
  end if;
  if nullif(trim(coalesce(p_sku, '')), '') is null
      or nullif(trim(coalesce(p_product_name, '')), '') is null
      or p_product_price is null or p_product_price < 0
      or p_product_quantity is null or p_product_quantity < 0
      or p_max_quantity is null or p_max_quantity < 0 then
    raise exception 'product_data_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'product-create:' || v_operation_id,
    0
  ));
  select product.* into v_product
  from public.products product
  where product.create_operation_id = v_operation_id;
  if found then
    if v_product.location_id is distinct from v_profile.location_id
        or v_product.sku is distinct from trim(p_sku)
        or v_product.product_name is distinct from trim(p_product_name) then
      raise exception 'product_submission_conflict';
    end if;
    return to_jsonb(v_product);
  end if;

  begin
    insert into public.products (
      sku, product_name, category, product_price, product_quantity,
      description, image_url, location_id, manufacturer, model,
      product_size, shelf_level, bin_number, unit, max_quantity,
      create_operation_id
    ) values (
      trim(p_sku), trim(p_product_name), p_category, p_product_price,
      p_product_quantity, p_description, p_image_url, v_profile.location_id,
      p_manufacturer, p_model, p_product_size, p_shelf_level, p_bin_number,
      coalesce(nullif(trim(p_unit), ''), 'pcs'), p_max_quantity,
      v_operation_id
    ) returning * into v_product;
  exception when unique_violation then
    raise exception 'product_sku_already_exists';
  end;

  insert into public.transaction_history (
    product_id, transaction_type, quantity_change, new_quantity,
    location_id, user_id, user_name, operation_id, operation_scope
  ) values (
    v_product.id, 'add', v_product.product_quantity,
    v_product.product_quantity, v_profile.location_id, v_profile.profile_id,
    v_profile.profile_name, v_operation_id, 'product_create'
  );
  return to_jsonb(v_product);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.create_product_v1(
  text, text, text, text, text, numeric, numeric, text, text, text, text,
  text, text, text, text, numeric
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.create_product_v1(
  text, text, text, text, text, numeric, numeric, text, text, text, text,
  text, text, text, text, numeric
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.save_store_map_v1 (
  p_session_token   text,
  p_expected_layout jsonb,
  p_new_layout      jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_layout jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Map session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then raise exception 'map_save_not_allowed'; end if;
  if p_expected_layout is not null and jsonb_typeof(p_expected_layout) <> 'array' then
    raise exception 'map_layout_invalid';
  end if;
  if p_new_layout is not null and jsonb_typeof(p_new_layout) <> 'array' then
    raise exception 'map_layout_invalid';
  end if;

  update public.locations location
  set layout_data = p_new_layout
  where location.id = v_profile.location_id
    and coalesce(location.layout_data, '[]'::jsonb)
      = coalesce(p_expected_layout, '[]'::jsonb)
  returning location.layout_data into v_layout;

  if found then
    return jsonb_build_object(
      'status', 'saved',
      'layout_data', coalesce(v_layout, '[]'::jsonb)
    );
  end if;

  select coalesce(location.layout_data, '[]'::jsonb) into v_layout
  from public.locations location
  where location.id = v_profile.location_id;
  if not found then raise exception 'map_location_not_found'; end if;
  return jsonb_build_object('status', 'conflict', 'layout_data', v_layout);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.save_store_map_v1(text, jsonb, jsonb)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.save_store_map_v1(text, jsonb, jsonb)
  FROM PUBLIC, authenticated;

commit;

-- SQL-first compatibility:
-- Existing clients continue using create_inventory_approval_request_v1.
-- New clients use create_inventory_approval_request_v2 after this deployment.
-- Phase B1 RPC signatures and behavior are not replaced by this phase.

