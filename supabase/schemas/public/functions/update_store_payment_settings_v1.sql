CREATE OR REPLACE FUNCTION public.update_store_payment_settings_v1 (
  p_session_token text,
  p_gcash_qr_url  text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_qr_url text;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update payment settings';
  end if;

  v_qr_url := trim(coalesce(p_gcash_qr_url, ''));
  insert into public.store_settings (location_id, gcash_qr_url)
  values (v_profile.location_id, v_qr_url)
  on conflict (location_id) do update set
    gcash_qr_url = excluded.gcash_qr_url;
  return v_qr_url;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."update_store_payment_settings_v1"(text, text) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."update_store_payment_settings_v1"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_store_payment_settings_v1"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."update_store_payment_settings_v1"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."update_store_payment_settings_v1"(text, text) FROM PUBLIC, "authenticated";
