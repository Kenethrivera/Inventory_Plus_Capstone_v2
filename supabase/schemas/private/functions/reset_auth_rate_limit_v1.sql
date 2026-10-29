CREATE OR REPLACE FUNCTION private.reset_auth_rate_limit_v1 (
  p_action_type      text,
  p_subject_key_hash bytea
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'pg_temp'
  AS $function$
begin
  if p_action_type not in ('login', 'current_password')
      or p_subject_key_hash is null
      or octet_length(p_subject_key_hash) <> 32 then
    raise exception 'auth_rate_limit_key_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'auth-rate-limit:' || p_action_type || ':' ||
      encode(p_subject_key_hash, 'hex'),
    0
  ));

  delete from private.auth_rate_limits limiter
  where limiter.action_type = p_action_type
    and limiter.subject_key_hash = p_subject_key_hash;
end;
$function$;

REVOKE ALL ON FUNCTION private.reset_auth_rate_limit_v1(text, bytea)
  FROM PUBLIC, "anon", "authenticated";
