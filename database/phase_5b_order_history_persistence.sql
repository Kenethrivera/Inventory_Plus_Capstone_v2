-- Phase 5B durable logical order history.
-- Apply through the normal migration process only; the application never
-- executes this file. This migration is independent of History read access.

create table if not exists public.order_history (
  order_id text primary key,
  location_id uuid not null,
  status text not null,
  items jsonb not null default '[]'::jsonb,
  created_at timestamptz not null,
  event_at timestamptz not null,
  assigned_at timestamptz,
  prepared_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  returned_at timestamptz,
  created_by_id text,
  created_by_name text,
  assigned_helper_id text,
  assigned_helper_name text,
  prepared_by_id text,
  prepared_by_name text,
  completed_by_id text,
  completed_by_name text,
  cancelled_by_id text,
  cancelled_by_name text,
  returned_by_id text,
  returned_by_name text,
  total_amount numeric not null default 0,
  discount_amount numeric not null default 0,
  payment_mode text,
  cash_given numeric,
  change_amount numeric,
  snapshot_updated_at timestamptz not null default now()
);

-- Existing Phase 5B deployments predate event_at. Backfill it from business
-- timestamps before enforcing NOT NULL; snapshot_updated_at is intentionally
-- excluded because it is persistence metadata rather than a lifecycle event.
alter table public.order_history
  add column if not exists event_at timestamptz;

update public.order_history
set event_at = coalesce(greatest(
  created_at,
  assigned_at,
  prepared_at,
  completed_at,
  cancelled_at,
  returned_at
), created_at)
where event_at is distinct from coalesce(greatest(
  created_at,
  assigned_at,
  prepared_at,
  completed_at,
  cancelled_at,
  returned_at
), created_at);

alter table public.order_history
  alter column event_at set not null;

-- There is deliberately no anon SELECT policy. The separate History migration
-- exposes only token-bound, explicitly projected read RPCs.
alter table public.order_history enable row level security;
revoke all on table public.order_history from public;
revoke all on table public.order_history from anon, authenticated;

-- This is a write-only trigger boundary, not a privileged client read tunnel.
-- A trigger failure rolls back the corresponding operational order mutation,
-- ensuring an acknowledged lifecycle transition cannot omit its snapshot.
create or replace function public.sync_order_history_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_returned_by_name text;
  v_event_at timestamptz;
begin
  v_event_at := coalesce(greatest(
    new.created_at,
    new.assigned_at,
    new.prepared_at,
    new.completed_at,
    new.cancelled_at,
    new.returned_at
  ), new.created_at);

  if new.returned_by_id is not null then
    select profile.name
      into v_returned_by_name
      from public.profiles profile
     where profile.id::text = new.returned_by_id::text;
  end if;

  insert into public.order_history (
    order_id, location_id, status, items, created_at, event_at,
    assigned_at, prepared_at, completed_at, cancelled_at, returned_at,
    created_by_id, created_by_name,
    assigned_helper_id, assigned_helper_name,
    prepared_by_id, prepared_by_name,
    completed_by_id, completed_by_name,
    cancelled_by_id, cancelled_by_name,
    returned_by_id, returned_by_name,
    total_amount, discount_amount, payment_mode, cash_given, change_amount,
    snapshot_updated_at
  ) values (
    new.id::text, new.location_id, new.status,
    coalesce(new.items::jsonb, '[]'::jsonb), new.created_at, v_event_at,
    new.assigned_at, new.prepared_at, new.completed_at,
    new.cancelled_at, new.returned_at,
    new.created_by_id::text, new.created_by_name,
    new.assigned_helper_id::text, new.assigned_helper_name,
    new.prepared_by_id::text, new.prepared_by_name,
    new.completed_by_id::text, new.completed_by_name,
    new.cancelled_by_id::text, new.cancelled_by_name,
    new.returned_by_id::text, v_returned_by_name,
    coalesce(new.total_amount, 0), coalesce(new.discount_amount, 0),
    new.payment_mode, new.cash_given, new.change_amount, now()
  )
  on conflict (order_id) do update set
    location_id = excluded.location_id,
    status = excluded.status,
    items = excluded.items,
    created_at = excluded.created_at,
    event_at = excluded.event_at,
    assigned_at = excluded.assigned_at,
    prepared_at = excluded.prepared_at,
    completed_at = excluded.completed_at,
    cancelled_at = excluded.cancelled_at,
    returned_at = excluded.returned_at,
    created_by_id = excluded.created_by_id,
    created_by_name = excluded.created_by_name,
    assigned_helper_id = excluded.assigned_helper_id,
    assigned_helper_name = excluded.assigned_helper_name,
    prepared_by_id = excluded.prepared_by_id,
    prepared_by_name = excluded.prepared_by_name,
    completed_by_id = excluded.completed_by_id,
    completed_by_name = excluded.completed_by_name,
    cancelled_by_id = excluded.cancelled_by_id,
    cancelled_by_name = excluded.cancelled_by_name,
    returned_by_id = excluded.returned_by_id,
    returned_by_name = coalesce(
      excluded.returned_by_name, public.order_history.returned_by_name),
    total_amount = excluded.total_amount,
    discount_amount = excluded.discount_amount,
    payment_mode = excluded.payment_mode,
    cash_given = excluded.cash_given,
    change_amount = excluded.change_amount,
    snapshot_updated_at = excluded.snapshot_updated_at;

  return new;
end;
$$;

revoke all on function public.sync_order_history_v1() from public;
revoke all on function public.sync_order_history_v1()
  from anon, authenticated;

drop trigger if exists orders_sync_order_history_v1 on public.orders;
create trigger orders_sync_order_history_v1
after insert or update on public.orders
for each row execute function public.sync_order_history_v1();

-- Capture any operational rows that existed before this trigger was installed.
-- The same logical key and ON CONFLICT update make this safe to rerun.
insert into public.order_history (
  order_id, location_id, status, items, created_at, event_at,
  assigned_at, prepared_at, completed_at, cancelled_at, returned_at,
  created_by_id, created_by_name,
  assigned_helper_id, assigned_helper_name,
  prepared_by_id, prepared_by_name,
  completed_by_id, completed_by_name,
  cancelled_by_id, cancelled_by_name,
  returned_by_id, returned_by_name,
  total_amount, discount_amount, payment_mode, cash_given, change_amount,
  snapshot_updated_at
)
select
  o.id::text, o.location_id, o.status,
  coalesce(o.items::jsonb, '[]'::jsonb), o.created_at,
  coalesce(greatest(
    o.created_at,
    o.assigned_at,
    o.prepared_at,
    o.completed_at,
    o.cancelled_at,
    o.returned_at
  ), o.created_at),
  o.assigned_at, o.prepared_at, o.completed_at,
  o.cancelled_at, o.returned_at,
  o.created_by_id::text, o.created_by_name,
  o.assigned_helper_id::text, o.assigned_helper_name,
  o.prepared_by_id::text, o.prepared_by_name,
  o.completed_by_id::text, o.completed_by_name,
  o.cancelled_by_id::text, o.cancelled_by_name,
  o.returned_by_id::text, (
    select profile.name from public.profiles profile
    where profile.id::text = o.returned_by_id::text
  ),
  coalesce(o.total_amount, 0), coalesce(o.discount_amount, 0),
  o.payment_mode, o.cash_given, o.change_amount, now()
from public.orders o
on conflict (order_id) do update set
  location_id = excluded.location_id,
  status = excluded.status,
  items = excluded.items,
  created_at = excluded.created_at,
  event_at = excluded.event_at,
  assigned_at = excluded.assigned_at,
  prepared_at = excluded.prepared_at,
  completed_at = excluded.completed_at,
  cancelled_at = excluded.cancelled_at,
  returned_at = excluded.returned_at,
  created_by_id = excluded.created_by_id,
  created_by_name = excluded.created_by_name,
  assigned_helper_id = excluded.assigned_helper_id,
  assigned_helper_name = excluded.assigned_helper_name,
  prepared_by_id = excluded.prepared_by_id,
  prepared_by_name = excluded.prepared_by_name,
  completed_by_id = excluded.completed_by_id,
  completed_by_name = excluded.completed_by_name,
  cancelled_by_id = excluded.cancelled_by_id,
  cancelled_by_name = excluded.cancelled_by_name,
  returned_by_id = excluded.returned_by_id,
  returned_by_name = coalesce(
    excluded.returned_by_name, public.order_history.returned_by_name),
  total_amount = excluded.total_amount,
  discount_amount = excluded.discount_amount,
  payment_mode = excluded.payment_mode,
  cash_given = excluded.cash_given,
  change_amount = excluded.change_amount,
  snapshot_updated_at = excluded.snapshot_updated_at;

-- Replace the earlier expression index with the canonical lifecycle ordering
-- index. Reusing the same name prevents duplicate equivalent indexes.
drop index if exists public.order_history_event_idx;
create index order_history_event_idx on public.order_history (
  location_id, event_at desc, order_id desc
);

-- Actor membership is an OR across lifecycle roles. Separate indexes allow a
-- bitmap OR plan instead of making later columns unusable behind another actor.
create index if not exists order_history_created_actor_idx
  on public.order_history (location_id, created_by_id);
create index if not exists order_history_completed_actor_idx
  on public.order_history (location_id, completed_by_id);
create index if not exists order_history_cancelled_actor_idx
  on public.order_history (location_id, cancelled_by_id);
create index if not exists order_history_returned_actor_idx
  on public.order_history (location_id, returned_by_id);
create index if not exists order_history_assigned_helper_idx
  on public.order_history (location_id, assigned_helper_id);
create index if not exists order_history_prepared_helper_idx
  on public.order_history (location_id, prepared_by_id);
