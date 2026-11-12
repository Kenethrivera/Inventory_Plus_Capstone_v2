CREATE OR REPLACE FUNCTION public.update_settings_dashboard_v1 (
  p_session_token text,
  p_auto_assign_orders boolean,
  p_max_helper_orders integer,
  p_max_approved_discount numeric,
  p_default_cashier_limit numeric,
  p_gcash_enabled boolean,
  p_gcash_account_name text,
  p_gcash_number text,
  p_cashier_limits jsonb -- Retained for RPC compatibility; individual overrides are ignored.
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update store settings';
  end if;
  if p_auto_assign_orders is null or p_gcash_enabled is null
     or p_max_helper_orders is null or p_max_helper_orders not between 1 and 30
     or p_max_approved_discount is null or p_max_approved_discount not between 0 and 100
     or p_default_cashier_limit is null
     or p_default_cashier_limit not between 0 and p_max_approved_discount then
    raise exception 'Store settings contain invalid limits';
  end if;
  insert into public.store_settings (
    location_id,
    auto_assign_orders,
    max_active_orders_per_helper,
    max_approved_discount_pct,
    cashier_auto_approved_discount_limit_pct,
    gcash_enabled,
    gcash_account_name,
    gcash_number
  ) values (
    v_profile.location_id,
    p_auto_assign_orders,
    p_max_helper_orders,
    p_max_approved_discount,
    p_default_cashier_limit,
    p_gcash_enabled,
    trim(coalesce(p_gcash_account_name, '')),
    trim(coalesce(p_gcash_number, ''))
  )
  on conflict (location_id) do update set
    auto_assign_orders = excluded.auto_assign_orders,
    max_active_orders_per_helper = excluded.max_active_orders_per_helper,
    max_approved_discount_pct = excluded.max_approved_discount_pct,
    cashier_auto_approved_discount_limit_pct = excluded.cashier_auto_approved_discount_limit_pct,
    gcash_enabled = excluded.gcash_enabled,
    gcash_account_name = excluded.gcash_account_name,
    gcash_number = excluded.gcash_number;

  return true;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.update_settings_dashboard_v1(
  text, boolean, integer, numeric, numeric, boolean, text, text, jsonb
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.update_settings_dashboard_v1(
  text, boolean, integer, numeric, numeric, boolean, text, text, jsonb
) FROM PUBLIC, authenticated;
