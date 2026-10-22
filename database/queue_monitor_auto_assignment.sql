-- Queue Monitor automatic Helper assignment.
-- Apply manually after the Phase 5B app-session migration. The only caller
-- input is the opaque session token; role and location are derived server-side.

drop function if exists public.auto_assign_pending_orders_v1(uuid);

create or replace function public.auto_assign_pending_orders_v1(
  p_session_token text
) returns integer
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_role text;
  v_location_id uuid;
  v_order_id public.orders.id%type;
  v_helper_id public.profiles.id%type;
  v_helper_name public.profiles.name%type;
  v_assigned_count integer := 0;
begin
  select session_profile.role,
         session_profile.location_id
    into v_role, v_location_id
    from private.require_app_session_v1(p_session_token) session_profile;

  if not found or v_role not in ('admin', 'staff', 'cashier', 'helper') then
    raise exception 'Application session is invalid or expired';
  end if;

  -- All clients reconciling the same store serialize behind one transaction
  -- lock. The conditional UPDATE remains the final ownership guard.
  perform pg_advisory_xact_lock(
    hashtextextended('auto-assign:' || v_location_id::text, 0)
  );

  for v_order_id in
    select pending.id
      from public.orders pending
     where pending.location_id = v_location_id
       and lower(pending.status) = 'pending'
       and pending.assigned_helper_id is null
     order by pending.created_at asc, pending.id asc
     for update skip locked
  loop
    select profile.id, profile.name
      into v_helper_id, v_helper_name
      from public.staff_presence presence
      join public.profiles profile
        -- Presence identity is written by the custom-auth client. Compare its
        -- textual representation to the numeric profile key so this migration
        -- remains compatible with the repository's existing presence schema.
        on profile.id::text = presence.user_id::text
       and profile.location_id = v_location_id
      left join lateral (
        select count(*) filter (
                 where lower(work.status) = 'pending'
               )::integer as active_count,
               max(work.assigned_at) as last_assigned_at
          from public.orders work
         where work.location_id = v_location_id
           and work.assigned_helper_id = profile.id
      ) workload on true
     where presence.location_id = v_location_id
       and presence.is_online = true
       and presence.last_seen_at >= clock_timestamp() - interval '2 minutes'
       and lower(presence.user_role) = 'helper'
       and lower(profile.role) = 'helper'
     order by coalesce(workload.active_count, 0) asc,
              workload.last_assigned_at asc nulls first,
              profile.id asc
     limit 1;

    if v_helper_id is null then
      exit;
    end if;

    update public.orders assigned
       set assigned_helper_id = v_helper_id,
           assigned_helper_name = v_helper_name,
           assigned_at = clock_timestamp(),
           assigned_by_admin_id = null,
           assigned_by_admin_name = null
     where assigned.id = v_order_id
       and assigned.location_id = v_location_id
       and lower(assigned.status) = 'pending'
       and assigned.assigned_helper_id is null;

    if found then
      v_assigned_count := v_assigned_count + 1;
    end if;
  end loop;

  return v_assigned_count;
end;
$$;

revoke all on function public.auto_assign_pending_orders_v1(text) from public;
revoke all on function public.auto_assign_pending_orders_v1(text)
  from authenticated;
grant execute on function public.auto_assign_pending_orders_v1(text) to anon;
