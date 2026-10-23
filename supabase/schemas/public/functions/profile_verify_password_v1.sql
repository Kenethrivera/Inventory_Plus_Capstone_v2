CREATE OR REPLACE FUNCTION public.profile_verify_password_v1 (
  p_session_token text,
  p_password      text
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_verify_password_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_verify_password_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_verify_password_v1"(text, text) FROM PUBLIC, "authenticated";
