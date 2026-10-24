CREATE OR REPLACE FUNCTION public.update_cashier_discount_limit_v1 (
  p_session_token text,
  p_limit_pct     numeric
)
  RETURNS numeric
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_limit numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update the discount limit';
  end if;
  if p_limit_pct is null or p_limit_pct < 0 or p_limit_pct > 100 then
    raise exception 'Discount limit must be between 0 and 100';
  end if;

  insert into public.store_settings (
    location_id, cashier_auto_approved_discount_limit_pct
  ) values (v_profile.location_id, p_limit_pct)
  on conflict (location_id) do update set
    cashier_auto_approved_discount_limit_pct = excluded.cashier_auto_approved_discount_limit_pct
  returning cashier_auto_approved_discount_limit_pct into v_limit;
  return v_limit;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."update_cashier_discount_limit_v1"(text, numeric) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."update_cashier_discount_limit_v1"(text, numeric) TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_cashier_discount_limit_v1"(text, numeric) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."update_cashier_discount_limit_v1"(text, numeric) TO "postgres";

REVOKE ALL ON FUNCTION "public"."update_cashier_discount_limit_v1"(text, numeric) FROM PUBLIC, "authenticated";
