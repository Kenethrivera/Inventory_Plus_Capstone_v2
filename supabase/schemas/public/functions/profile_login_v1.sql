CREATE OR REPLACE FUNCTION public.profile_login_v1 (
  p_username text,
  p_password text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_session_token text;
  v_expires_at timestamptz;
begin
  select
    profile.id,
    profile.location_id,
    profile.name,
    profile.role,
    profile.email,
    profile.address,
    profile.phone,
    profile.must_change_password
  into v_profile
  from public.profiles profile
  where profile.username = trim(coalesce(p_username, ''))
    and profile.password = encode(extensions.digest(
      convert_to(coalesce(p_password, ''), 'UTF8'), 'sha256'), 'hex')
    and profile.location_id is not null
  limit 1;

  if not found then return null; end if;

  select issued.session_token, issued.expires_at
    into v_session_token, v_expires_at
  from private.issue_app_session_v1(v_profile.id) issued;

  return jsonb_build_object(
    'session_token', v_session_token,
    'expires_at', v_expires_at,
    'profile', jsonb_build_object(
      'id', v_profile.id,
      'location_id', v_profile.location_id,
      'name', v_profile.name,
      'role', v_profile.role,
      'email', v_profile.email,
      'address', v_profile.address,
      'phone', v_profile.phone,
      'must_change_password', v_profile.must_change_password
    )
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_login_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_login_v1"(text, text) FROM PUBLIC, "authenticated";
