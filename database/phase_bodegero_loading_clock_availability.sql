-- Apply after phase_bodegero_performance.sql and phase_bodegero_availability.sql.
-- Enforce availability when an assigned Bodegero starts loading.
begin;

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

commit;
