-- Stage 6B.5 data-integrity remediation candidate.
--
-- NOT APPLIED TO PRODUCTION. Test in an isolated project first. This migration
-- preserves existing malformed rows but prevents new completed snapshots from
-- being created or modified into an invalid state.

begin;

create table if not exists private.order_history_data_issues (
  issue_id uuid primary key default extensions.gen_random_uuid(),
  order_id text not null,
  issue_code text not null check (issue_code in (
    'missing_completed_at',
    'missing_items',
    'malformed_item',
    'inconsistent_unit',
    'unmatched_product'
  )),
  status text not null default 'unresolved' check (status in (
    'unresolved',
    'corrected_with_evidence',
    'unrecoverable'
  )),
  original_snapshot jsonb not null,
  evidence jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_profile_id bigint,
  resolution_note text,
  unique (order_id, issue_code)
);

alter table private.order_history_data_issues enable row level security;
revoke all on table private.order_history_data_issues
  from public, anon, authenticated, service_role;
grant select, insert, update on table private.order_history_data_issues
  to postgres;

create or replace function private.assert_completed_order_snapshot_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_item jsonb;
  v_product_id text;
  v_quantity text;
begin
  if lower(trim(coalesce(new.status, ''))) <> 'completed' then
    return new;
  end if;
  if new.completed_at is null then
    raise exception 'completed_order_timestamp_required';
  end if;
  if jsonb_typeof(new.items) is distinct from 'array'
      or jsonb_array_length(new.items) = 0 then
    raise exception 'order_item_snapshot_invalid';
  end if;

  for v_item in select value from jsonb_array_elements(new.items)
  loop
    v_product_id := coalesce(
      v_item ->> 'product_id', v_item ->> 'productId', '');
    v_quantity := coalesce(v_item ->> 'quantity', '');
    if v_product_id
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        or v_quantity !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'order_item_snapshot_invalid';
    end if;
    if v_quantity::numeric <= 0 then
      raise exception 'order_item_snapshot_invalid';
    end if;
  end loop;
  return new;
end;
$function$;

revoke all on function private.assert_completed_order_snapshot_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists orders_validate_completed_snapshot_v1
  on public.orders;
create trigger orders_validate_completed_snapshot_v1
before insert or update of status, items, completed_at on public.orders
for each row execute function private.assert_completed_order_snapshot_v1();

drop trigger if exists order_history_validate_completed_snapshot_v1
  on public.order_history;
create trigger order_history_validate_completed_snapshot_v1
before insert or update of status, items, completed_at on public.order_history
for each row execute function private.assert_completed_order_snapshot_v1();

-- Existing rows are deliberately not changed. Capture them in the private
-- audit ledger only after an authorized operator reviews the affected order.
-- Never infer item lines from inventory movements alone.

commit;
