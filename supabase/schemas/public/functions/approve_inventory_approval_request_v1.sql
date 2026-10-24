CREATE OR REPLACE FUNCTION public.approve_inventory_approval_request_v1 (
  p_session_token text,
  p_request_id    uuid,
  p_review_note   text DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_request public.approval_requests;
  v_product record;
  v_new_quantity numeric;
  v_transaction_id uuid;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may approve requests';
  end if;

  select request.* into v_request
  from public.approval_requests request
  where request.id = p_request_id
  for update;
  if not found then raise exception 'Approval request not found'; end if;
  if v_request.location_id <> v_profile.location_id then
    raise exception 'Approval request is outside the active location';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'Approval request is already %', v_request.status;
  end if;

  if v_request.request_type <> 'discount' then
    select product.id, product.product_quantity,
        coalesce(product.is_active, true) as is_active
      into v_product
    from public.products product
    where product.id = v_request.product_id
      and product.location_id = v_profile.location_id
    for update;

    if not found or not v_product.is_active then
      raise exception 'Item not found, disabled, or outside the active location';
    end if;
    if v_request.requested_quantity <= 0 then
      raise exception 'Requested quantity is invalid';
    end if;
    if v_request.request_type = 'write_off'
        and v_request.requested_quantity > v_product.product_quantity then
      raise exception 'Write-off conflict: only % remains in stock',
        v_product.product_quantity;
    end if;

    v_new_quantity := case v_request.request_type
      when 'restock' then v_product.product_quantity
        + v_request.requested_quantity
      else v_product.product_quantity - v_request.requested_quantity
    end;

    update public.products set product_quantity = v_new_quantity
    where id = v_request.product_id
      and location_id = v_profile.location_id;

    insert into public.transaction_history (
      product_id, transaction_type, quantity_change, new_quantity,
      location_id, user_id, user_name, note
    ) values (
      v_request.product_id,
      case v_request.request_type when 'restock' then 'stock_in'
        else 'write_off' end,
      case v_request.request_type when 'restock'
        then v_request.requested_quantity
        else -v_request.requested_quantity end,
      v_new_quantity, v_profile.location_id, v_request.requested_by_id,
      v_request.requested_by_name,
      concat_ws(': ',
        case when v_request.request_type = 'write_off'
          then v_request.reason else null end,
        nullif(v_request.note, ''),
        'Approved by ' || v_profile.profile_name
      )
    ) returning id into v_transaction_id;
  end if;

  update public.approval_requests
  set status = 'approved',
      reviewed_by_id = v_profile.profile_id,
      reviewed_by_name = v_profile.profile_name,
      reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_review_note, '')), ''),
      transaction_id = v_transaction_id
  where id = v_request.id
  returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);
  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."approve_inventory_approval_request_v1"(text, uuid, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."approve_inventory_approval_request_v1"(text, uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."approve_inventory_approval_request_v1"(text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."approve_inventory_approval_request_v1"(text, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."approve_inventory_approval_request_v1"(text, uuid, text) FROM PUBLIC, "authenticated";
