-- Apply after phase_bodegero_loading.sql and phase_5b_order_history_persistence.sql.
-- Loading clocks are server timestamps. Completed results survive order cleanup.
begin;

create table if not exists public.bodegero_loading_clocks (
  order_id uuid primary key references public.orders(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  bodegero_id bigint not null references public.profiles(id),
  assigned_at timestamptz not null,
  started_at timestamptz,
  paused_at timestamptz,
  paused_seconds numeric not null default 0,
  finished_at timestamptz,
  constraint bodegero_clock_pause_nonnegative check (paused_seconds >= 0)
);
create index if not exists bodegero_loading_clocks_staff_idx
  on public.bodegero_loading_clocks (location_id, bodegero_id, assigned_at);
alter table public.bodegero_loading_clocks enable row level security;
revoke all on public.bodegero_loading_clocks from public, anon, authenticated;

alter table public.order_history
  add column if not exists assigned_bodegero_id text,
  add column if not exists assigned_bodegero_name text,
  add column if not exists bodegero_assigned_at timestamptz,
  add column if not exists loading_started_at timestamptz,
  add column if not exists loading_verified_at timestamptz,
  add column if not exists loading_paused_seconds numeric;

-- The existing history trigger runs first. This trigger saves the loading clock
-- and a durable copy of its final timing in the same transaction as the order.
create or replace function private.sync_bodegero_loading_clock_v1()
returns trigger language plpgsql security definer
set search_path = public, private, pg_temp as $$
declare
  v_clock public.bodegero_loading_clocks%rowtype;
  v_assignment_changed boolean;
begin
  if new.assigned_bodegero_id is not null then
    if tg_op = 'INSERT' then
      v_assignment_changed := true;
    else
      v_assignment_changed := old.assigned_bodegero_id is distinct from new.assigned_bodegero_id;
    end if;
    if v_assignment_changed then
      insert into public.bodegero_loading_clocks
        (order_id, location_id, bodegero_id, assigned_at)
      values (new.id, new.location_id, new.assigned_bodegero_id::bigint, now())
      on conflict (order_id) do update set
        bodegero_id = excluded.bodegero_id,
        assigned_at = excluded.assigned_at,
        started_at = null, paused_at = null,
        paused_seconds = 0, finished_at = null;
    end if;
    if new.loading_verified_at is not null then
      update public.bodegero_loading_clocks set
        finished_at = coalesce(finished_at, new.loading_verified_at),
        paused_seconds = paused_seconds + case when paused_at is null then 0
          else extract(epoch from (new.loading_verified_at - paused_at)) end,
        paused_at = null
      where order_id = new.id and finished_at is null;
    end if;
    select * into v_clock from public.bodegero_loading_clocks where order_id = new.id;
  end if;
  update public.order_history set
    assigned_bodegero_id = new.assigned_bodegero_id,
    assigned_bodegero_name = new.assigned_bodegero_name,
    bodegero_assigned_at = v_clock.assigned_at,
    loading_started_at = v_clock.started_at,
    loading_verified_at = new.loading_verified_at,
    loading_paused_seconds = v_clock.paused_seconds
  where order_id = new.id::text;
  return new;
end;
$$;
revoke all on function private.sync_bodegero_loading_clock_v1()
  from public, anon, authenticated;
drop trigger if exists orders_zz_bodegero_clock_v1 on public.orders;
create trigger orders_zz_bodegero_clock_v1
after insert or update on public.orders for each row
execute function private.sync_bodegero_loading_clock_v1();

-- Existing completed proofs can be reported, but have no trustworthy start
-- time and therefore cannot contribute to a timed score.
insert into public.bodegero_loading_clocks
  (order_id, location_id, bodegero_id, assigned_at, finished_at)
select o.id, o.location_id, o.assigned_bodegero_id::bigint, o.created_at,
  o.loading_verified_at
from public.orders o
where o.assigned_bodegero_id is not null
on conflict (order_id) do nothing;
update public.order_history h set
  assigned_bodegero_id = o.assigned_bodegero_id,
  assigned_bodegero_name = o.assigned_bodegero_name,
  bodegero_assigned_at = c.assigned_at,
  loading_started_at = c.started_at,
  loading_verified_at = o.loading_verified_at,
  loading_paused_seconds = c.paused_seconds
from public.orders o left join public.bodegero_loading_clocks c on c.order_id = o.id
where h.order_id = o.id::text;

create or replace function public.start_order_loading_clock_v1(
  p_session_token text, p_order_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp as $$
declare v_actor record; v_clock public.bodegero_loading_clocks%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'bodegero_required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.staff_presence presence
    where presence.user_id = v_actor.profile_id::text
      and presence.location_id = v_actor.location_id::text
      and lower(presence.user_role) = 'bodegero'
      and presence.is_online = true
      and presence.logged_out_at is null
      and presence.last_seen_at >= now() - interval '2 minutes'
  ) then
    raise exception 'bodegero_unavailable' using errcode = '42501';
  end if;
  select c.* into v_clock from public.bodegero_loading_clocks c
  join public.orders o on o.id = c.order_id
  where c.order_id = p_order_id and c.location_id = v_actor.location_id
    and c.bodegero_id = v_actor.profile_id
    and o.loading_verified_at is null
    and o.status in ('pending', 'solo_picking') for update of c;
  if not found then raise exception 'loading_assignment_conflict'; end if;
  update public.bodegero_loading_clocks
  set started_at = coalesce(started_at, now())
  where order_id = p_order_id returning * into v_clock;
  return jsonb_build_object('started_at', v_clock.started_at,
    'paused', v_clock.paused_at is not null);
end;
$$;
revoke all on function public.start_order_loading_clock_v1(text, uuid)
  from public, authenticated;
grant execute on function public.start_order_loading_clock_v1(text, uuid)
  to anon, service_role;

create or replace function public.set_order_loading_pause_v1(
  p_session_token text, p_order_id uuid, p_paused boolean
) returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp as $$
declare v_actor record; v_clock public.bodegero_loading_clocks%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'bodegero_required' using errcode = '42501';
  end if;
  select c.* into v_clock from public.bodegero_loading_clocks c
  join public.orders o on o.id = c.order_id
  where c.order_id = p_order_id and c.location_id = v_actor.location_id
    and c.bodegero_id = v_actor.profile_id
    and c.started_at is not null and c.finished_at is null
    and o.loading_verified_at is null
    and o.status in ('pending', 'solo_picking') for update of c;
  if not found then raise exception 'loading_assignment_conflict'; end if;
  if p_paused is null then raise exception 'pause_state_required'; end if;
  if p_paused and v_clock.paused_at is null then
    update public.bodegero_loading_clocks set paused_at = now()
    where order_id = p_order_id returning * into v_clock;
  elsif not p_paused and v_clock.paused_at is not null then
    update public.bodegero_loading_clocks set
      paused_seconds = paused_seconds + extract(epoch from (now() - paused_at)),
      paused_at = null
    where order_id = p_order_id returning * into v_clock;
  end if;
  return jsonb_build_object('started_at', v_clock.started_at,
    'paused', v_clock.paused_at is not null);
end;
$$;
revoke all on function public.set_order_loading_pause_v1(text, uuid, boolean)
  from public, authenticated;
grant execute on function public.set_order_loading_pause_v1(text, uuid, boolean)
  to anon, service_role;

-- Bodegero workload is a proxy: one point per heavy line plus quantity bands.
-- It is not a physical weight or a sales-value measure.
-- Score after five timed loads: 40% assignment-to-proof on-time rate,
-- 30% peer workload, 20% peer active pace, 10% completed/(completed + overdue).
-- Peer workload and pace use eligible staff in the same location and period;
-- tied cohorts receive a neutral 50. Pending work becomes overdue after 24h.
create or replace function public.bodegero_performance_v1(
  p_session_token text, p_period_start timestamptz, p_period_end timestamptz
) returns jsonb language plpgsql stable security definer
set search_path = public, private, pg_temp as $$
declare v_actor record; v_result jsonb;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'admin' then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  if p_period_start is null or p_period_end <= p_period_start then
    raise exception 'performance_period_invalid';
  end if;
  with heavy_orders as (
    select h.order_id, h.assigned_bodegero_id as employee_id,
      h.loading_verified_at,
      h.loading_started_at,
      h.loading_paused_seconds,
      h.bodegero_assigned_at,
      h.status,
      coalesce((select sum(1 + case
        when coalesce((item ->> 'quantity')::numeric, 0) <= 1 then 0
        when (item ->> 'quantity')::numeric <= 5 then .25
        when (item ->> 'quantity')::numeric <= 10 then .5
        when (item ->> 'quantity')::numeric <= 20 then .75
        else 1 end)
        from jsonb_array_elements(h.items) item
        where item ->> 'requires_loading' = 'true'), 0)::numeric as points
    from public.order_history h
    where h.location_id = v_actor.location_id
      and h.bodegero_assigned_at >= p_period_start
      and h.bodegero_assigned_at < p_period_end
      and h.assigned_bodegero_id is not null
      and exists (select 1 from jsonb_array_elements(h.items) item
        where item ->> 'requires_loading' = 'true')
  ), measured as (
    select *, case when loading_started_at is not null
        and bodegero_assigned_at <= loading_started_at
        and loading_verified_at >= loading_started_at
        and extract(epoch from (loading_verified_at - loading_started_at))
            > coalesce(loading_paused_seconds, 0)
      then (extract(epoch from (loading_verified_at - loading_started_at))
        - coalesce(loading_paused_seconds, 0)) / 60 end as active_minutes,
      case when loading_started_at is not null
          and bodegero_assigned_at <= loading_started_at
          and loading_verified_at >= loading_started_at
          and extract(epoch from (loading_verified_at - bodegero_assigned_at))
              > coalesce(loading_paused_seconds, 0)
        then (extract(epoch from (loading_verified_at - bodegero_assigned_at))
          - coalesce(loading_paused_seconds, 0)) / 60 end as service_minutes,
      case when loading_started_at >= bodegero_assigned_at then
          extract(epoch from (loading_started_at - bodegero_assigned_at)) / 60
        end as start_delay_minutes
    from heavy_orders
  ), grouped as (
    select employee_id,
      count(*)::integer as assigned_count,
      count(*) filter (where loading_verified_at is not null)::integer as completed_count,
      count(*) filter (where loading_verified_at is null and status not in ('cancelled', 'returned')
        and bodegero_assigned_at < now() - interval '24 hours')::integer as overdue_count,
      count(active_minutes)::integer as valid_timing_count,
      count(*) filter (where loading_verified_at is not null and active_minutes is null)::integer as excluded_timing_count,
      coalesce(sum(points) filter (where loading_verified_at is not null), 0) as workload_points,
      coalesce(sum(points) filter (where active_minutes is not null), 0) as timed_points,
      coalesce(sum(active_minutes), 0) as total_active_minutes,
      coalesce(sum(loading_paused_seconds) filter (where loading_verified_at is not null), 0) / 60
        as total_paused_minutes,
      avg(start_delay_minutes) filter (where active_minutes is not null)
        as average_start_delay_minutes,
      percentile_cont(.5) within group (order by active_minutes) as median_minutes,
      count(*) filter (where active_minutes is not null
        and service_minutes <= 20 + 5 * points)::integer as on_time_count
    from measured group by employee_id
  ), scored as (
    select g.*,
      case when valid_timing_count > 0 then
        round(on_time_count * 100.0 / valid_timing_count, 1) end as on_time_rate,
      case when valid_timing_count > 0 and total_active_minutes > 0 then
        round(timed_points * 60.0 / total_active_minutes, 2) end as points_per_hour,
      case when completed_count + overdue_count > 0 then
        round(completed_count * 100.0 / (completed_count + overdue_count), 1) end as completion_rate
    from grouped g
  ), ranked as (
    select s.*,
      case when valid_timing_count >= 5 then
        case when max(workload_points) filter (where valid_timing_count >= 5) over ()
               = min(workload_points) filter (where valid_timing_count >= 5) over () then 50
        else (workload_points - min(workload_points) filter (where valid_timing_count >= 5) over ())
          * 100 / nullif(max(workload_points) filter (where valid_timing_count >= 5) over ()
          - min(workload_points) filter (where valid_timing_count >= 5) over (), 0) end end as throughput_peer,
      case when valid_timing_count >= 5 then
        case when max(points_per_hour) filter (where valid_timing_count >= 5) over ()
               = min(points_per_hour) filter (where valid_timing_count >= 5) over () then 50
        else (points_per_hour - min(points_per_hour) filter (where valid_timing_count >= 5) over ())
          * 100 / nullif(max(points_per_hour) filter (where valid_timing_count >= 5) over ()
          - min(points_per_hour) filter (where valid_timing_count >= 5) over (), 0) end end as pace_peer
    from scored s
  )
  select jsonb_build_object(
    'total_completed', coalesce(sum(completed_count), 0),
    'total_workload_points', coalesce(sum(workload_points), 0),
    'total_valid_timing', coalesce(sum(valid_timing_count), 0),
    'records', coalesce(jsonb_agg(jsonb_build_object(
      'employee_id', profile.id::text,
      'employee_name', profile.name,
      'is_active', profile.is_active,
      'assigned_count', coalesce(r.assigned_count, 0),
      'completed_count', coalesce(r.completed_count, 0),
      'overdue_count', coalesce(r.overdue_count, 0),
      'valid_timing_count', coalesce(r.valid_timing_count, 0),
      'excluded_timing_count', coalesce(r.excluded_timing_count, 0),
      'workload_points', coalesce(r.workload_points, 0),
      'median_minutes', r.median_minutes,
      'total_paused_minutes', r.total_paused_minutes,
      'average_start_delay_minutes', r.average_start_delay_minutes,
      'on_time_rate', r.on_time_rate,
      'points_per_hour', r.points_per_hour,
      'completion_rate', r.completion_rate,
      'score', case when r.valid_timing_count >= 5 then round(
        r.on_time_rate * .40 + r.throughput_peer * .30
        + r.pace_peer * .20 + r.completion_rate * .10, 1) end
      ) order by profile.name), '[]'::jsonb)
  ) into v_result
  from public.profiles profile left join ranked r on r.employee_id = profile.id::text
  where profile.location_id = v_actor.location_id and profile.role = 'bodegero';
  return coalesce(v_result, '{"records":[]}'::jsonb);
end;
$$;
revoke all on function public.bodegero_performance_v1(text, timestamptz, timestamptz)
  from public, authenticated;
grant execute on function public.bodegero_performance_v1(text, timestamptz, timestamptz)
  to anon, service_role;
commit;
