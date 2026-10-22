-- Phase 5B server-verifiable sessions for the existing custom profile login.
-- Apply through the normal migration process only.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.app_sessions (
  token_hash bytea primary key,
  profile_id bigint not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);

alter table private.app_sessions enable row level security;
revoke all on table private.app_sessions from public, anon, authenticated;

create index if not exists app_sessions_profile_active_idx
  on private.app_sessions (profile_id, expires_at desc)
  where revoked_at is null;

create or replace function private.issue_app_session_v1(p_profile_id bigint)
returns table(session_token text, expires_at timestamptz)
language plpgsql volatile security definer
set search_path = private, public, extensions, pg_temp
as $$
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
$$;

create or replace function private.require_app_session_v1(
  p_session_token text
) returns table(profile_id bigint, role text, location_id uuid, profile_name text)
language sql stable security definer
set search_path = private, public, extensions, pg_temp
as $$
  select profile.id, lower(profile.role), profile.location_id, profile.name
  from private.app_sessions session
  join public.profiles profile on profile.id = session.profile_id
  where session.token_hash = extensions.digest(
      convert_to(coalesce(p_session_token, ''), 'UTF8'), 'sha256')
    and session.revoked_at is null
    and session.expires_at > now()
    and profile.location_id is not null
  limit 1
$$;

revoke all on function private.issue_app_session_v1(bigint)
  from public, anon, authenticated;
revoke all on function private.require_app_session_v1(text)
  from public, anon, authenticated;

create or replace function private.revoke_sessions_on_password_change_v1()
returns trigger
language plpgsql security definer
set search_path = private, public, pg_temp
as $$
begin
  update private.app_sessions
  set revoked_at = coalesce(revoked_at, now())
  where profile_id = new.id and revoked_at is null;
  return new;
end;
$$;

revoke all on function private.revoke_sessions_on_password_change_v1()
  from public, anon, authenticated;

drop trigger if exists profiles_revoke_sessions_on_password_change_v1
  on public.profiles;
create trigger profiles_revoke_sessions_on_password_change_v1
after update of password on public.profiles
for each row
execute function private.revoke_sessions_on_password_change_v1();

create or replace function public.profile_login_v1(
  p_username text,
  p_password text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
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
$$;

create or replace function public.profile_restore_session_v1(
  p_session_token text
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
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
$$;

create or replace function public.profile_logout_v1(
  p_session_token text
) returns void
language plpgsql volatile security definer
set search_path = private, extensions, pg_temp
as $$
begin
  update private.app_sessions
  set revoked_at = coalesce(revoked_at, now())
  where token_hash = extensions.digest(
      convert_to(coalesce(p_session_token, ''), 'UTF8'), 'sha256')
    and revoked_at is null;
end;
$$;

create or replace function public.profile_verify_password_v1(
  p_session_token text,
  p_password text
) returns boolean
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile_id bigint;
begin
  select session_profile.profile_id into v_profile_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then return false; end if;

  return exists (
    select 1 from public.profiles profile
    where profile.id = v_profile_id
      and profile.password = encode(extensions.digest(
        convert_to(coalesce(p_password, ''), 'UTF8'), 'sha256'), 'hex')
  );
end;
$$;

create or replace function public.profile_change_password_v1(
  p_session_token text,
  p_current_password text,
  p_new_password text
) returns jsonb
language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile_id bigint;
  v_role text;
  v_current_hash text;
  v_new_hash text;
  v_session_token text;
  v_expires_at timestamptz;
begin
  select session_profile.profile_id, session_profile.role
    into v_profile_id, v_role
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then
    return jsonb_build_object('status', 'not_authenticated');
  end if;

  v_current_hash := encode(extensions.digest(
    convert_to(coalesce(p_current_password, ''), 'UTF8'), 'sha256'), 'hex');
  v_new_hash := encode(extensions.digest(
    convert_to(coalesce(p_new_password, ''), 'UTF8'), 'sha256'), 'hex');

  if not exists (
    select 1 from public.profiles profile
    where profile.id = v_profile_id and profile.password = v_current_hash
  ) then return jsonb_build_object('status', 'incorrect_current'); end if;

  if v_new_hash = v_current_hash then
    return jsonb_build_object('status', 'same_password');
  end if;

  if length(coalesce(p_new_password, '')) < 8
    or p_new_password !~ '[A-Z]'
    or p_new_password !~ '[a-z]'
    or p_new_password !~ '[0-9]'
    or p_new_password !~ '[!@#$%^&*(),.?":{}|<>]'
  then return jsonb_build_object('status', 'invalid_new'); end if;

  update public.profiles
  set password = v_new_hash,
      must_change_password = case
        when v_role in ('helper', 'staff', 'cashier') then false
        else must_change_password
      end
  where id = v_profile_id and password = v_current_hash;

  if not found then
    return jsonb_build_object('status', 'concurrent_change');
  end if;

  -- The password trigger revoked every older session. Issue one replacement
  -- only after the password update has completed.
  select issued.session_token, issued.expires_at
    into v_session_token, v_expires_at
  from private.issue_app_session_v1(v_profile_id) issued;

  return jsonb_build_object(
    'status', 'success',
    'session_token', v_session_token,
    'expires_at', v_expires_at
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
begin
  select session_profile.role, session_profile.location_id
    into v_admin_role, v_admin_location
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found or v_admin_role <> 'admin' then return false; end if;

  select lower(profile.role) into v_target_role
  from public.profiles profile
  where profile.id = p_target_profile_id
    and profile.location_id = v_admin_location
  for update;
  if not found then return false; end if;

  update public.profiles
  set password = encode(extensions.digest(
        convert_to(coalesce(p_new_password, ''), 'UTF8'), 'sha256'), 'hex'),
      must_change_password = case
        when v_target_role in ('helper', 'staff', 'cashier') then true
        else must_change_password
      end
  where id = p_target_profile_id;

  return found;
end;
$$;

-- Function creation grants PUBLIC execution by default. Expose only the
-- application entry points required by the current anon client.
revoke all on function public.profile_login_v1(text, text) from public;
revoke all on function public.profile_restore_session_v1(text) from public;
revoke all on function public.profile_logout_v1(text) from public;
revoke all on function public.profile_verify_password_v1(text, text) from public;
revoke all on function public.profile_change_password_v1(text, text, text)
  from public;
revoke all on function public.profile_admin_reset_password_v1(text, bigint, text)
  from public;

revoke all on function public.profile_login_v1(text, text) from authenticated;
revoke all on function public.profile_restore_session_v1(text)
  from authenticated;
revoke all on function public.profile_logout_v1(text) from authenticated;
revoke all on function public.profile_verify_password_v1(text, text)
  from authenticated;
revoke all on function public.profile_change_password_v1(text, text, text)
  from authenticated;
revoke all on function public.profile_admin_reset_password_v1(text, bigint, text)
  from authenticated;

grant execute on function public.profile_login_v1(text, text) to anon;
grant execute on function public.profile_restore_session_v1(text) to anon;
grant execute on function public.profile_logout_v1(text) to anon;
grant execute on function public.profile_verify_password_v1(text, text) to anon;
grant execute on function public.profile_change_password_v1(text, text, text)
  to anon;
grant execute on function public.profile_admin_reset_password_v1(text, bigint, text)
  to anon;
