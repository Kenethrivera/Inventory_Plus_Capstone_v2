CREATE OR REPLACE FUNCTION private.revoke_sessions_on_password_change_v1()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'public', 'pg_temp'
  AS $function$
begin
  update private.app_sessions
  set revoked_at = coalesce(revoked_at, now())
  where profile_id = new.id and revoked_at is null;
  return new;
end;
$function$;

REVOKE ALL ON FUNCTION "private"."revoke_sessions_on_password_change_v1"() FROM PUBLIC;
