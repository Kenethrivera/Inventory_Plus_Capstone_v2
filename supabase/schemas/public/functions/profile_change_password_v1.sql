CREATE OR REPLACE FUNCTION public.profile_change_password_v1 (
  p_session_token    text,
  p_current_password text,
  p_new_password     text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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

  v_current_hash := encode(
    extensions.digest(
      convert_to(coalesce(p_current_password, ''), 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  v_new_hash := encode(
    extensions.digest(
      convert_to(coalesce(p_new_password, ''), 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  if not exists (
    select 1
    from public.profiles profile
    where profile.id = v_profile_id
      and profile.password = v_current_hash
  ) then
    return jsonb_build_object('status', 'incorrect_current');
  end if;

  if v_new_hash = v_current_hash then
    return jsonb_build_object('status', 'same_password');
  end if;

  if length(coalesce(p_new_password, '')) < 8
    or p_new_password !~ '[A-Z]'
    or p_new_password !~ '[a-z]'
    or p_new_password !~ '[0-9]'
    or p_new_password !~ '[!@#$%^&*(),.?":{}|<>]'
  then
    return jsonb_build_object('status', 'invalid_new');
  end if;

  update public.profiles
  set password = v_new_hash,
      must_change_password = case
        when v_role in ('helper', 'staff', 'cashier') then false
        else must_change_password
      end
  where id = v_profile_id
    and password = v_current_hash;

  if not found then
    return jsonb_build_object('status', 'concurrent_change');
  end if;

  select issued.session_token, issued.expires_at
    into v_session_token, v_expires_at
  from private.issue_app_session_v1(v_profile_id) issued;

  return jsonb_build_object(
    'status', 'success',
    'session_token', v_session_token,
    'expires_at', v_expires_at
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_change_password_v1"(text, text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_change_password_v1"(text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_change_password_v1"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_change_password_v1"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_change_password_v1"(text, text, text) FROM PUBLIC, "authenticated";
