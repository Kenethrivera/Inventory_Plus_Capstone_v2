-- Run once before deploying the second GCash account UI.
alter table public.store_settings
  add column if not exists gcash_alt_account_name text not null default '',
  add column if not exists gcash_alt_number text not null default '',
  add column if not exists gcash_alt_qr_url text not null default '';

-- The POS no longer has a GCash availability switch.
update public.store_settings set gcash_enabled = true where gcash_enabled = false;
do $block$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.store_settings'::regclass
      and conname = 'store_settings_gcash_always_enabled_check'
  ) then
    alter table public.store_settings
      add constraint store_settings_gcash_always_enabled_check
      check (gcash_enabled = true);
  end if;
end;
$block$;

create or replace function public.update_settings_dashboard_v2(
  p_session_token text,
  p_auto_assign_orders boolean,
  p_max_helper_orders integer,
  p_max_approved_discount numeric,
  p_default_cashier_limit numeric,
  p_gcash_account_name text,
  p_gcash_number text,
  p_gcash_alt_account_name text,
  p_gcash_alt_number text
) returns boolean
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update store settings';
  end if;
  if p_auto_assign_orders is null
     or p_max_helper_orders is null or p_max_helper_orders not between 1 and 30
     or p_max_approved_discount is null or p_max_approved_discount not between 0 and 100
     or p_default_cashier_limit is null
     or p_default_cashier_limit not between 0 and p_max_approved_discount
     or (trim(coalesce(p_gcash_alt_account_name, '')) = '') <>
        (trim(coalesce(p_gcash_alt_number, '')) = '')
     or (trim(coalesce(p_gcash_alt_number, '')) <> '' and
         trim(p_gcash_alt_number) !~ '^09[0-9]{9}$')
     or (trim(coalesce(p_gcash_alt_number, '')) <> '' and
         trim(p_gcash_alt_number) = trim(coalesce(p_gcash_number, ''))) then
    raise exception 'Store settings contain invalid limits or GCash details';
  end if;

  insert into public.store_settings (
    location_id, auto_assign_orders, max_active_orders_per_helper,
    max_approved_discount_pct, cashier_auto_approved_discount_limit_pct,
    gcash_enabled, gcash_account_name, gcash_number,
    gcash_alt_account_name, gcash_alt_number
  ) values (
    v_profile.location_id, p_auto_assign_orders, p_max_helper_orders,
    p_max_approved_discount, p_default_cashier_limit,
    true, trim(coalesce(p_gcash_account_name, '')),
    trim(coalesce(p_gcash_number, '')),
    trim(coalesce(p_gcash_alt_account_name, '')),
    trim(coalesce(p_gcash_alt_number, ''))
  ) on conflict (location_id) do update set
    auto_assign_orders = excluded.auto_assign_orders,
    max_active_orders_per_helper = excluded.max_active_orders_per_helper,
    max_approved_discount_pct = excluded.max_approved_discount_pct,
    cashier_auto_approved_discount_limit_pct = excluded.cashier_auto_approved_discount_limit_pct,
    gcash_enabled = true,
    gcash_account_name = excluded.gcash_account_name,
    gcash_number = excluded.gcash_number,
    gcash_alt_account_name = excluded.gcash_alt_account_name,
    gcash_alt_number = excluded.gcash_alt_number;
  return true;
end;
$function$;

grant execute on function public.update_settings_dashboard_v2(
  text, boolean, integer, numeric, numeric, text, text, text, text
) to anon, service_role, postgres;
revoke all on function public.update_settings_dashboard_v2(
  text, boolean, integer, numeric, numeric, text, text, text, text
) from public, authenticated;

create or replace function public.update_secondary_gcash_qr_v1(
  p_session_token text,
  p_gcash_qr_url text
) returns text
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_qr_url text;
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update payment settings';
  end if;
  v_qr_url := trim(coalesce(p_gcash_qr_url, ''));
  insert into public.store_settings (location_id, gcash_alt_qr_url)
  values (v_profile.location_id, v_qr_url)
  on conflict (location_id) do update set gcash_alt_qr_url = excluded.gcash_alt_qr_url;
  return v_qr_url;
end;
$function$;

grant execute on function public.update_secondary_gcash_qr_v1(text, text)
  to anon, service_role, postgres;
revoke all on function public.update_secondary_gcash_qr_v1(text, text)
  from public, authenticated;
