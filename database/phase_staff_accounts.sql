BEGIN;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

DROP FUNCTION IF EXISTS public.update_staff_account_v1(text, bigint, text, text, text, text, boolean);

CREATE OR REPLACE FUNCTION public.update_staff_account_v1(
  p_session_token text,
  p_target_profile_id bigint,
  p_name text,
  p_email text,
  p_phone text,
  p_role text,
  p_is_active boolean,
  p_address text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id bigint;
  v_admin_role text;
  v_location_id uuid;
  v_target public.profiles%rowtype;
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  select session_profile.profile_id, session_profile.role,
         session_profile.location_id
    into v_admin_id, v_admin_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found or v_admin_role <> 'admin' then
    return false;
  end if;

  if trim(coalesce(p_name, '')) = '' or
     v_role not in ('admin', 'staff', 'helper') or
     p_is_active is null then
    return false;
  end if;

  -- Serialize account status changes within the store so two admins cannot
  -- simultaneously remove the last active administrator.
  perform pg_advisory_xact_lock(hashtextextended(v_location_id::text, 0));
  select * into v_target
  from public.profiles
  where id = p_target_profile_id and location_id = v_location_id
  for update;
  if not found then return false; end if;

  if v_target.id = v_admin_id and
     (v_role <> 'admin' or not p_is_active) then
    return false;
  end if;
  if v_target.role = 'admin' and v_target.is_active and
     (v_role <> 'admin' or not p_is_active) and
     (select count(*) from public.profiles
      where location_id = v_location_id and role = 'admin' and is_active) <= 1 then
    return false;
  end if;

  update public.profiles
  set name = trim(p_name),
      email = nullif(trim(coalesce(p_email, '')), ''),
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      address = case when p_address is null then address else nullif(trim(p_address), '') end,
      role = v_role,
      is_active = p_is_active
  where id = p_target_profile_id;

  if v_target.role is distinct from v_role or
     (v_target.is_active and not p_is_active) then
    update private.app_sessions
    set revoked_at = now()
    where profile_id = p_target_profile_id and revoked_at is null;
  end if;
  if not p_is_active then
    update public.staff_presence
    set is_online = false,
        current_module = null,
        logged_out_at = now()
    where user_id = p_target_profile_id::text;
  end if;
  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.update_staff_account_v1(
  text, bigint, text, text, text, text, boolean, text
) FROM PUBLIC, authenticated;


CREATE OR REPLACE FUNCTION public.profile_login_v1 (
  p_username text,
  p_password text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_normalized_username text := trim(coalesce(p_username, ''));
  v_subject_key_hash bytea;
  v_rate_limited boolean;
  v_retry_after_seconds integer;
  v_session_token text;
  v_expires_at timestamptz;
begin
  -- Username matching remains intentionally case-sensitive. Trimming here
  -- matches the existing login semantics while preventing whitespace variants
  -- from receiving independent limiter buckets.
  v_subject_key_hash := extensions.digest(
    convert_to('login:' || v_normalized_username, 'UTF8'),
    'sha256'
  );

  v_retry_after_seconds := private.auth_rate_limit_retry_after_seconds_v1(
    'login',
    v_subject_key_hash
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
    and profile.is_active
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
        'login',
        v_subject_key_hash
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_login_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_login_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_login_v1"(text, text) FROM PUBLIC, "authenticated";


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
    and profile.is_active
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
    and profile.is_active
  limit 1
$function$;

REVOKE ALL ON FUNCTION "private"."require_app_session_v1"(text) FROM PUBLIC;


COMMIT;

NOTIFY pgrst, 'reload schema';
