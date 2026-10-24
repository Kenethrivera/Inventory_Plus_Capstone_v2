CREATE OR REPLACE FUNCTION private.upsert_inventory_approval_notification_v1 (
  p_request public.approval_requests
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
declare
  v_notification_id public.notifications.id%type;
  v_action text := case p_request.request_type
    when 'restock' then 'Restock'
    when 'write_off' then 'Write-off'
    else 'Discount' end;
  v_title text;
  v_body text;
  v_target_roles text[];
  v_priority text;
  v_payload jsonb;
begin
  if p_request.status = 'pending' then
    v_title := v_action || ' approval requested';
    v_body := case when p_request.request_type = 'discount' then
      p_request.requested_by_name || ' requested a ' ||
      round(p_request.discount_effective_percentage, 2) ||
      '% discount (PHP ' || round(p_request.discount_amount, 2) || ').'
    else
      p_request.requested_by_name || ' requested ' || v_action || ' of ' ||
      p_request.requested_quantity || ' ' || p_request.unit || ' for ' ||
      p_request.product_name || '.' end;
    v_target_roles := array['admin']::text[];
    v_priority := 'high';
  else
    v_title := v_action || ' request ' || p_request.status;
    v_body := case when p_request.request_type = 'discount' then
      'Your ' || round(p_request.discount_effective_percentage, 2) ||
      '% discount request was ' || p_request.status || '.'
    else
      'Your ' || v_action || ' request for ' ||
      p_request.requested_quantity || ' ' || p_request.unit || ' of ' ||
      p_request.product_name || ' was ' || p_request.status || '.' end;
    v_target_roles := array[p_request.requested_by_role]::text[];
    v_priority := 'medium';
  end if;

  v_payload := jsonb_build_object(
    'category', 'inventoryApproval',
    'approvalRequestId', p_request.id,
    'requestType', p_request.request_type,
    'status', p_request.status,
    'stage', p_request.status,
    'productId', p_request.product_id,
    'productName', p_request.product_name,
    'quantity', p_request.requested_quantity,
    'unit', p_request.unit,
    'discountMode', p_request.discount_mode,
    'discountValue', p_request.discount_value,
    'discountAmount', p_request.discount_amount,
    'effectivePercentage', p_request.discount_effective_percentage,
    'subtotalAmount', p_request.subtotal_amount,
    'requestedById', p_request.requested_by_id,
    'requestedByName', p_request.requested_by_name,
    'recipientId', case when p_request.status = 'pending'
      then null else to_jsonb(p_request.requested_by_id) end
  );

  select notification.id into v_notification_id
  from public.notifications notification
  where notification.location_id = p_request.location_id::text
    and notification.is_resolved = false
    and notification.type = 'system'
    and notification.payload ->> 'category' = 'inventoryApproval'
    and notification.payload ->> 'approvalRequestId' = p_request.id::text
  order by notification.created_at, notification.id
  limit 1
  for update;

  if v_notification_id is null then
    insert into public.notifications (
      location_id, target_roles, title, body, type, priority, payload,
      created_at, is_resolved, resolved_at
    ) values (
      p_request.location_id::text, v_target_roles, v_title, v_body, 'system',
      v_priority, v_payload, now(), false, null
    ) returning id into v_notification_id;
  else
    update public.notifications
    set target_roles = v_target_roles,
        title = v_title,
        body = v_body,
        priority = v_priority,
        payload = v_payload,
        is_resolved = false,
        resolved_at = null
    where id = v_notification_id;

    update public.notification_reads
    set is_read = false,
        read_at = null,
        is_deleted = false,
        deleted_at = null
    where notification_id = v_notification_id;
  end if;

  update public.notifications notification
  set is_resolved = true,
      resolved_at = now()
  where notification.location_id = p_request.location_id::text
    and notification.id <> v_notification_id
    and notification.is_resolved = false
    and notification.type = 'system'
    and notification.payload ->> 'category' = 'inventoryApproval'
    and notification.payload ->> 'approvalRequestId' = p_request.id::text;
end;
$function$;

REVOKE ALL ON FUNCTION "private"."upsert_inventory_approval_notification_v1"(public.approval_requests) FROM PUBLIC;
