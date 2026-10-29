CREATE OR REPLACE FUNCTION public.profile_admin_reset_password_v1 (
  p_session_token     text,
  p_target_profile_id bigint,
  p_new_password      text
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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

  -- The password update and limiter reset share this transaction. Derive the
  -- key from the trusted target profile, never from client-supplied limiter
  -- metadata. Username matching remains case-sensitive and trim-normalized.
  v_login_subject_key_hash := extensions.digest(
    convert_to('login:' || trim(v_target_username), 'UTF8'),
    'sha256'
  );
  perform private.reset_auth_rate_limit_v1(
    'login',
    v_login_subject_key_hash
  );

  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_admin_reset_password_v1"(text, bigint, text) FROM PUBLIC, "authenticated";
