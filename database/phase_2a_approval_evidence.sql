-- Phase 2A refinement: durable proof images for new inventory approvals.
-- Deploy after database/phase_2a_inventory_approvals.sql.

alter table public.approval_requests
  add column if not exists proof_storage_path text,
  add column if not exists proof_file_name text,
  add column if not exists proof_mime_type text;

create table if not exists private.approval_evidence_uploads (
  id uuid primary key default extensions.gen_random_uuid(),
  location_id uuid not null references public.locations(id),
  requested_by_id bigint not null references public.profiles(id),
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (
    mime_type in ('image/jpeg', 'image/png', 'image/webp', 'image/gif')
  ),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes')
);

revoke all on table private.approval_evidence_uploads
  from public, anon, authenticated;

-- Private bucket. The approval-evidence Edge Function mediates uploads and
-- short-lived signed reads with the server-side service role.
insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'approval_evidence',
  'approval_evidence',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.prepare_inventory_approval_evidence_v1(
  p_session_token text,
  p_file_name text,
  p_mime_type text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
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

  delete from private.approval_evidence_uploads
  where expires_at <= now();

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
$$;

revoke all on function public.prepare_inventory_approval_evidence_v1(
  text, text, text
) from public, authenticated;
grant execute on function public.prepare_inventory_approval_evidence_v1(
  text, text, text
) to anon, service_role;

create or replace function public.inventory_approval_evidence_access_v1(
  p_session_token text,
  p_request_id uuid
) returns text
language plpgsql stable security definer
set search_path = public, private, pg_temp
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
  select request.* into v_request
  from public.approval_requests request
  where request.id = p_request_id;
  if not found or v_request.location_id <> v_profile.location_id then
    raise exception 'Approval evidence is unavailable';
  end if;
  if v_profile.role <> 'admin'
      and v_request.requested_by_id <> v_profile.profile_id then
    raise exception 'Approval evidence is unavailable';
  end if;
  return v_request.proof_storage_path;
end;
$$;

revoke all on function public.inventory_approval_evidence_access_v1(
  text, uuid
) from public, authenticated;
grant execute on function public.inventory_approval_evidence_access_v1(
  text, uuid
) to anon, service_role;

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
    'transaction_id', p_request.transaction_id,
    'proof_storage_path', p_request.proof_storage_path,
    'proof_file_name', p_request.proof_file_name,
    'proof_mime_type', p_request.proof_mime_type
  )
$$;

revoke all on function private.approval_request_json_v1(
  public.approval_requests
) from public, anon, authenticated;

drop function public.create_inventory_approval_request_v1(
  text, text, uuid, numeric, text, text
);

create function public.create_inventory_approval_request_v1(
  p_session_token text,
  p_request_type text,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text,
  p_note text,
  p_proof_storage_path text,
  p_proof_file_name text,
  p_proof_mime_type text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
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
$$;

revoke all on function public.create_inventory_approval_request_v1(
  text, text, uuid, numeric, text, text, text, text, text
) from public, authenticated;
grant execute on function public.create_inventory_approval_request_v1(
  text, text, uuid, numeric, text, text, text, text, text
) to anon;
