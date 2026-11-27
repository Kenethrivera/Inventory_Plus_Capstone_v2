-- Read store settings through the application's session token. The client uses
-- a custom session, so direct PostgREST reads run as anon and cannot see this
-- RLS-protected table.
create or replace function public.store_settings_snapshot_v1(
  p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_session record;
  v_settings public.store_settings%rowtype;
  v_result jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'invalid_or_expired_session' using errcode = '28000';
  end if;

  select * into v_settings
  from public.store_settings
  where location_id = v_session.location_id;
  if not found then return null; end if;

  v_result := jsonb_build_object(
    'gcash_qr_url', v_settings.gcash_qr_url,
    'gcash_account_name', v_settings.gcash_account_name,
    'gcash_number', v_settings.gcash_number,
    'gcash_alt_qr_url', v_settings.gcash_alt_qr_url,
    'gcash_alt_account_name', v_settings.gcash_alt_account_name,
    'gcash_alt_number', v_settings.gcash_alt_number,
    'cashier_auto_approved_discount_limit_pct',
      v_settings.cashier_auto_approved_discount_limit_pct
  );
  if v_session.role = 'admin' then
    v_result := v_result || jsonb_build_object(
      'auto_assign_orders', v_settings.auto_assign_orders,
      'max_active_orders_per_helper', v_settings.max_active_orders_per_helper,
      'max_approved_discount_pct', v_settings.max_approved_discount_pct
    );
  end if;
  return v_result;
end;
$function$;

revoke all on function public.store_settings_snapshot_v1(text)
from public, authenticated;
grant execute on function public.store_settings_snapshot_v1(text)
to anon, service_role;
