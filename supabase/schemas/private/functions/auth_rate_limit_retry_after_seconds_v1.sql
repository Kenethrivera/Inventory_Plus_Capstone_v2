CREATE OR REPLACE FUNCTION private.auth_rate_limit_retry_after_seconds_v1 (
  p_action_type      text,
  p_subject_key_hash bytea
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'pg_temp'
  AS $function$
declare
  v_now timestamptz := clock_timestamp();
  v_blocked_until timestamptz;
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

  select limiter.blocked_until
    into v_blocked_until
  from private.auth_rate_limits limiter
  where limiter.action_type = p_action_type
    and limiter.subject_key_hash = p_subject_key_hash
  for update;

  if not found or v_blocked_until is null then
    return 0;
  end if;

  if v_blocked_until <= v_now then
    update private.auth_rate_limits limiter
    set window_started_at = v_now,
        attempt_count = 0,
        blocked_until = null
    where limiter.action_type = p_action_type
      and limiter.subject_key_hash = p_subject_key_hash;
    return 0;
  end if;

  return greatest(
    1,
    ceil(extract(epoch from (v_blocked_until - v_now)))::integer
  );
end;
$function$;

REVOKE ALL ON FUNCTION private.auth_rate_limit_retry_after_seconds_v1(
  text, bytea
) FROM PUBLIC, "anon", "authenticated";
