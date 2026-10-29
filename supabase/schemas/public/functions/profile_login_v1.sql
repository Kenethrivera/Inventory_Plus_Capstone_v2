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
