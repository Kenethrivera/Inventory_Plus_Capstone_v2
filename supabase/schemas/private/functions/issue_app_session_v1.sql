CREATE OR REPLACE FUNCTION private.issue_app_session_v1 (
  p_profile_id bigint
)
  RETURNS TABLE (
    session_token text,
    expires_at    timestamp with time zone
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'public', 'extensions', 'pg_temp'
  AS $function$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at timestamptz := now() + interval '24 hours';
begin
  insert into private.app_sessions (token_hash, profile_id, expires_at)
  values (
    extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'),
    p_profile_id,
    v_expires_at
  );
  return query select v_token, v_expires_at;
end;
$function$;

REVOKE ALL ON FUNCTION "private"."issue_app_session_v1"(bigint) FROM PUBLIC;
