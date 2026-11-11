CREATE OR REPLACE FUNCTION public.update_staff_account_v1(
  p_session_token text,
  p_target_profile_id bigint,
  p_name text,
  p_email text,
  p_phone text,
  p_role text,
  p_is_active boolean,
  p_address text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id bigint;
  v_admin_role text;
  v_location_id uuid;
  v_target public.profiles%rowtype;
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  select session_profile.profile_id, session_profile.role,
         session_profile.location_id
    into v_admin_id, v_admin_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  if trim(coalesce(p_name, '')) = '' or
     v_role not in ('admin', 'staff', 'helper') or
     p_is_active is null then
    return false;
  end if;

  -- Serialize account status changes within the store so two admins cannot
  -- simultaneously remove the last active administrator.
  perform pg_advisory_xact_lock(hashtextextended(v_location_id::text, 0));
  select * into v_target
  from public.profiles
  where id = p_target_profile_id and location_id = v_location_id
  for update;
  if not found then return false; end if;

  if v_target.id = v_admin_id and
     (v_role <> 'admin' or not p_is_active) then
    return false;
  end if;
  if v_target.role = 'admin' and v_target.is_active and
     (v_role <> 'admin' or not p_is_active) and
     (select count(*) from public.profiles
      where location_id = v_location_id and role = 'admin' and is_active) <= 1 then
    return false;
  end if;

  update public.profiles
  set name = trim(p_name),
      email = nullif(trim(coalesce(p_email, '')), ''),
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      address = case when p_address is null then address else nullif(trim(p_address), '') end,
      role = v_role,
      is_active = p_is_active
  where id = p_target_profile_id;

  if v_target.role is distinct from v_role or
     (v_target.is_active and not p_is_active) then
    update private.app_sessions
    set revoked_at = now()
    where profile_id = p_target_profile_id and revoked_at is null;
  end if;
  if not p_is_active then
    update public.staff_presence
    set is_online = false,
        current_module = null,
        logged_out_at = now()
    where user_id = p_target_profile_id::text;
  end if;
  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) FROM PUBLIC, authenticated;
