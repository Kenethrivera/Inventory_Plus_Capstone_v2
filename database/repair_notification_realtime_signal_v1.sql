-- No notification content or recipient information is published here.
-- The client refetches notification_feed_v1 with its app session.
begin;

create table if not exists public.notification_realtime_signals (
  id boolean primary key default true,
  revision bigint not null default 0,
  changed_at timestamptz not null default clock_timestamp(),
  constraint notification_realtime_signals_one_row check (id)
);

alter table public.notification_realtime_signals enable row level security;
revoke all on public.notification_realtime_signals from public, anon, authenticated;
grant select on public.notification_realtime_signals to anon;
drop policy if exists notification_realtime_signals_anon_read
  on public.notification_realtime_signals;
create policy notification_realtime_signals_anon_read
  on public.notification_realtime_signals
  for select to anon using (true);

create or replace function public.signal_notification_change_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  insert into public.notification_realtime_signals (id, revision, changed_at)
  values (true, 1, clock_timestamp())
  on conflict (id) do update set
    revision = public.notification_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

revoke all on function public.signal_notification_change_v1()
  from public, anon, authenticated;

drop trigger if exists notifications_signal_realtime_v1 on public.notifications;
create trigger notifications_signal_realtime_v1
  after insert or update or delete on public.notifications
  for each row execute function public.signal_notification_change_v1();
drop trigger if exists notification_reads_signal_realtime_v1
  on public.notification_reads;
create trigger notification_reads_signal_realtime_v1
  after insert or update or delete on public.notification_reads
  for each row execute function public.signal_notification_change_v1();

do $publication$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notification_realtime_signals'
  ) then
    alter publication supabase_realtime
      add table public.notification_realtime_signals;
  end if;
end;
$publication$;

commit;
