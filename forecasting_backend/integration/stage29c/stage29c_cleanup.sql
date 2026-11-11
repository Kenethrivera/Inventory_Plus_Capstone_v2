-- WRITE/DESTRUCTIVE SCRIPT FOR THE AUTHORIZED DISPOSABLE DATABASE ONLY.
-- Removes only Stage 2.9C proposal objects and fixed Stage 2.9C fixtures.
-- It deliberately does not remove the operator-created environment marker.

begin;

do $guard$
begin
  if to_regclass('private.stage29c_isolated_environment') is null or not exists (
    select 1
    from private.stage29c_isolated_environment
    where marker = 'inventory-plus-stage29c'
      and project_ref = current_setting(
        'inventory_plus.stage29c_expected_project_ref', true)
      and purpose = 'inventory-plus-stage29c-isolated-integration'
      and allow_schema_writes is true
  ) then
    raise exception 'Stage 2.9C cleanup guard rejected this database';
  end if;
end;
$guard$;

drop function if exists public.forecast_recommendation_tracking_v1(text, uuid);
drop function if exists public.reconcile_forecast_recommendation_v1(
  text, uuid, bigint, boolean, text
);
drop function if exists public.match_forecast_recommendation_receipt_v1(
  text, bigint, uuid, numeric
);
drop function if exists public.save_forecast_recommendation_snapshot_v1(
  text, uuid, uuid, text, text, integer, boolean, timestamptz, timestamptz,
  integer, date, date, numeric, numeric, text, jsonb
);
drop function if exists public.forecast_recommendation_snapshot_by_request_v1(
  text, uuid
);

drop table if exists public.forecast_recommendation_reconciliations;
drop table if exists public.forecast_recommendation_receipt_allocations;
drop table if exists public.forecast_recommendation_snapshots;
drop function if exists private.reject_forecast_recommendation_mutation_v1();

delete from private.app_sessions where profile_id in (-29001, -29002);
delete from public.transaction_history
where operation_scope = 'stage29c-isolated-test';
delete from public.products
where id in (
  '29c00000-0000-4000-8000-000000000001',
  '29c00000-0000-4000-8000-000000000002'
);
delete from public.profiles where id in (-29001, -29002);
delete from public.locations
where id = '29c00000-0000-4000-8000-000000000001';

commit;
