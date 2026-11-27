-- Presence uses the application's custom session token; direct table calls
-- from the client run as anon and are denied by RLS.
create or replace function public.staff_presence_write_v1(
  p_session_token text,
  p_event text,
  p_is_online boolean,
  p_current_module text
)
returns void
language plpgsql
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_session record;
  v_now timestamptz := now();
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;
  if p_event not in ('login', 'heartbeat', 'logout')
     or p_is_online is null
     or length(coalesce(p_current_module, '')) > 200
     or (p_event = 'logout' and p_is_online) then
    raise exception 'invalid_presence_input' using errcode = '22023';
  end if;

  insert into public.staff_presence (
    user_id, user_name, user_role, location_id, is_online,
    current_module, logged_in_at, last_seen_at, logged_out_at
  ) values (
    v_session.profile_id::text, v_session.profile_name, v_session.role,
    v_session.location_id::text, p_is_online,
    case when p_event = 'logout' then null else p_current_module end,
    v_now, v_now,
    case when p_event = 'logout' then v_now else null end
  ) on conflict (user_id) do update set
    user_name = excluded.user_name,
    user_role = excluded.user_role,
    location_id = excluded.location_id,
    is_online = excluded.is_online,
    current_module = excluded.current_module,
    logged_in_at = case when p_event = 'login'
      then v_now else public.staff_presence.logged_in_at end,
    last_seen_at = v_now,
    logged_out_at = case when p_event = 'logout' then v_now else null end;
end;
$function$;

create or replace function public.staff_presence_list_v1(
  p_session_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_session record;
  v_rows jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.last_seen_at desc), '[]'::jsonb)
  into v_rows
  from public.staff_presence p
  where p.location_id = v_session.location_id::text
    and p.logged_out_at is null
    and p.last_seen_at >= now() - interval '2 minutes';
  return v_rows;
end;
$function$;

revoke all on function public.staff_presence_write_v1(text,text,boolean,text)
from public, authenticated;
revoke all on function public.staff_presence_list_v1(text)
from public, authenticated;
grant execute on function public.staff_presence_write_v1(text,text,boolean,text)
to anon, service_role;
grant execute on function public.staff_presence_list_v1(text)
to anon, service_role;
