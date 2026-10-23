CREATE OR REPLACE FUNCTION private.require_app_session_v1 (
  p_session_token text
)
  RETURNS TABLE (
    profile_id   bigint,
    role         text,
    location_id  uuid,
    profile_name text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'private', 'public', 'extensions', 'pg_temp'
  AS $function$
  select profile.id, lower(profile.role), profile.location_id, profile.name
  from private.app_sessions session
  join public.profiles profile on profile.id = session.profile_id
  where session.token_hash = extensions.digest(
      convert_to(coalesce(p_session_token, ''), 'UTF8'), 'sha256')
    and session.revoked_at is null
    and session.expires_at > now()
    and profile.location_id is not null
  limit 1
$function$;

REVOKE ALL ON FUNCTION "private"."require_app_session_v1"(text) FROM PUBLIC;
