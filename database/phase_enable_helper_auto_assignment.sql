-- Apply after phase_bodegero_loading.sql and phase_settings_dashboard_gcash.sql.
-- The current Settings UI does not expose auto_assign_orders, so an older
-- false value must not silently disable Helper assignment.
begin;

alter table public.store_settings
  alter column auto_assign_orders set default true;

update public.store_settings
set auto_assign_orders = true
where auto_assign_orders is distinct from true;

commit;
