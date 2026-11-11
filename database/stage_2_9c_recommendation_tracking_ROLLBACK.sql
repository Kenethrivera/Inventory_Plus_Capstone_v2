-- INVENTORY PLUS - STAGE 2.9C TARGETED ROLLBACK
-- MANUAL EXECUTION ONLY.
--
-- This removes only Stage 2.9C recommendation-tracking objects. It never
-- truncates or changes products, inventory, sales, orders, transaction history,
-- profiles, locations, authentication, forecasting data, or purchase orders.
--
-- SAFETY: if any recommendation history exists, this script refuses removal.
-- A separate, explicit decision to destroy/export that history is required.
-- Only after that review, change v_history_removal_authorized from false to
-- true below. Do not make that change merely to bypass the guard.

begin;
set local lock_timeout = '10s';
set local statement_timeout = '5min';

do $preflight$
declare
  v_history_removal_authorized boolean := false;
  v_snapshot_rows bigint := 0;
  v_allocation_rows bigint := 0;
  v_reconciliation_rows bigint := 0;
begin
  if to_regclass('public.forecast_recommendation_snapshots') is not null then
    execute 'select count(*) from public.forecast_recommendation_snapshots'
      into v_snapshot_rows;
  end if;
  if to_regclass(
      'public.forecast_recommendation_receipt_allocations') is not null then
    execute
      'select count(*) from public.forecast_recommendation_receipt_allocations'
      into v_allocation_rows;
  end if;
  if to_regclass(
      'public.forecast_recommendation_reconciliations') is not null then
    execute
      'select count(*) from public.forecast_recommendation_reconciliations'
      into v_reconciliation_rows;
  end if;

  if (v_snapshot_rows + v_allocation_rows + v_reconciliation_rows) > 0
      and not v_history_removal_authorized then
    raise exception using
      message = format(
        'Stage 2.9C rollback refused: history exists '
        '(snapshots=%s, allocations=%s, reconciliations=%s).',
        v_snapshot_rows, v_allocation_rows, v_reconciliation_rows
      ),
      hint = 'Export/review history and separately authorize removal first.';
  end if;

  -- A partial installation is allowed, but an unrelated object using one of
  -- these names is not. Where a tracking table exists, verify its identifying
  -- Stage 2.9C comment before permitting removal.
  if to_regclass('public.forecast_recommendation_snapshots') is not null
      and coalesce(obj_description(to_regclass(
        'public.forecast_recommendation_snapshots'), 'pg_class'), '') <>
        'Immutable owner-saved demand-minus-stock recommendation snapshots; no external FKs so product deletion does not erase or block history.'
  then
    raise exception
      'Rollback refused: forecast_recommendation_snapshots identity is unexpected.';
  end if;
  if to_regclass(
      'public.forecast_recommendation_receipt_allocations') is not null
      and coalesce(obj_description(to_regclass(
        'public.forecast_recommendation_receipt_allocations'),
        'pg_class'), '') <>
        'Explicit immutable allocations of genuine stock_in receipt snapshots to earlier recommendations; not backorders or forecast accuracy.'
  then
    raise exception
      'Rollback refused: receipt allocation table identity is unexpected.';
  end if;
  if to_regclass(
      'public.forecast_recommendation_reconciliations') is not null
      and coalesce(obj_description(to_regclass(
        'public.forecast_recommendation_reconciliations'),
        'pg_class'), '') <>
        'Explicit owner confirmation that a recommendation-to-receipt comparison is complete.'
  then
    raise exception
      'Rollback refused: reconciliation table identity is unexpected.';
  end if;

  if exists (
    select 1
    from (values
      ('private.reject_forecast_recommendation_mutation_v1()'),
      ('public.forecast_recommendation_snapshot_by_request_v1(text,uuid)'),
      ('public.save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamptz,timestamptz,integer,date,date,numeric,numeric,text,jsonb)'),
      ('public.match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)'),
      ('public.reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)'),
      ('public.forecast_recommendation_tracking_v1(text,uuid)')
    ) expected(signature)
    cross join lateral (
      select to_regprocedure(expected.signature) as function_oid
    ) resolved
    where resolved.function_oid is not null
      and coalesce(obj_description(
        resolved.function_oid, 'pg_proc'), '') <>
        'Inventory Plus Stage 2.9C recommendation tracking.'
  ) then
    raise exception
      'Rollback refused: a recommendation function identity is unexpected.';
  end if;
end;
$preflight$;

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

do $verify$
begin
  if to_regclass('public.forecast_recommendation_snapshots') is not null
      or to_regclass(
        'public.forecast_recommendation_receipt_allocations') is not null
      or to_regclass(
        'public.forecast_recommendation_reconciliations') is not null
      or to_regprocedure(
        'public.forecast_recommendation_snapshot_by_request_v1(text,uuid)')
        is not null
      or to_regprocedure(
        'public.save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamptz,timestamptz,integer,date,date,numeric,numeric,text,jsonb)')
        is not null
      or to_regprocedure(
        'public.match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)')
        is not null
      or to_regprocedure(
        'public.reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)')
        is not null
      or to_regprocedure(
        'public.forecast_recommendation_tracking_v1(text,uuid)') is not null
      or to_regprocedure(
        'private.reject_forecast_recommendation_mutation_v1()') is not null
  then
    raise exception 'Stage 2.9C rollback verification failed.';
  end if;
end;
$verify$;

commit;
