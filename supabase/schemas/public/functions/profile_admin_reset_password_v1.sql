CREATE OR REPLACE FUNCTION public.profile_admin_reset_password_v1 (
  p_session_token     text,
  p_target_profile_id bigint,
  p_new_password      text
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_admin_role text;
  v_admin_location uuid;
  v_target_role text;
begin
  select session_profile.role, session_profile.location_id
    into v_admin_role, v_admin_location
  from private.require_app_session_v1(p_session_token) session_profile;

  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  select lower(profile.role)
    into v_target_role
  from public.profiles profile
  where profile.id = p_target_profile_id
    and profile.location_id = v_admin_location
  for update;

  if not found then
    return false;
  end if;

  update public.profiles
  set password = encode(
        extensions.digest(
          convert_to(coalesce(p_new_password, ''), 'UTF8'),
          'sha256'
        ),
        'hex'
      ),
      must_change_password = case
        when v_target_role in ('helper', 'staff', 'cashier') then true
        else must_change_password
      end
  where id = p_target_profile_id;

  return found;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM PUBLIC, "authenticated";
