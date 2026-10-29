-- Phase C1A additive adjustment: five-minute login block, safe retry-after
-- metadata, and login-limiter reset after a successful Admin password reset.
--
-- Manual deployment only. C1A must already be deployed. Run this complete
-- file as one transaction before deploying the matching Flutter client.

begin;

create or replace function private.auth_rate_limit_retry_after_seconds_v1(
  p_action_type text,
  p_subject_key_hash bytea
) returns integer
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
$$;

revoke all on function private.auth_rate_limit_retry_after_seconds_v1(
  text, bytea
) from public, anon, authenticated;

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
  v_retry_after_seconds integer;
  v_session_token text;
  v_expires_at timestamptz;
begin
  v_subject_key_hash := extensions.digest(
    convert_to('login:' || v_normalized_username, 'UTF8'),
    'sha256'
  );

  v_retry_after_seconds := private.auth_rate_limit_retry_after_seconds_v1(
    'login', v_subject_key_hash
  );
  if v_retry_after_seconds > 0 then
    return jsonb_build_object(
      'status', 'rate_limited',
      'rate_limited', true,
      'retry_after_seconds', v_retry_after_seconds
    );
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
      interval '5 minutes'
    );
    if v_rate_limited then
      v_retry_after_seconds := private.auth_rate_limit_retry_after_seconds_v1(
        'login', v_subject_key_hash
      );
      return jsonb_build_object(
        'status', 'rate_limited',
        'rate_limited', true,
        'retry_after_seconds', greatest(v_retry_after_seconds, 1)
      );
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

create or replace function public.profile_admin_reset_password_v1(
  p_session_token text,
  p_target_profile_id bigint,
  p_new_password text
) returns boolean
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_admin_role text;
  v_admin_location uuid;
  v_target_role text;
  v_target_username text;
  v_login_subject_key_hash bytea;
begin
  select session_profile.role, session_profile.location_id
    into v_admin_role, v_admin_location
  from private.require_app_session_v1(p_session_token) session_profile;

  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  select lower(profile.role), profile.username
    into v_target_role, v_target_username
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

  if not found then
    return false;
  end if;

  v_login_subject_key_hash := extensions.digest(
    convert_to('login:' || trim(v_target_username), 'UTF8'),
    'sha256'
  );
  perform private.reset_auth_rate_limit_v1(
    'login', v_login_subject_key_hash
  );

  return true;
end;
$$;

-- CREATE OR REPLACE preserves the already-deployed public RPC signatures and
-- ACLs. The new private helper is explicitly inaccessible to client roles.

commit;
