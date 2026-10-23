CREATE OR REPLACE FUNCTION public.profile_logout_v1 (
  p_session_token text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'private', 'extensions', 'pg_temp'
  AS $function$
begin
  update private.app_sessions
  set revoked_at = coalesce(revoked_at, now())
  where token_hash = extensions.digest(
      convert_to(coalesce(p_session_token, ''), 'UTF8'), 'sha256')
    and revoked_at is null;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."profile_logout_v1"(text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."profile_logout_v1"(text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."profile_logout_v1"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."profile_logout_v1"(text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."profile_logout_v1"(text) FROM PUBLIC, "authenticated";
