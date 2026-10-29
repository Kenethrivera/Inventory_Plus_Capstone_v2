CREATE OR REPLACE FUNCTION public.profile_verify_password_v1 (
  p_session_token text,
  p_password      text
)
  RETURNS boolean
  LANGUAGE plpgsql
  VOLATILE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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

  -- NULL is the backwards-compatible limited state. Existing clients compare
  -- only with TRUE and therefore continue to treat it as an incorrect value.
  if private.auth_rate_limit_is_blocked_v1(
    'current_password',
    v_subject_key_hash
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
      'current_password',
      v_subject_key_hash
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_verify_password_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_verify_password_v1"(text, text) FROM PUBLIC, "authenticated";
