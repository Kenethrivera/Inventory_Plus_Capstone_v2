-- Apply after phase_bodegero_loading.sql and phase_b2b_notification_upload_safety.sql.

-- Enables Bodegero stock requests and scoped loading history.

begin;

ALTER TABLE public.approval_requests
  DROP CONSTRAINT IF EXISTS approval_requests_requested_by_role_check;
ALTER TABLE public.approval_requests
  ADD CONSTRAINT approval_requests_requested_by_role_check
  CHECK (requested_by_role IN ('helper', 'bodegero', 'staff', 'cashier'));

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
  if v_profile.role not in ('helper', 'bodegero', 'staff', 'cashier') then
    raise exception 'Only Cashier, Helper, or Bodegero accounts may upload proof';
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
  if v_profile.role not in ('helper', 'bodegero', 'staff', 'cashier') then
    raise exception 'Only Cashier, Helper, or Bodegero accounts may request stock changes';
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
  if v_proof_path is null then
    raise exception 'A supporting photo is required for stock requests';
  end if;
  if v_proof_path is not null or v_proof_name is not null or v_proof_mime is not null then
    if v_proof_path is null or v_proof_name is null or v_proof_mime is null then
      raise exception 'Photo evidence details are incomplete';
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
    v_proof_path, v_proof_name, v_proof_mime,
    v_operation_id
  ) returning * into v_request;

  if v_proof_path is not null then
    delete from private.approval_evidence_uploads where id = v_upload.id;
  end if;
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

CREATE OR REPLACE FUNCTION public.my_inventory_approval_requests_v1 (
  p_session_token text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_records jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'bodegero', 'staff', 'cashier') then
    raise exception 'Only Cashier, Helper, or Bodegero accounts may view requests';
  end if;

  select coalesce(jsonb_agg(private.approval_request_json_v1(scoped.row_value)
    order by scoped.requested_at desc, scoped.id desc), '[]'::jsonb)
  into v_records
  from (
    select request as row_value, request.requested_at, request.id
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.requested_by_id = v_profile.profile_id
      and request.request_type in ('restock', 'write_off')
    order by request.requested_at desc, request.id desc
    limit 30
  ) scoped;

  return v_records;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.my_inventory_approval_requests_v1(text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.my_inventory_approval_requests_v1(text)
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.bodegero_loading_history_v1(
  p_session_token text,
  p_page integer DEFAULT 1,
  p_search text DEFAULT '',
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_actor record;
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_search text := lower(trim(coalesce(p_search, '')));
  v_total integer;
  v_records jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM private.require_app_session_v1(p_session_token);
  IF NOT FOUND OR v_actor.role <> 'bodegero' THEN
    RAISE EXCEPTION 'Bodegero session required' USING errcode = '42501';
  END IF;

  WITH scoped AS (
    SELECT proof.order_id, proof.truck_plate, proof.captured_at,
      orders.status, orders.items
    FROM public.order_loading_proofs proof
    JOIN public.orders orders ON orders.id = proof.order_id
    WHERE proof.location_id = v_actor.location_id
      AND orders.location_id = v_actor.location_id
      AND proof.bodegero_id = v_actor.profile_id
      AND (
        v_search = ''
        OR strpos(lower(proof.order_id::text), v_search) > 0
        OR strpos(lower(proof.truck_plate), v_search) > 0
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(coalesce(orders.items::jsonb, '[]'::jsonb)) item
          WHERE coalesce(item ->> 'requires_loading', 'false') = 'true'
            AND strpos(lower(coalesce(item ->> 'product_name', '')), v_search) > 0
        )
      )
  ), page_rows AS (
    SELECT * FROM scoped
    ORDER BY captured_at DESC, order_id DESC
    OFFSET (v_page::bigint - 1) * v_page_size LIMIT v_page_size
  )
  SELECT
    (SELECT count(*) FROM scoped),
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'order_id', row.order_id,
        'truck_plate', row.truck_plate,
        'captured_at', row.captured_at,
        'status', row.status,
        'items', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'product_name', coalesce(item ->> 'product_name', 'Unknown product'),
            'quantity', item -> 'quantity'
          ))
          FROM jsonb_array_elements(coalesce(row.items::jsonb, '[]'::jsonb)) item
          WHERE coalesce(item ->> 'requires_loading', 'false') = 'true'
        ), '[]'::jsonb)
      ) ORDER BY row.captured_at DESC, row.order_id DESC)
      FROM page_rows row
    ), '[]'::jsonb)
  INTO v_total, v_records;

  RETURN jsonb_build_object(
    'records', v_records,
    'total_count', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.bodegero_loading_history_v1(text, integer, text, integer)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.bodegero_loading_history_v1(text, integer, text, integer)
  TO anon, service_role;

commit;
