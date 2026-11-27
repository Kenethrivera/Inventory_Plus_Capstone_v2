CREATE OR REPLACE FUNCTION public.update_store_access_settings_v1 (
  p_session_token text,
  p_settings jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
  v_weekly jsonb;
  v_day jsonb;
  v_day_number integer;
  v_weekly_count integer;
  v_open_days integer := 0;
  v_before integer;
  v_after integer;
  v_saved public.store_access_settings%rowtype;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'admin' then
    raise exception 'Admin session required' using errcode = '42501';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object'
      or p_settings ->> 'location_id' is distinct from v_actor.location_id::text then
    raise exception 'Invalid store access location' using errcode = '22023';
  end if;

  v_before := (p_settings ->> 'staff_access_before_minutes')::integer;
  v_after := (p_settings ->> 'staff_access_after_minutes')::integer;
  if v_before is null or v_before not between 0 and 240
      or v_after is null or v_after not between 0 and 240 then
    raise exception 'Access allowance must be between 0 and 240 minutes'
      using errcode = '22023';
  end if;

  v_weekly := p_settings -> 'weekly_hours';
  if v_weekly is null or jsonb_typeof(v_weekly) <> 'object' then
    raise exception 'Store hours must include all seven days'
      using errcode = '22023';
  end if;
  select count(*) into v_weekly_count from jsonb_object_keys(v_weekly);
  if v_weekly_count <> 7 then
    raise exception 'Store hours must include all seven days'
      using errcode = '22023';
  end if;
  for v_day_number in 1..7 loop
    v_day := v_weekly -> v_day_number::text;
    if v_day is null or jsonb_typeof(v_day) <> 'object'
        or jsonb_typeof(v_day -> 'closed') <> 'boolean'
        or nullif(v_day ->> 'open', '') is null
        or nullif(v_day ->> 'close', '') is null then
      raise exception 'Invalid hours for day %', v_day_number
        using errcode = '22023';
    end if;
    perform (v_day ->> 'open')::time;
    perform (v_day ->> 'close')::time;
    if (v_day ->> 'closed')::boolean then
      if nullif(trim(coalesce(v_day ->> 'closed_reason', '')), '') is null then
        raise exception 'Closed days require a reason'
          using errcode = '22023';
      end if;
    else
      v_open_days := v_open_days + 1;
    end if;
  end loop;
  if v_open_days = 0 then
    raise exception 'At least one day must be open' using errcode = '22023';
  end if;

  insert into public.store_access_settings (
    location_id, opening_time, closing_time,
    staff_access_before_minutes, staff_access_after_minutes,
    restrict_staff_login, allow_admin_anytime, weekly_hours, updated_at
  ) values (
    v_actor.location_id::text,
    (p_settings ->> 'opening_time')::time,
    (p_settings ->> 'closing_time')::time,
    v_before, v_after,
    (p_settings ->> 'restrict_staff_login')::boolean,
    true, v_weekly, now()
  )
  on conflict (location_id) do update set
    opening_time = excluded.opening_time,
    closing_time = excluded.closing_time,
    staff_access_before_minutes = excluded.staff_access_before_minutes,
    staff_access_after_minutes = excluded.staff_access_after_minutes,
    restrict_staff_login = excluded.restrict_staff_login,
    allow_admin_anytime = true,
    weekly_hours = excluded.weekly_hours,
    updated_at = excluded.updated_at
  returning * into v_saved;

  return to_jsonb(v_saved);
end;
$function$;

REVOKE ALL ON FUNCTION public.update_store_access_settings_v1(text, jsonb)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.update_store_access_settings_v1(text, jsonb)
  TO anon, service_role, postgres;
