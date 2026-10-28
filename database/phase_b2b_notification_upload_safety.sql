-- Phase B2B: notification lifecycle deduplication and retry-safe uploads.
-- Manual deployment only. Run this file as one unit in the Supabase SQL editor.
-- Deploy this SQL after Phase B2A and before the B2B Edge Function/frontend.

begin;

alter table public.notifications
  add column if not exists lifecycle_key text;

alter table private.approval_evidence_uploads
  add column if not exists operation_id text;

alter table private.approval_evidence_uploads
  add column if not exists cleanup_claimed_at timestamp with time zone;

do $constraint$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'approval_evidence_uploads_operation_key'
      and conrelid = 'private.approval_evidence_uploads'::regclass
  ) then
    alter table private.approval_evidence_uploads
      add constraint approval_evidence_uploads_operation_key
      unique (location_id, requested_by_id, operation_id);
  end if;
end;
$constraint$;

-- Backfill only active, lifecycle-identifiable rows. Rendered text is never
-- used as identity, and resolved history remains unchanged.
with source as (
  select
    notification.id,
    case
      when notification.type in (
        'newOrder', 'orderAssigned', 'orderPrepared', 'orderCancelled'
      ) and nullif(notification.payload ->> 'orderId', '') is not null
        then 'order-workflow:' || (notification.payload ->> 'orderId')
      when notification.type in ('lowStock', 'criticalStock', 'deadStock')
          and nullif(notification.payload ->> 'itemId', '') is not null
        then 'stock-alert:' || audience.key || ':' ||
          (notification.payload ->> 'itemId')
      when notification.type = 'stockAlert'
          and jsonb_typeof(notification.payload -> 'items') = 'array'
          and jsonb_array_length(notification.payload -> 'items') = 1
          and nullif(notification.payload #>> '{items,0,itemId}', '') is not null
        then 'stock-alert:' || audience.key || ':' ||
          (notification.payload #>> '{items,0,itemId}')
      when notification.type = 'exportReminder'
          and nullif(notification.payload ->> 'reportType', '') is not null
          and nullif(notification.payload ->> 'periodType', '') is not null
          and nullif(notification.payload ->> 'periodKey', '') is not null
        then 'export:' || audience.key || ':' ||
          lower(notification.payload ->> 'reportType') || ':' ||
          lower(notification.payload ->> 'periodType') || ':' ||
          (notification.payload ->> 'periodKey')
      when notification.type = 'transaction'
          and coalesce(
            nullif(notification.payload ->> 'transactionId', ''),
            nullif(notification.payload ->> 'orderId', '')
          ) is not null
        then 'transaction:' || audience.key || ':' || coalesce(
          nullif(notification.payload ->> 'transactionId', ''),
          notification.payload ->> 'orderId'
        )
      when notification.type = 'inventoryRestocked'
          and nullif(notification.payload ->> 'transactionId', '') is not null
        then 'restock:' || audience.key || ':' ||
          (notification.payload ->> 'transactionId')
      when notification.type = 'system'
          and notification.payload ->> 'category' = 'inventoryApproval'
          and nullif(notification.payload ->> 'approvalRequestId', '') is not null
        then 'inventory-approval:' ||
          (notification.payload ->> 'approvalRequestId')
      when notification.type = 'system'
          and notification.payload ->> 'category' = 'storeAccess'
          and nullif(notification.payload ->> 'lifecycleKind', '') is not null
          and nullif(notification.payload ->> 'windowKey', '') is not null
        then 'store-access:' ||
          (notification.payload ->> 'lifecycleKind') || ':' ||
          (notification.payload ->> 'windowKey')
      else null
    end as lifecycle_key
  from public.notifications notification
  cross join lateral (
    select coalesce(string_agg(lower(role), '|' order by lower(role)), '') as key
    from unnest(notification.target_roles) as target(role)
  ) audience
  where notification.is_resolved = false
    and notification.lifecycle_key is null
)
update public.notifications notification
set lifecycle_key = source.lifecycle_key
from source
where notification.id = source.id
  and source.lifecycle_key is not null;

-- Legacy multi-item stockAlert rows cannot map to a single product lifecycle.
-- Identifiable single-item rows were keyed above and remain active.
update public.notifications
set is_resolved = true,
    resolved_at = coalesce(resolved_at, now())
where is_resolved = false
  and type = 'stockAlert'
  and lifecycle_key is null;

-- Keep the oldest row, matching the existing client reconciliation rule, and
-- resolve only duplicate active rows before enforcing uniqueness.
with ranked as (
  select
    notification.id,
    row_number() over (
      partition by notification.location_id, notification.lifecycle_key
      order by notification.created_at, notification.id
    ) as position
  from public.notifications notification
  where notification.is_resolved = false
    and notification.lifecycle_key is not null
)
update public.notifications notification
set is_resolved = true,
    resolved_at = coalesce(notification.resolved_at, now())
from ranked
where notification.id = ranked.id
  and ranked.position > 1;

create unique index if not exists notifications_active_lifecycle_unique
  on public.notifications (location_id, lifecycle_key)
  where lifecycle_key is not null
    and is_resolved = false;

CREATE OR REPLACE FUNCTION private.upsert_notification_lifecycle_v1 (
  p_location_id  text,
  p_lifecycle_key text,
  p_target_roles text[],
  p_title        text,
  p_body         text,
  p_type         text,
  p_priority     text,
  p_payload      jsonb,
  p_created_at   timestamp with time zone DEFAULT now()
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
declare
  v_notification public.notifications;
  v_old_stage text;
  v_new_stage text;
begin
  if nullif(trim(coalesce(p_location_id, '')), '') is null
      or nullif(trim(coalesce(p_lifecycle_key, '')), '') is null then
    raise exception 'notification_lifecycle_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'notification:' || p_location_id || ':' || p_lifecycle_key,
    0
  ));

  select notification.* into v_notification
  from public.notifications notification
  where notification.location_id = p_location_id
    and notification.lifecycle_key = p_lifecycle_key
    and notification.is_resolved = false
  for update;

  if found then
    v_old_stage := v_notification.type || ':' || coalesce(
      v_notification.payload ->> 'stage',
      v_notification.payload ->> 'status',
      ''
    );
    v_new_stage := p_type || ':' || coalesce(
      p_payload ->> 'stage',
      p_payload ->> 'status',
      ''
    );
    update public.notifications notification
    set target_roles = p_target_roles,
        title = p_title,
        body = p_body,
        type = p_type,
        priority = p_priority,
        payload = coalesce(p_payload, '{}'::jsonb),
        is_resolved = false,
        resolved_at = null
    where notification.id = v_notification.id;

    if v_old_stage is distinct from v_new_stage then
      update public.notification_reads
      set is_read = false,
          read_at = null,
          is_deleted = false,
          deleted_at = null
      where notification_id = v_notification.id;
    end if;
    return v_notification.id;
  end if;

  insert into public.notifications (
    location_id, target_roles, title, body, type, priority, payload,
    created_at, is_resolved, resolved_at, lifecycle_key
  ) values (
    p_location_id, p_target_roles, p_title, p_body, p_type, p_priority,
    coalesce(p_payload, '{}'::jsonb), coalesce(p_created_at, now()),
    false, null, p_lifecycle_key
  ) returning * into v_notification;
  return v_notification.id;
end;
$function$;

REVOKE ALL ON FUNCTION private.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.upsert_notification_lifecycle_v1 (
  p_session_token  text,
  p_lifecycle_key  text,
  p_target_roles   text[],
  p_title          text,
  p_body           text,
  p_type           text,
  p_priority       text,
  p_payload        jsonb,
  p_created_at     timestamp with time zone DEFAULT now()
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_notification_id uuid;
  v_notification public.notifications;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Notification session is invalid or expired'; end if;

  v_notification_id := private.upsert_notification_lifecycle_v1(
    v_profile.location_id::text,
    nullif(trim(coalesce(p_lifecycle_key, '')), ''),
    p_target_roles,
    p_title,
    p_body,
    p_type,
    p_priority,
    p_payload,
    p_created_at
  );
  select notification.* into v_notification
  from public.notifications notification
  where notification.id = v_notification_id;
  return to_jsonb(v_notification);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.transition_stock_notification_v1 (
  p_session_token text,
  p_item_id       text,
  p_status        text,
  p_title         text,
  p_body          text,
  p_type          text,
  p_priority      text,
  p_payload       jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_state public.stock_notification_states;
  v_item_id text := nullif(trim(coalesce(p_item_id, '')), '');
  v_status text := lower(trim(coalesce(p_status, '')));
  v_lifecycle_key text;
  v_changed boolean;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Notification session is invalid or expired'; end if;
  if v_item_id is null or v_status not in ('ok', 'low', 'critical', 'dead') then
    raise exception 'stock_notification_transition_invalid';
  end if;
  v_lifecycle_key := 'stock-alert:admin:' || v_item_id;

  perform pg_advisory_xact_lock(hashtextextended(
    'stock-notification:' || v_profile.location_id::text || ':' || v_item_id,
    0
  ));
  select state.* into v_state
  from public.stock_notification_states state
  where state.location_id = v_profile.location_id::text
    and state.item_id = v_item_id
  for update;

  if not found then
    insert into public.stock_notification_states (
      location_id, item_id, last_status, updated_at
    ) values (
      v_profile.location_id::text, v_item_id, v_status, now()
    );
    return jsonb_build_object(
      'initialized', true,
      'changed', false,
      'status', v_status
    );
  end if;

  v_changed := v_state.last_status is distinct from v_status;
  if v_status = 'ok' then
    update public.notifications notification
    set is_resolved = true,
        resolved_at = now()
    where notification.location_id = v_profile.location_id::text
      and notification.lifecycle_key = v_lifecycle_key
      and notification.is_resolved = false;
  else
    if p_title is null or p_body is null or p_type is null
        or p_priority is null or p_payload is null then
      raise exception 'stock_notification_payload_invalid';
    end if;
    if v_changed then
      perform private.upsert_notification_lifecycle_v1(
        v_profile.location_id::text,
        v_lifecycle_key,
        array['admin']::text[],
        p_title,
        p_body,
        p_type,
        p_priority,
        p_payload,
        now()
      );
    else
      update public.notifications notification
      set target_roles = array['admin']::text[],
          title = p_title,
          body = p_body,
          type = p_type,
          priority = p_priority,
          payload = p_payload
      where notification.location_id = v_profile.location_id::text
        and notification.lifecycle_key = v_lifecycle_key
        and notification.is_resolved = false;
    end if;
  end if;

  update public.stock_notification_states state
  set last_status = v_status,
      updated_at = now()
  where state.id = v_state.id;
  return jsonb_build_object(
    'initialized', false,
    'changed', v_changed,
    'status', v_status
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.transition_stock_notification_v1(
  text, text, text, text, text, text, text, jsonb
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.transition_stock_notification_v1(
  text, text, text, text, text, text, text, jsonb
) FROM PUBLIC, authenticated;

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

  v_notification_id := private.upsert_notification_lifecycle_v1(
    p_request.location_id::text,
    'inventory-approval:' || p_request.id::text,
    v_target_roles,
    v_title,
    v_body,
    'system',
    v_priority,
    v_payload,
    now()
  );
end;
$function$;

REVOKE ALL ON FUNCTION "private"."upsert_inventory_approval_notification_v1"(public.approval_requests) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.prepare_inventory_approval_evidence_v1 (
  p_session_token text,
  p_file_name     text,
  p_mime_type     text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_upload private.approval_evidence_uploads;
  v_file_name text := nullif(trim(coalesce(p_file_name, '')), '');
  v_mime_type text := lower(nullif(trim(coalesce(p_mime_type, '')), ''));
  v_extension text;
  v_upload_id uuid := extensions.gen_random_uuid();
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may upload proof';
  end if;
  if v_file_name is null or length(v_file_name) > 255 then
    raise exception 'A valid proof file name is required';
  end if;
  v_extension := case v_mime_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'image/gif' then 'gif'
    else null
  end;
  if v_extension is null then
    raise exception 'Only JPG, PNG, WebP, or GIF proof images are allowed';
  end if;

  insert into private.approval_evidence_uploads (
    id, location_id, requested_by_id, storage_path, file_name, mime_type
  ) values (
    v_upload_id,
    v_profile.location_id,
    v_profile.profile_id,
    v_profile.location_id::text || '/' || v_profile.profile_id::text || '/' ||
      v_upload_id::text || '.' || v_extension,
    v_file_name,
    v_mime_type
  ) returning * into v_upload;

  return jsonb_build_object(
    'storage_path', v_upload.storage_path,
    'file_name', v_upload.file_name,
    'mime_type', v_upload.mime_type,
    'expires_at', v_upload.expires_at
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."prepare_inventory_approval_evidence_v1"(text, text, text) FROM PUBLIC, "authenticated";

CREATE OR REPLACE FUNCTION public.prepare_inventory_approval_evidence_v2 (
  p_session_token text,
  p_operation_id  text,
  p_file_name     text,
  p_mime_type     text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_upload private.approval_evidence_uploads;
  v_request public.approval_requests;
  v_operation_id text := nullif(trim(coalesce(p_operation_id, '')), '');
  v_file_name text := nullif(trim(coalesce(p_file_name, '')), '');
  v_mime_type text := lower(nullif(trim(coalesce(p_mime_type, '')), ''));
  v_extension text;
  v_storage_path text;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may upload proof';
  end if;
  if v_operation_id is null or length(v_operation_id) < 16 then
    raise exception 'evidence_operation_invalid';
  end if;
  if v_file_name is null or length(v_file_name) > 255 then
    raise exception 'A valid proof file name is required';
  end if;
  v_extension := case v_mime_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'image/gif' then 'gif'
    else null
  end;
  if v_extension is null then
    raise exception 'Only JPG, PNG, WebP, or GIF proof images are allowed';
  end if;

  -- Serialize with create_inventory_approval_request_v2. A retry must observe
  -- a committed request before it can recreate or overwrite its evidence.
  perform pg_advisory_xact_lock(hashtextextended(
    'inventory-approval:' || v_operation_id,
    0
  ));
  select request.* into v_request
  from public.approval_requests request
  where request.submission_operation_id = v_operation_id
    and request.location_id = v_profile.location_id
    and request.requested_by_id = v_profile.profile_id;
  if found and v_request.proof_storage_path is not null then
    return jsonb_build_object(
      'storage_path', v_request.proof_storage_path,
      'file_name', v_request.proof_file_name,
      'mime_type', v_request.proof_mime_type,
      'expires_at', null,
      'already_submitted', true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'approval-evidence:' || v_profile.location_id::text || ':' ||
      v_profile.profile_id::text || ':' || v_operation_id,
    0
  ));
  select upload.* into v_upload
  from private.approval_evidence_uploads upload
  where upload.location_id = v_profile.location_id
    and upload.requested_by_id = v_profile.profile_id
    and upload.operation_id = v_operation_id
  for update;
  if found then
    if v_upload.cleanup_claimed_at is not null then
      raise exception 'evidence_upload_expired';
    end if;
    if v_upload.mime_type <> v_mime_type then
      raise exception 'evidence_operation_conflict';
    end if;
    update private.approval_evidence_uploads upload
    set expires_at = now() + interval '15 minutes',
        file_name = v_file_name
    where upload.id = v_upload.id
    returning * into v_upload;
  else
    v_storage_path := v_profile.location_id::text || '/' ||
      v_profile.profile_id::text || '/' ||
      encode(extensions.digest(convert_to(v_operation_id, 'UTF8'), 'sha256'), 'hex') ||
      '.' || v_extension;
    insert into private.approval_evidence_uploads (
      location_id, requested_by_id, storage_path, file_name, mime_type,
      operation_id
    ) values (
      v_profile.location_id, v_profile.profile_id, v_storage_path,
      v_file_name, v_mime_type, v_operation_id
    ) returning * into v_upload;
  end if;

  return jsonb_build_object(
    'storage_path', v_upload.storage_path,
    'file_name', v_upload.file_name,
    'mime_type', v_upload.mime_type,
    'expires_at', v_upload.expires_at,
    'already_submitted', false
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.prepare_inventory_approval_evidence_v2(
  text, text, text, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.prepare_inventory_approval_evidence_v2(
  text, text, text, text
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.claim_expired_approval_evidence_v1 (
  p_session_token text,
  p_limit         integer DEFAULT 25
)
  RETURNS TABLE (storage_path text)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;

  return query
  with candidates as (
    select upload.id
    from private.approval_evidence_uploads upload
    where upload.location_id = v_profile.location_id
      and (upload.cleanup_claimed_at is not null
        or upload.expires_at <= now() - interval '1 hour')
      and not exists (
        select 1 from public.approval_requests request
        where request.proof_storage_path = upload.storage_path
      )
    order by coalesce(upload.cleanup_claimed_at, upload.expires_at), upload.id
    limit v_limit
    for update skip locked
  ), claimed as (
    update private.approval_evidence_uploads upload
    set cleanup_claimed_at = coalesce(upload.cleanup_claimed_at, now())
    where upload.id in (select candidate.id from candidates candidate)
    returning upload.storage_path
  )
  select claimed.storage_path from claimed;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.claim_expired_approval_evidence_v1(text, integer)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.claim_expired_approval_evidence_v1(text, integer)
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.finalize_approval_evidence_cleanup_v1 (
  p_session_token text,
  p_storage_paths text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_deleted integer;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Approval session is invalid or expired'; end if;

  delete from private.approval_evidence_uploads upload
  where upload.location_id = v_profile.location_id
    and upload.cleanup_claimed_at is not null
    and upload.storage_path = any(coalesce(p_storage_paths, '{}'::text[]))
    and not exists (
      select 1 from public.approval_requests request
      where request.proof_storage_path = upload.storage_path
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.finalize_approval_evidence_cleanup_v1(text, text[])
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.finalize_approval_evidence_cleanup_v1(text, text[])
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.create_inventory_approval_request_v1 (
  p_session_token      text,
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
  v_type text := lower(trim(coalesce(p_request_type, '')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_proof_path text := nullif(trim(coalesce(p_proof_storage_path, '')), '');
  v_proof_name text := nullif(trim(coalesce(p_proof_file_name, '')), '');
  v_proof_mime text := lower(nullif(trim(coalesce(p_proof_mime_type, '')), ''));
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may request stock changes';
  end if;
  if v_type not in ('restock', 'write_off') then
    raise exception 'Unsupported approval request type';
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
    and upload.cleanup_claimed_at is null
  for update;
  if not found then
    raise exception 'Valid uploaded photo evidence is required';
  end if;
  if not exists (
    select 1
    from storage.objects evidence
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
    proof_storage_path, proof_file_name, proof_mime_type
  ) values (
    v_profile.location_id, v_type, v_profile.profile_id,
    v_profile.profile_name, v_profile.role, v_product.id,
    v_product.product_name, coalesce(v_product.sku, ''), v_product.unit,
    p_quantity, v_product.product_quantity, v_reason, v_note,
    v_upload.storage_path, v_upload.file_name, v_upload.mime_type
  ) returning * into v_request;

  delete from private.approval_evidence_uploads
  where id = v_upload.id;

  perform private.upsert_inventory_approval_notification_v1(v_request);
  return private.approval_request_json_v1(v_request);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text, text, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."create_inventory_approval_request_v1"(text, text, uuid, numeric, text, text, text, text, text) FROM PUBLIC, "authenticated";

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
    and upload.cleanup_claimed_at is null
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

commit;

-- SQL-first compatibility:
-- lifecycle_key, operation_id, and cleanup_claimed_at are nullable/additive.
-- Existing direct notification clients may omit lifecycle_key without failure.
-- Existing evidence v1 RPC signatures remain available.
-- Phase B1 and Phase B2A operational RPC signatures are preserved.

