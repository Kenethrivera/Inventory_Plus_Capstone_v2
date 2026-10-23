-- Phase 2A durable Restock / Write-off approval workflow.
--
-- Apply through the normal migration process only. This file is intentionally
-- not executed by the application or by Codex.
--
-- Requires database/phase_5b_app_sessions.sql because every RPC derives the
-- live profile, role, and location from the opaque application session token.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.approval_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  location_id uuid not null,
  request_type text not null check (request_type in ('restock', 'write_off')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  requested_by_id bigint not null references public.profiles(id),
  requested_by_name text not null,
  requested_by_role text not null
    check (requested_by_role in ('helper', 'staff', 'cashier')),
  requested_at timestamptz not null default now(),
  reviewed_by_id bigint references public.profiles(id),
  reviewed_by_name text,
  reviewed_at timestamptz,
  product_id bigint not null references public.products(id),
  product_name text not null,
  product_sku text not null default '',
  unit text not null default 'pcs',
  requested_quantity numeric not null check (requested_quantity > 0),
  stock_at_request numeric not null check (stock_at_request >= 0),
  reason text,
  note text,
  review_note text,
  transaction_id bigint,
  request_payload jsonb not null default '{}'::jsonb,
  constraint approval_request_write_off_reason check (
    request_type <> 'write_off' or nullif(trim(reason), '') is not null
  )
);

alter table public.approval_requests enable row level security;
revoke all on table public.approval_requests from public, anon, authenticated;

create index if not exists approval_requests_location_status_requested_idx
  on public.approval_requests (
    location_id, status, requested_at desc, id desc
  );

create index if not exists approval_requests_requester_requested_idx
  on public.approval_requests (
    location_id, requested_by_id, requested_at desc
  );

-- The approval rows remain private to token-bound RPCs. Postgres Changes
-- therefore uses the same privacy-preserving, location-only invalidation
-- pattern as order_history.
create table if not exists public.approval_request_realtime_signals (
  location_id uuid primary key,
  revision bigint not null default 1,
  changed_at timestamptz not null default clock_timestamp()
);

alter table public.approval_request_realtime_signals enable row level security;
revoke all on table public.approval_request_realtime_signals from public;
revoke all on table public.approval_request_realtime_signals
  from anon, authenticated;
grant select on table public.approval_request_realtime_signals to anon;

drop policy if exists approval_request_realtime_signals_anon_read
  on public.approval_request_realtime_signals;
create policy approval_request_realtime_signals_anon_read
  on public.approval_request_realtime_signals
  for select to anon using (true);

create or replace function public.signal_approval_request_change_v1()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_location_id uuid;
begin
  if tg_op = 'UPDATE'
     and old.location_id is distinct from new.location_id then
    insert into public.approval_request_realtime_signals (
      location_id, revision, changed_at
    ) values (old.location_id, 1, clock_timestamp())
    on conflict (location_id) do update set
      revision = public.approval_request_realtime_signals.revision + 1,
      changed_at = excluded.changed_at;
  end if;

  v_location_id := case when tg_op = 'DELETE'
    then old.location_id else new.location_id end;

  insert into public.approval_request_realtime_signals (
    location_id, revision, changed_at
  ) values (v_location_id, 1, clock_timestamp())
  on conflict (location_id) do update set
    revision = public.approval_request_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.signal_approval_request_change_v1()
  from public, anon, authenticated;

drop trigger if exists approval_request_signal_realtime_v1
  on public.approval_requests;
create trigger approval_request_signal_realtime_v1
after insert or update or delete on public.approval_requests
for each row execute function public.signal_approval_request_change_v1();

create or replace function private.approval_request_json_v1(
  p_request public.approval_requests
) returns jsonb
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  select jsonb_build_object(
    'id', p_request.id,
    'location_id', p_request.location_id,
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
    'current_stock', coalesce((
      select product.product_quantity
      from public.products product
      where product.id = p_request.product_id
        and product.location_id = p_request.location_id
    ), p_request.stock_at_request),
    'reason', p_request.reason,
    'note', p_request.note,
    'review_note', p_request.review_note,
    'transaction_id', p_request.transaction_id
  )
$$;

revoke all on function private.approval_request_json_v1(
  public.approval_requests
) from public, anon, authenticated;

-- Persist the existing notification lifecycle in the same transaction as the
-- request transition. Flutter still reconciles this row through the existing
-- NotificationService identity `inventory-approval:<request id>`.
create or replace function private.upsert_inventory_approval_notification_v1(
  p_request public.approval_requests
) returns void
language plpgsql volatile security definer
set search_path = public, private, pg_temp
as $$
declare
  v_notification_id public.notifications.id%type;
  v_action text := case p_request.request_type
    when 'restock' then 'Restock' else 'Write-off' end;
  v_title text;
  v_body text;
  v_target_roles text[];
  v_priority text;
  v_payload jsonb;
begin
  if p_request.status = 'pending' then
    v_title := v_action || ' approval requested';
    v_body := p_request.requested_by_name || ' requested ' || v_action ||
      ' of ' || p_request.requested_quantity || ' ' || p_request.unit ||
      ' for ' || p_request.product_name || '.';
    v_target_roles := array['admin']::text[];
    v_priority := 'high';
  else
    v_title := v_action || ' request ' || p_request.status;
    v_body := 'Your ' || v_action || ' request for ' ||
      p_request.requested_quantity || ' ' || p_request.unit || ' of ' ||
      p_request.product_name || ' was ' || p_request.status || '.';
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
    'requestedById', p_request.requested_by_id,
    'requestedByName', p_request.requested_by_name,
    'recipientId', case when p_request.status = 'pending'
      then null else to_jsonb(p_request.requested_by_id) end
  );

  select notification.id into v_notification_id
  from public.notifications notification
  where notification.location_id = p_request.location_id
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
      p_request.location_id, v_target_roles, v_title, v_body, 'system',
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
  where notification.location_id = p_request.location_id
    and notification.id <> v_notification_id
    and notification.is_resolved = false
    and notification.type = 'system'
    and notification.payload ->> 'category' = 'inventoryApproval'
    and notification.payload ->> 'approvalRequestId' = p_request.id::text;
end;
$$;

revoke all on function private.upsert_inventory_approval_notification_v1(
  public.approval_requests
) from public, anon, authenticated;

create or replace function public.create_inventory_approval_request_v1(
  p_session_token text,
  p_request_type text,
  p_product_id bigint,
  p_quantity numeric,
  p_reason text default null,
  p_note text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_product record;
  v_request public.approval_requests;
  v_type text := lower(trim(coalesce(p_request_type, '')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_note text := nullif(trim(coalesce(p_note, '')), '');
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
    requested_quantity, stock_at_request, reason, note, request_payload
  ) values (
    v_profile.location_id, v_type, v_profile.profile_id,
    v_profile.profile_name, v_profile.role, v_product.id,
    v_product.product_name, coalesce(v_product.sku, ''), v_product.unit,
    p_quantity, v_product.product_quantity, v_reason, v_note,
    jsonb_build_object(
      'product_id', v_product.id,
      'product_name', v_product.product_name,
      'product_sku', coalesce(v_product.sku, ''),
      'unit', v_product.unit,
      'requested_quantity', p_quantity,
      'reason', v_reason,
      'note', v_note
    )
  ) returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);

  return private.approval_request_json_v1(v_request);
end;
$$;

create or replace function public.approval_requests_page_v1(
  p_session_token text,
  p_status text default 'pending',
  p_page integer default 1,
  p_page_size integer default 20
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_status text := lower(trim(coalesce(p_status, 'pending')));
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_total integer;
  v_records jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may review approval requests';
  end if;
  if v_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Unsupported approval status';
  end if;

  select count(*)::integer into v_total
  from public.approval_requests request
  where request.location_id = v_profile.location_id
    and request.status = v_status;

  select coalesce(jsonb_agg(private.approval_request_json_v1(scoped.row_value)
      order by scoped.requested_at desc, scoped.id desc), '[]'::jsonb)
    into v_records
  from (
    select request as row_value, request.requested_at, request.id
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.status = v_status
    order by request.requested_at desc, request.id desc
    limit v_page_size
    offset ((v_page - 1)::bigint * v_page_size::bigint)
  ) scoped;

  return jsonb_build_object(
    'records', v_records,
    'total_count', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
end;
$$;

create or replace function public.approve_inventory_approval_request_v1(
  p_session_token text,
  p_request_id uuid,
  p_review_note text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_request public.approval_requests;
  v_product record;
  v_new_quantity numeric;
  v_transaction_id bigint;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may approve stock changes';
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
    when 'restock' then v_product.product_quantity + v_request.requested_quantity
    else v_product.product_quantity - v_request.requested_quantity
  end;

  update public.products
  set product_quantity = v_new_quantity
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
      then v_request.requested_quantity else -v_request.requested_quantity end,
    v_new_quantity, v_profile.location_id, v_request.requested_by_id,
    v_request.requested_by_name,
    concat_ws(': ',
      case when v_request.request_type = 'write_off'
        then v_request.reason else null end,
      nullif(v_request.note, ''),
      'Approved by ' || v_profile.profile_name
    )
  ) returning id into v_transaction_id;

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
$$;

create or replace function public.reject_inventory_approval_request_v1(
  p_session_token text,
  p_request_id uuid,
  p_review_note text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_request public.approval_requests;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may reject stock changes';
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

  update public.approval_requests
  set status = 'rejected',
      reviewed_by_id = v_profile.profile_id,
      reviewed_by_name = v_profile.profile_name,
      reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_review_note, '')), '')
  where id = v_request.id
  returning * into v_request;

  perform private.upsert_inventory_approval_notification_v1(v_request);

  return private.approval_request_json_v1(v_request);
end;
$$;

revoke all on function public.create_inventory_approval_request_v1(
  text, text, bigint, numeric, text, text
) from public, authenticated;
revoke all on function public.approval_requests_page_v1(
  text, text, integer, integer
) from public, authenticated;
revoke all on function public.approve_inventory_approval_request_v1(
  text, uuid, text
) from public, authenticated;
revoke all on function public.reject_inventory_approval_request_v1(
  text, uuid, text
) from public, authenticated;

grant execute on function public.create_inventory_approval_request_v1(
  text, text, bigint, numeric, text, text
) to anon;
grant execute on function public.approval_requests_page_v1(
  text, text, integer, integer
) to anon;
grant execute on function public.approve_inventory_approval_request_v1(
  text, uuid, text
) to anon;
grant execute on function public.reject_inventory_approval_request_v1(
  text, uuid, text
) to anon;

-- This is the only publication addition. It is required because the private
-- approval rows themselves cannot safely be exposed to the anon custom-auth
-- client, while Admin/requester clients still need centralized invalidation.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'approval_request_realtime_signals'
  ) then
    alter publication supabase_realtime
      add table public.approval_request_realtime_signals;
  end if;
end;
$$;
