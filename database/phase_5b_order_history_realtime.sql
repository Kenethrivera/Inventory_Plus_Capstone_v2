-- Phase 5B durable Sales History realtime invalidation.
--
-- public.order_history deliberately has no anon SELECT access. Supabase
-- Postgres Changes applies table privileges/RLS, so publishing that table
-- directly would either emit nothing to this custom-auth client or require
-- exposing sensitive order-history rows to anon. This trigger-maintained
-- table publishes only a location-scoped revision signal.

create table if not exists public.order_history_realtime_signals (
  location_id uuid primary key,
  revision bigint not null default 1,
  changed_at timestamptz not null default clock_timestamp()
);

alter table public.order_history_realtime_signals enable row level security;

revoke all on table public.order_history_realtime_signals from public;
revoke all on table public.order_history_realtime_signals
  from anon, authenticated;
grant select on table public.order_history_realtime_signals to anon;

drop policy if exists order_history_realtime_signals_anon_read
  on public.order_history_realtime_signals;
create policy order_history_realtime_signals_anon_read
  on public.order_history_realtime_signals
  for select
  to anon
  using (true);

create or replace function public.signal_order_history_change_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_location_id uuid;
begin
  -- If an order is ever moved between locations, invalidate both families.
  if tg_op = 'UPDATE'
     and old.location_id is distinct from new.location_id then
    insert into public.order_history_realtime_signals (
      location_id,
      revision,
      changed_at
    ) values (
      old.location_id,
      1,
      clock_timestamp()
    )
    on conflict (location_id) do update set
      revision = public.order_history_realtime_signals.revision + 1,
      changed_at = excluded.changed_at;
  end if;

  if tg_op = 'DELETE' then
    v_location_id := old.location_id;
  else
    v_location_id := new.location_id;
  end if;

  insert into public.order_history_realtime_signals (
    location_id,
    revision,
    changed_at
  ) values (
    v_location_id,
    1,
    clock_timestamp()
  )
  on conflict (location_id) do update set
    revision = public.order_history_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.signal_order_history_change_v1() from public;
revoke all on function public.signal_order_history_change_v1()
  from anon, authenticated;

drop trigger if exists order_history_signal_realtime_v1
  on public.order_history;
create trigger order_history_signal_realtime_v1
after insert or update or delete on public.order_history
for each row execute function public.signal_order_history_change_v1();

-- ALTER PUBLICATION has no IF NOT EXISTS form. Guard it so this migration is
-- safe to reapply and does not alter any unrelated publication membership.
do $$
begin
  if not exists (
    select 1
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'order_history_realtime_signals'
  ) then
    alter publication supabase_realtime
      add table public.order_history_realtime_signals;
  end if;
end;
$$;
