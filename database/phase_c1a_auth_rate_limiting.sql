-- Phase C1A: durable abuse protection for custom login and authenticated
-- current-password verification.
--
-- Manual deployment only. Do not run this file from the Flutter client.
-- Requires the Phase 5B custom app-session functions and extensions.pgcrypto.
-- Deploy the complete file as one transaction before deploying the C1A client.

begin;

create table if not exists private.auth_rate_limits (
  action_type text not null,
  subject_key_hash bytea not null,
  window_started_at timestamptz not null,
  attempt_count integer not null default 0,
  blocked_until timestamptz,
  last_attempt_at timestamptz not null,
  constraint auth_rate_limits_pkey
    primary key (action_type, subject_key_hash),
  constraint auth_rate_limits_action_type_check
    check (action_type in ('login', 'current_password')),
  constraint auth_rate_limits_subject_hash_check
    check (octet_length(subject_key_hash) = 32),
  constraint auth_rate_limits_attempt_count_check
    check (attempt_count >= 0)
);

alter table private.auth_rate_limits enable row level security;
revoke all on table private.auth_rate_limits from public, anon, authenticated;

create index if not exists auth_rate_limits_last_attempt_idx
  on private.auth_rate_limits (last_attempt_at);

create or replace function private.auth_rate_limit_is_blocked_v1(
  p_action_type text,
  p_subject_key_hash bytea
) returns boolean
language plpgsql volatile security definer
set search_path = private, pg_temp
as $$
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
    return false;
  end if;
  if v_blocked_until > v_now then
    return true;
  end if;

  update private.auth_rate_limits limiter
  set window_started_at = v_now,
      attempt_count = 0,
      blocked_until = null
  where limiter.action_type = p_action_type
    and limiter.subject_key_hash = p_subject_key_hash;
  return false;
end;
$$;

create or replace function private.record_auth_rate_limit_failure_v1(
  p_action_type text,
  p_subject_key_hash bytea,
  p_max_attempts integer,
  p_window interval,
  p_block_duration interval
) returns boolean
language plpgsql volatile security definer
set search_path = private, pg_temp
as $$
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
$$;

create or replace function private.reset_auth_rate_limit_v1(
  p_action_type text,
  p_subject_key_hash bytea
) returns void
language plpgsql volatile security definer
set search_path = private, pg_temp
as $$
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
$$;

revoke all on function private.auth_rate_limit_is_blocked_v1(text, bytea)
  from public, anon, authenticated;
revoke all on function private.record_auth_rate_limit_failure_v1(
  text, bytea, integer, interval, interval
) from public, anon, authenticated;
revoke all on function private.reset_auth_rate_limit_v1(text, bytea)
  from public, anon, authenticated;

create or replace function public.profile_login_v1(
  p_username text,
  p_password text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_normalized_username text := trim(coalesce(p_username, ''));
  v_subject_key_hash bytea;
  v_rate_limited boolean;
  v_session_token text;
  v_expires_at timestamptz;
begin
  v_subject_key_hash := extensions.digest(
    convert_to('login:' || v_normalized_username, 'UTF8'),
    'sha256'
  );

  if private.auth_rate_limit_is_blocked_v1(
    'login', v_subject_key_hash
  ) then
    return jsonb_build_object('status', 'rate_limited');
  end if;

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
  where profile.username = v_normalized_username
    and profile.password = encode(extensions.digest(
      convert_to(coalesce(p_password, ''), 'UTF8'), 'sha256'), 'hex')
    and profile.location_id is not null
  limit 1;

  if not found then
    v_rate_limited := private.record_auth_rate_limit_failure_v1(
      'login',
      v_subject_key_hash,
      5,
      interval '10 minutes',
      interval '15 minutes'
    );
    if v_rate_limited then
      return jsonb_build_object('status', 'rate_limited');
    end if;
    return null;
  end if;

  perform private.reset_auth_rate_limit_v1('login', v_subject_key_hash);

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
$$;

create or replace function public.profile_verify_password_v1(
  p_session_token text,
  p_password text
) returns boolean
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile_id bigint;
  v_subject_key_hash bytea;
  v_password_matches boolean;
  v_rate_limited boolean;
begin
  select session_profile.profile_id into v_profile_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then return false; end if;

  v_subject_key_hash := extensions.digest(
    convert_to('profile:' || v_profile_id::text, 'UTF8'),
    'sha256'
  );

  if private.auth_rate_limit_is_blocked_v1(
    'current_password', v_subject_key_hash
  ) then
    return null;
  end if;

  select exists (
    select 1 from public.profiles profile
    where profile.id = v_profile_id
      and profile.password = encode(extensions.digest(
        convert_to(coalesce(p_password, ''), 'UTF8'), 'sha256'), 'hex')
  ) into v_password_matches;

  if v_password_matches then
    perform private.reset_auth_rate_limit_v1(
      'current_password', v_subject_key_hash
    );
    return true;
  end if;

  v_rate_limited := private.record_auth_rate_limit_failure_v1(
    'current_password',
    v_subject_key_hash,
    8,
    interval '10 minutes',
    interval '15 minutes'
  );
  if v_rate_limited then return null; end if;
  return false;
end;
$$;

-- CREATE OR REPLACE preserves the existing public function signatures and
-- their current EXECUTE ACLs. No new public grants are introduced here.

commit;
