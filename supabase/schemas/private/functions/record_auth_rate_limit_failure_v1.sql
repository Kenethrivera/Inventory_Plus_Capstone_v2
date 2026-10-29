CREATE OR REPLACE FUNCTION private.record_auth_rate_limit_failure_v1 (
  p_action_type      text,
  p_subject_key_hash bytea,
  p_max_attempts     integer,
  p_window           interval,
  p_block_duration   interval
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'pg_temp'
  AS $function$
declare
  v_now timestamptz := clock_timestamp();
  v_limiter private.auth_rate_limits;
  v_attempt_count integer;
  v_window_started_at timestamptz;
  v_blocked_until timestamptz;
begin
  if p_action_type not in ('login', 'current_password')
      or p_subject_key_hash is null
      or octet_length(p_subject_key_hash) <> 32
      or p_max_attempts < 1
      or p_window <= interval '0 seconds'
      or p_block_duration <= interval '0 seconds' then
    raise exception 'auth_rate_limit_policy_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'auth-rate-limit:' || p_action_type || ':' ||
      encode(p_subject_key_hash, 'hex'),
    0
  ));

  select limiter.*
    into v_limiter
  from private.auth_rate_limits limiter
  where limiter.action_type = p_action_type
    and limiter.subject_key_hash = p_subject_key_hash
  for update;

  if found and v_limiter.blocked_until > v_now then
    return true;
  end if;

  if not found or v_limiter.window_started_at <= v_now - p_window then
    v_attempt_count := 1;
    v_window_started_at := v_now;
  else
    v_attempt_count := v_limiter.attempt_count + 1;
    v_window_started_at := v_limiter.window_started_at;
  end if;

  v_blocked_until := case
    when v_attempt_count >= p_max_attempts then v_now + p_block_duration
    else null
  end;

  insert into private.auth_rate_limits (
    action_type,
    subject_key_hash,
    window_started_at,
    attempt_count,
    blocked_until,
    last_attempt_at
  ) values (
    p_action_type,
    p_subject_key_hash,
    v_window_started_at,
    v_attempt_count,
    v_blocked_until,
    v_now
  )
  on conflict (action_type, subject_key_hash) do update
  set window_started_at = excluded.window_started_at,
      attempt_count = excluded.attempt_count,
      blocked_until = excluded.blocked_until,
      last_attempt_at = excluded.last_attempt_at;

  -- Small opportunistic batches avoid a polling job while ensuring abandoned
  -- unknown-username buckets do not remain forever.
  delete from private.auth_rate_limits limiter
  where limiter.ctid in (
    select stale.ctid
    from private.auth_rate_limits stale
    where stale.last_attempt_at < v_now - interval '30 days'
      and (stale.blocked_until is null or stale.blocked_until <= v_now)
    order by stale.last_attempt_at
    limit 25
  );

  return v_blocked_until is not null;
end;
$function$;

REVOKE ALL ON FUNCTION private.record_auth_rate_limit_failure_v1(
  text, bytea, integer, interval, interval
) FROM PUBLIC, "anon", "authenticated";
