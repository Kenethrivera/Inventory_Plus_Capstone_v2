CREATE OR REPLACE FUNCTION public.profile_restore_session_v1 (
  p_session_token text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
begin
  select
    profile.id,
    profile.location_id,
    profile.name,
    profile.role,
    profile.email,
    profile.address,
    profile.phone,
    profile.must_change_password,
    session.expires_at
  into v_profile
  from private.app_sessions session
  join public.profiles profile on profile.id = session.profile_id
  where session.token_hash = extensions.digest(
      convert_to(coalesce(p_session_token, ''), 'UTF8'), 'sha256')
    and session.revoked_at is null
    and session.expires_at > now()
    and profile.location_id is not null
  limit 1;

  if not found then return null; end if;

  return jsonb_build_object(
    'expires_at', v_profile.expires_at,
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

GRANT EXECUTE ON FUNCTION "public"."profile_restore_session_v1"(text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_restore_session_v1"(text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_restore_session_v1"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_restore_session_v1"(text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_restore_session_v1"(text) FROM PUBLIC, "authenticated";
