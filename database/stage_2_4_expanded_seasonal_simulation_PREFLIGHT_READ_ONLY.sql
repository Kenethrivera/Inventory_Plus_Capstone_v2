-- INVENTORY PLUS STAGE 2.4 -- LIVE READ-ONLY IMPORT PREFLIGHT
--
-- Run this complete file in Supabase SQL Editor before enabling the import.
-- It performs catalog and duplicate checks only. PostgreSQL enforces READ ONLY
-- for the entire transaction, so an accidental write in this script will fail.
--
-- Expected result: every row, including OVERALL, reports PASS.

begin transaction read only;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

with
parameters as (
  select
    1::bigint as admin_profile_id,
    '11111111-1111-1111-1111-111111111111'::uuid as location_id,
    'sim-season-v1:'::text as import_tag
),
planned_products(product_id, sku) as (
  values
    ('31000000-0000-4000-8000-000000000001'::uuid, 'SIM-SUM-001'),
    ('31000000-0000-4000-8000-000000000002'::uuid, 'SIM-SUM-002'),
    ('31000000-0000-4000-8000-000000000003'::uuid, 'SIM-SUM-003'),
    ('31000000-0000-4000-8000-000000000004'::uuid, 'SIM-SUM-004'),
    ('31000000-0000-4000-8000-000000000005'::uuid, 'SIM-SUM-005'),
    ('31000000-0000-4000-8000-000000000006'::uuid, 'SIM-SUM-006'),
    ('31000000-0000-4000-8000-000000000007'::uuid, 'SIM-SUM-007'),
    ('31000000-0000-4000-8000-000000000008'::uuid, 'SIM-SUM-008'),
    ('32000000-0000-4000-8000-000000000001'::uuid, 'SIM-RAIN-001'),
    ('32000000-0000-4000-8000-000000000002'::uuid, 'SIM-RAIN-002'),
    ('32000000-0000-4000-8000-000000000003'::uuid, 'SIM-RAIN-003'),
    ('32000000-0000-4000-8000-000000000004'::uuid, 'SIM-RAIN-004'),
    ('32000000-0000-4000-8000-000000000005'::uuid, 'SIM-RAIN-005'),
    ('32000000-0000-4000-8000-000000000006'::uuid, 'SIM-RAIN-006'),
    ('32000000-0000-4000-8000-000000000007'::uuid, 'SIM-RAIN-007'),
    ('32000000-0000-4000-8000-000000000008'::uuid, 'SIM-RAIN-008'),
    ('33000000-0000-4000-8000-000000000001'::uuid, 'SIM-NEU-001'),
    ('33000000-0000-4000-8000-000000000002'::uuid, 'SIM-NEU-002'),
    ('33000000-0000-4000-8000-000000000003'::uuid, 'SIM-NEU-003'),
    ('33000000-0000-4000-8000-000000000004'::uuid, 'SIM-NEU-004'),
    ('33000000-0000-4000-8000-000000000005'::uuid, 'SIM-NEU-005'),
    ('33000000-0000-4000-8000-000000000006'::uuid, 'SIM-NEU-006'),
    ('33000000-0000-4000-8000-000000000007'::uuid, 'SIM-NEU-007'),
    ('33000000-0000-4000-8000-000000000008'::uuid, 'SIM-NEU-008')
),
required_tables(schema_name, table_name) as (
  values
    ('public', 'locations'),
    ('public', 'profiles'),
    ('public', 'products'),
    ('public', 'orders'),
    ('public', 'order_history'),
    ('public', 'transaction_history')
),
required_columns(schema_name, table_name, column_name, expected_udt) as (
  values
    ('public', 'locations', 'id', 'uuid'),
    ('public', 'profiles', 'id', 'int8'),
    ('public', 'profiles', 'name', 'text'),
    ('public', 'profiles', 'role', 'text'),
    ('public', 'profiles', 'location_id', 'uuid'),
    ('public', 'products', 'id', 'uuid'),
    ('public', 'products', 'sku', 'text'),
    ('public', 'products', 'product_name', 'text'),
    ('public', 'products', 'category', 'text'),
    ('public', 'products', 'description', 'text'),
    ('public', 'products', 'unit', 'text'),
    ('public', 'products', 'product_price', 'numeric'),
    ('public', 'products', 'product_quantity', 'numeric'),
    ('public', 'products', 'max_quantity', 'numeric'),
    ('public', 'products', 'created_at', 'timestamptz'),
    ('public', 'products', 'updated_at', 'timestamptz'),
    ('public', 'products', 'location_id', 'uuid'),
    ('public', 'products', 'is_active', 'bool'),
    ('public', 'products', 'create_operation_id', 'text'),
    ('public', 'orders', 'id', 'uuid'),
    ('public', 'orders', 'status', 'text'),
    ('public', 'orders', 'items', 'jsonb'),
    ('public', 'orders', 'location_id', 'uuid'),
    ('public', 'orders', 'created_by', 'int8'),
    ('public', 'orders', 'prepared_by', 'int8'),
    ('public', 'orders', 'created_at', 'timestamptz'),
    ('public', 'orders', 'updated_at', 'timestamptz'),
    ('public', 'orders', 'total_amount', 'numeric'),
    ('public', 'orders', 'discount_amount', 'numeric'),
    ('public', 'orders', 'payment_mode', 'text'),
    ('public', 'orders', 'cash_given', 'float8'),
    ('public', 'orders', 'change_amount', 'float8'),
    ('public', 'orders', 'completed_at', 'timestamptz'),
    ('public', 'orders', 'prepared_at', 'timestamptz'),
    ('public', 'orders', 'created_by_id', 'text'),
    ('public', 'orders', 'created_by_name', 'text'),
    ('public', 'orders', 'prepared_by_id', 'text'),
    ('public', 'orders', 'prepared_by_name', 'text'),
    ('public', 'orders', 'completed_by_id', 'text'),
    ('public', 'orders', 'completed_by_name', 'text'),
    ('public', 'orders', 'checkout_operation_id', 'text'),
    ('public', 'order_history', 'order_id', 'text'),
    ('public', 'order_history', 'location_id', 'uuid'),
    ('public', 'order_history', 'status', 'text'),
    ('public', 'order_history', 'items', 'jsonb'),
    ('public', 'order_history', 'completed_at', 'timestamptz'),
    ('public', 'transaction_history', 'id', 'uuid'),
    ('public', 'transaction_history', 'created_at', 'timestamptz'),
    ('public', 'transaction_history', 'product_id', 'uuid'),
    ('public', 'transaction_history', 'user_id', 'int8'),
    ('public', 'transaction_history', 'user_name', 'text'),
    ('public', 'transaction_history', 'transaction_type', 'text'),
    ('public', 'transaction_history', 'quantity_change', 'numeric'),
    ('public', 'transaction_history', 'new_quantity', 'numeric'),
    ('public', 'transaction_history', 'location_id', 'uuid'),
    ('public', 'transaction_history', 'note', 'text'),
    ('public', 'transaction_history', 'operation_id', 'text'),
    ('public', 'transaction_history', 'operation_scope', 'text')
),
required_functions(function_name, function_identity) as (
  values
    ('private.require_app_session_v1',
      'private.require_app_session_v1(text)'),
    ('public.profile_restore_session_v1',
      'public.profile_restore_session_v1(text)'),
    ('public.forecast_daily_demand_v1',
      'public.forecast_daily_demand_v1(text,timestamptz,timestamptz,text)'),
    ('public.forecast_product_context_v1',
      'public.forecast_product_context_v1(text,uuid)'),
    ('public.sync_order_history_v1',
      'public.sync_order_history_v1()'),
    ('private.assert_completed_order_snapshot_v1',
      'private.assert_completed_order_snapshot_v1()')
),
required_constraints(table_name, constraint_name) as (
  values
    ('products', 'products_pkey'),
    ('products', 'products_sku_key'),
    ('products', 'products_location_id_fkey'),
    ('products', 'products_product_price_check'),
    ('products', 'products_product_quantity_check'),
    ('orders', 'orders_pkey'),
    ('orders', 'orders_status_check'),
    ('orders', 'orders_location_id_fkey'),
    ('orders', 'orders_created_by_fkey'),
    ('orders', 'orders_prepared_by_fkey'),
    ('order_history', 'order_history_pkey'),
    ('transaction_history', 'transaction_history_pkey'),
    ('transaction_history', 'transaction_history_product_id_fkey'),
    ('transaction_history', 'transaction_history_location_id_fkey'),
    ('transaction_history', 'transaction_history_user_id_fkey')
),
required_indexes(index_name) as (
  values
    ('products_create_operation_unique'),
    ('orders_checkout_operation_unique'),
    ('transaction_history_operation_unique')
),
trigger_state as (
  select
    trigger_row.tgname,
    count(*) as trigger_count,
    count(*) filter (
      where trigger_row.tgenabled in ('O', 'A')
    ) as enabled_count,
    count(*) filter (
      where trigger_row.tgenabled in ('O', 'A')
        and trigger_row.tgtype = case trigger_row.tgname
          when 'orders_sync_order_history_v1' then 21
          else 23
        end
        and trigger_row.tgfoid = to_regprocedure(
          case trigger_row.tgname
            when 'orders_sync_order_history_v1'
              then 'public.sync_order_history_v1()'
            else 'private.assert_completed_order_snapshot_v1()'
          end
        )
    ) as correctly_bound_count
  from pg_catalog.pg_trigger trigger_row
  join pg_catalog.pg_class table_row
    on table_row.oid = trigger_row.tgrelid
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and not trigger_row.tgisinternal
    and (
      (table_row.relname = 'orders' and trigger_row.tgname in (
        'orders_sync_order_history_v1',
        'orders_validate_completed_snapshot_v1'
      ))
      or (
        table_row.relname = 'order_history'
        and trigger_row.tgname = 'order_history_validate_completed_snapshot_v1'
      )
    )
  group by trigger_row.tgname
),
checks(check_order, check_name, status, details) as (
  select
    10,
    'required tables',
    case when count(*) filter (
      where to_regclass(format('%I.%I', schema_name, table_name)) is null
    ) = 0 then 'PASS' else 'FAIL' end,
    coalesce(
      string_agg(
        format('%I.%I', schema_name, table_name), ', '
      ) filter (
        where to_regclass(format('%I.%I', schema_name, table_name)) is null
      ),
      'all required tables exist'
    )
  from required_tables

  union all
  select
    20,
    'required columns and types',
    case when count(*) filter (
      where actual.column_name is null
        or actual.udt_name is distinct from required.expected_udt
    ) = 0 then 'PASS' else 'FAIL' end,
    coalesce(
      string_agg(
        format(
          '%I.%I expected %s; found %s',
          required.table_name,
          required.column_name,
          required.expected_udt,
          coalesce(actual.udt_name, 'MISSING')
        ),
        ' | '
      ) filter (
        where actual.column_name is null
          or actual.udt_name is distinct from required.expected_udt
      ),
      'all required columns have compatible PostgreSQL types'
    )
  from required_columns required
  left join information_schema.columns actual
    on actual.table_schema = required.schema_name
   and actual.table_name = required.table_name
   and actual.column_name = required.column_name

  union all
  select
    30,
    'required function signatures',
    case when count(*) filter (
      where to_regprocedure(function_identity) is null
    ) = 0 then 'PASS' else 'FAIL' end,
    coalesce(
      string_agg(function_name, ', ') filter (
        where to_regprocedure(function_identity) is null
      ),
      'all required function signatures exist'
    )
  from required_functions

  union all
  select
    40,
    'required constraints',
    case when count(*) filter (
      where constraint_row.oid is null
    ) = 0 then 'PASS' else 'FAIL' end,
    coalesce(
      string_agg(
        format('%I.%I', required.table_name, required.constraint_name), ', '
      ) filter (where constraint_row.oid is null),
      'all required primary, unique, foreign-key, and check constraints exist'
    )
  from required_constraints required
  left join pg_catalog.pg_constraint constraint_row
    on constraint_row.conname = required.constraint_name
   and constraint_row.conrelid = to_regclass(
     format('public.%I', required.table_name)
   )

  union all
  select
    50,
    'required idempotency indexes',
    case when count(*) filter (
      where to_regclass('public.' || index_name) is null
    ) = 0 then 'PASS' else 'FAIL' end,
    coalesce(
      string_agg(index_name, ', ') filter (
        where to_regclass('public.' || index_name) is null
      ),
      'all required unique idempotency indexes exist'
    )
  from required_indexes

  union all
  select
    60,
    'orders to order_history synchronization trigger',
    case when coalesce(trigger_count, 0) = 1
           and coalesce(enabled_count, 0) = 1
           and coalesce(correctly_bound_count, 0) = 1
      then 'PASS' else 'FAIL' end,
    format(
      'found=%s, enabled=%s, enabled_and_bound_to_sync_order_history=%s',
      coalesce(trigger_count, 0),
      coalesce(enabled_count, 0),
      coalesce(correctly_bound_count, 0)
    )
  from (values ('orders_sync_order_history_v1')) expected(tgname)
  left join trigger_state using (tgname)

  union all
  select
    70,
    'orders completed-snapshot validation trigger',
    case when coalesce(trigger_count, 0) = 1
           and coalesce(enabled_count, 0) = 1
           and coalesce(correctly_bound_count, 0) = 1
      then 'PASS' else 'FAIL' end,
    format(
      'found=%s, enabled=%s, enabled_and_bound_to_validator=%s',
      coalesce(trigger_count, 0),
      coalesce(enabled_count, 0),
      coalesce(correctly_bound_count, 0)
    )
  from (values ('orders_validate_completed_snapshot_v1')) expected(tgname)
  left join trigger_state using (tgname)

  union all
  select
    80,
    'order_history completed-snapshot validation trigger',
    case when coalesce(trigger_count, 0) = 1
           and coalesce(enabled_count, 0) = 1
           and coalesce(correctly_bound_count, 0) = 1
      then 'PASS' else 'FAIL' end,
    format(
      'found=%s, enabled=%s, enabled_and_bound_to_validator=%s',
      coalesce(trigger_count, 0),
      coalesce(enabled_count, 0),
      coalesce(correctly_bound_count, 0)
    )
  from (values ('order_history_validate_completed_snapshot_v1')) expected(tgname)
  left join trigger_state using (tgname)

  union all
  select
    90,
    'target location',
    case when count(location.id) = 1 then 'PASS' else 'FAIL' end,
    format('matching target locations=%s', count(location.id))
  from parameters parameter
  left join public.locations location on location.id = parameter.location_id

  union all
  select
    100,
    'existing Admin and location',
    case when count(profile.id) = 1 then 'PASS' else 'FAIL' end,
    format('matching Admin profiles=%s', count(profile.id))
  from parameters parameter
  left join public.profiles profile
    on profile.id = parameter.admin_profile_id
   and lower(trim(profile.role)) = 'admin'
   and profile.location_id = parameter.location_id

  union all
  select
    110,
    'planned product ID, SKU, and import-tag collisions',
    case when count(product.id) = 0 then 'PASS' else 'FAIL' end,
    format('matching existing products=%s', count(product.id))
  from parameters parameter
  cross join planned_products planned
  left join public.products product
    on product.id = planned.product_id
    or product.sku = planned.sku
    or product.create_operation_id = parameter.import_tag || 'product:' || planned.sku

  union all
  select
    120,
    'tagged order collisions',
    case when count(order_row.id) = 0 then 'PASS' else 'FAIL' end,
    format('matching tagged orders=%s', count(order_row.id))
  from parameters parameter
  left join public.orders order_row
    on order_row.checkout_operation_id like parameter.import_tag || '%'

  union all
  select
    130,
    'deterministic order ID collisions',
    case when count(order_row.id) = 0 then 'PASS' else 'FAIL' end,
    format('matching deterministic order IDs=%s', count(order_row.id))
  from generate_series(
    date '2022-11-10', date '2026-11-09', interval '1 day'
  ) generated(business_date)
  left join public.orders order_row
    on order_row.id = md5(
      'expanded-ph-seasonal-simulation-v1|order|'
      || generated.business_date::date
    )::uuid

  union all
  select
    140,
    'deterministic order_history ID collisions',
    case when count(history.order_id) = 0 then 'PASS' else 'FAIL' end,
    format('matching deterministic order_history IDs=%s', count(history.order_id))
  from generate_series(
    date '2022-11-10', date '2026-11-09', interval '1 day'
  ) generated(business_date)
  left join public.order_history history
    on history.order_id = md5(
      'expanded-ph-seasonal-simulation-v1|order|'
      || generated.business_date::date
    )::uuid::text

  union all
  select
    150,
    'tagged inventory-movement collisions',
    case when count(history.id) = 0 then 'PASS' else 'FAIL' end,
    format('matching tagged movements=%s', count(history.id))
  from parameters parameter
  left join public.transaction_history history
    on history.operation_id like parameter.import_tag || '%'
),
final_rows(check_order, check_name, status, details) as (
  select check_order, check_name, status, details from checks
  union all
  select
    999,
    'OVERALL',
    case when bool_and(status = 'PASS') then 'PASS' else 'FAIL' end,
    format(
      '%s of %s checks passed; do not enable the import unless all pass',
      count(*) filter (where status = 'PASS'),
      count(*)
    )
  from checks
)
select check_name, status, details
from final_rows
order by check_order;

commit;
