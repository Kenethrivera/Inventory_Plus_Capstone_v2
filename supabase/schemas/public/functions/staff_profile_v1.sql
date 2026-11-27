CREATE OR REPLACE FUNCTION public.staff_profile_v1 (
  p_session_token text,
  p_target_profile_id bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
  v_profile jsonb;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'admin' then
    raise exception 'Admin session required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', profile.id,
    'name', profile.name,
    'username', profile.username,
    'role', profile.role,
    'created_at', profile.created_at,
    'location_id', profile.location_id,
    'email', profile.email,
    'phone', profile.phone,
    'address', profile.address,
    'must_change_password', profile.must_change_password,
    'is_active', profile.is_active,
    'cashier_discount_limit_pct', profile.cashier_discount_limit_pct
  ) into v_profile
  from public.profiles profile
  where profile.id = p_target_profile_id
    and profile.location_id = v_actor.location_id;

  return v_profile;
end;
$function$;

REVOKE ALL ON FUNCTION public.staff_profile_v1(text, bigint)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_profile_v1(text, bigint)
  TO anon, service_role, postgres;
