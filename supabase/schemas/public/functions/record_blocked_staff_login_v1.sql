CREATE OR REPLACE FUNCTION public.record_blocked_staff_login_v1 (
  p_session_token text,
  p_reason text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role not in ('staff', 'cashier', 'helper', 'bodegero') then
    raise exception 'Staff session required' using errcode = '42501';
  end if;

  insert into public.staff_session_logs (
    user_id, user_name, user_role, location_id,
    login_at, blocked_by_store_hours, block_reason
  ) values (
    v_actor.profile_id::text, v_actor.profile_name, v_actor.role,
    v_actor.location_id::text, now(), true,
    left(coalesce(p_reason, 'Outside store hours'), 500)
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.record_blocked_staff_login_v1(text, text)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.record_blocked_staff_login_v1(text, text)
  TO anon, service_role, postgres;
