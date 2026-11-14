-- Apply after phase_bodegero_worker_tabs.sql.
-- Existing requests without photos remain readable. New stock requests require one.

begin;

alter table public.approval_requests
  drop constraint if exists approval_requests_requested_by_role_check;
alter table public.approval_requests
  add constraint approval_requests_requested_by_role_check
  check (requested_by_role in ('helper', 'bodegero', 'staff', 'cashier'));

alter table public.approval_requests
  drop constraint if exists approval_request_stock_photo_required;
alter table public.approval_requests
  add constraint approval_request_stock_photo_required
  check (
    request_type not in ('restock', 'write_off')
    or (
      nullif(btrim(proof_storage_path), '') is not null
      and nullif(btrim(proof_file_name), '') is not null
      and nullif(btrim(proof_mime_type), '') is not null
    )
  ) not valid;

commit;
