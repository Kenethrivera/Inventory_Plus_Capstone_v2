-- INVENTORY PLUS - STAGE 2.9C RECOMMENDATION TRACKING PREFLIGHT
-- READ-ONLY DIAGNOSTIC ONLY. Safe to run in Supabase SQL Editor.
--
-- This script contains SELECT statements only. It does not call application
-- RPCs, create temporary objects, change transaction settings, or write data.
-- PASS means the live database matches the revised proposal's verified
-- prerequisite. NOT VERIFIED means metadata/data cannot prove the behavior.

with
expected_columns(table_name, column_name, data_type) as (
  values
    ('products', 'id', 'uuid'),
    ('products', 'sku', 'text'),
    ('products', 'product_name', 'text'),
    ('products', 'product_quantity', 'numeric'),
    ('products', 'location_id', 'uuid'),
    ('products', 'unit', 'text'),
    ('products', 'is_active', 'boolean'),
    ('transaction_history', 'id', 'uuid'),
    ('transaction_history', 'created_at', 'timestamp with time zone'),
    ('transaction_history', 'product_id', 'uuid'),
    ('transaction_history', 'location_id', 'uuid'),
    ('transaction_history', 'transaction_type', 'text'),
    ('transaction_history', 'quantity_change', 'numeric'),
    ('transaction_history', 'new_quantity', 'numeric'),
    ('transaction_history', 'operation_id', 'text'),
    ('transaction_history', 'operation_scope', 'text'),
    ('locations', 'id', 'uuid'),
    ('profiles', 'id', 'bigint'),
    ('profiles', 'role', 'text'),
    ('profiles', 'location_id', 'uuid'),
    ('profiles', 'is_active', 'boolean'),
    ('forecast_replenishment_configs', 'product_id', 'uuid'),
    ('forecast_replenishment_configs', 'location_id', 'uuid'),
    ('forecast_replenishment_configs', 'supplier_order_unit', 'text'),
    ('forecast_replenishment_configs', 'unit_conversion_factor', 'numeric'),
    ('approval_requests', 'id', 'uuid'),
    ('approval_requests', 'product_id', 'uuid'),
    ('approval_requests', 'request_type', 'text'),
    ('approval_requests', 'status', 'text'),
    ('approval_requests', 'unit', 'text'),
    ('approval_requests', 'transaction_id', 'uuid')
),
column_check as (
  select
    count(*) as expected_count,
    count(c.column_name) filter (where c.data_type = e.data_type) as matched_count,
    string_agg(
      format('%s.%s expected %s, found %s',
        e.table_name,
        e.column_name,
        e.data_type,
        coalesce(c.data_type, '<missing>')
      ),
      '; ' order by e.table_name, e.column_name
    ) filter (where c.column_name is null or c.data_type <> e.data_type)
      as mismatches
  from expected_columns e
  left join information_schema.columns c
    on c.table_schema = 'public'
   and c.table_name = e.table_name
   and c.column_name = e.column_name
),
required_functions(schema_name, function_name, identity_arguments) as (
  values
    ('private', 'require_app_session_v1', 'p_session_token text'),
    ('public', 'adjust_inventory_quantity_v1',
      'p_session_token text, p_operation_id text, p_product_id uuid, p_expected_quantity numeric, p_new_quantity numeric, p_transaction_type text, p_note text'),
    ('public', 'approve_inventory_approval_request_v1',
      'p_session_token text, p_request_id uuid, p_review_note text'),
    ('public', 'forecast_daily_demand_v1',
      'p_session_token text, p_period_start timestamp with time zone, p_period_end timestamp with time zone, p_business_timezone text'),
    ('public', 'forecast_product_context_v1',
      'p_session_token text, p_product_id uuid'),
    ('public', 'forecast_replenishment_config_v1',
      'p_session_token text, p_product_id uuid')
),
function_check as (
  select
    count(*) as expected_count,
    count(p.oid) as matched_count,
    string_agg(
      format('%I.%I(%s)', r.schema_name, r.function_name, r.identity_arguments),
      '; ' order by r.schema_name, r.function_name
    ) filter (where p.oid is null) as missing
  from required_functions r
  left join pg_namespace n on n.nspname = r.schema_name
  left join pg_proc p
    on p.pronamespace = n.oid
   and p.proname = r.function_name
   and pg_get_function_identity_arguments(p.oid) = r.identity_arguments
),
restock_stats as (
  select
    count(*) filter (where th.transaction_type = 'stock_in') as receipt_count,
    count(*) filter (
      where th.transaction_type = 'stock_in'
        and (
          th.quantity_change is null
          or th.quantity_change <= 0
          or th.product_id is null
          or th.location_id is null
        )
    ) as invalid_receipt_count,
    count(*) filter (
      where th.transaction_type = 'stock_in'
        and ar.id is not null
        and length(btrim(coalesce(ar.unit, ''))) > 0
    ) as approval_unit_receipt_count
  from public.transaction_history th
  left join public.approval_requests ar
    on ar.transaction_id = th.id
   and ar.request_type = 'restock'
   and ar.status = 'approved'
),
proposal_conflicts as (
  select
    (
      select count(*)
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname in (
          'forecast_recommendation_snapshots',
          'forecast_recommendation_receipt_allocations',
          'forecast_recommendation_reconciliations'
        )
    ) + (
      select count(*)
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where (n.nspname, p.proname) in (
        ('private', 'reject_forecast_recommendation_mutation_v1'),
        ('public', 'forecast_recommendation_snapshot_by_request_v1'),
        ('public', 'save_forecast_recommendation_snapshot_v1'),
        ('public', 'match_forecast_recommendation_receipt_v1'),
        ('public', 'reconcile_forecast_recommendation_v1'),
        ('public', 'forecast_recommendation_tracking_v1')
      )
    ) + (
      select count(*)
      from pg_trigger t
      where not t.tgisinternal
        and t.tgname in (
          'forecast_recommendation_snapshots_immutable_v1',
          'forecast_recommendation_receipts_immutable_v1',
          'forecast_recommendation_reconciliations_immutable_v1'
        )
    ) as conflict_count
),
checks(check_number, check_name, status, details) as (
  select 1, 'required public tables',
    case when count(*) = 6 then 'PASS' else 'FAIL' end,
    format('%s of 6 found', count(*))
  from information_schema.tables
  where table_schema = 'public'
    and table_name in (
      'products', 'transaction_history', 'locations', 'profiles',
      'forecast_replenishment_configs', 'approval_requests'
    )

  union all
  select 2, 'required columns and data types',
    case when matched_count = expected_count then 'PASS' else 'FAIL' end,
    case
      when matched_count = expected_count then format('%s of %s match', matched_count, expected_count)
      else coalesce(mismatches, 'unknown mismatch')
    end
  from column_check

  union all
  select 3, 'required function signatures',
    case when matched_count = expected_count then 'PASS' else 'FAIL' end,
    case
      when matched_count = expected_count then format('%s of %s match', matched_count, expected_count)
      else coalesce(missing, 'unknown missing function')
    end
  from function_check

  union all
  select 4, 'session validator security-definer contract',
    case when exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'private'
        and p.proname = 'require_app_session_v1'
        and pg_get_function_identity_arguments(p.oid) = 'p_session_token text'
        and p.prosecdef
        and p.provolatile = 's'
    ) then 'PASS' else 'FAIL' end,
    'Expected STABLE SECURITY DEFINER private.require_app_session_v1(text)'

  union all
  select 5, 'stock receipt representation',
    case
      when receipt_count = 0 then 'NOT VERIFIED'
      when invalid_receipt_count = 0 then 'PASS'
      else 'FAIL'
    end,
    format('%s stock_in rows; %s invalid/nonpositive/unscoped',
      receipt_count, invalid_receipt_count)
  from restock_stats

  union all
  select 6, 'transaction receipt unit contract',
    case when not exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = 'transaction_history'
        and column_name = 'unit'
    ) and exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = 'products'
        and column_name = 'unit'
        and data_type = 'text'
    ) then 'PASS' else 'FAIL' end,
    'transaction_history intentionally has no unit; quantity_change is the product inventory-unit delta'

  union all
  select 7, 'approved-restock unit snapshot coverage',
    case
      when receipt_count = 0 then 'NOT VERIFIED'
      when approval_unit_receipt_count = receipt_count then 'PASS'
      else 'NOT VERIFIED'
    end,
    format('%s of %s stock_in rows have an approved-request unit snapshot; unmatched rows require the current product unit',
      approval_unit_receipt_count, receipt_count)
  from restock_stats

  union all
  select 8, 'transaction-history product deletion behavior',
    case when exists (
      select 1
      from pg_constraint c
      join pg_class child on child.oid = c.conrelid
      join pg_namespace n on n.oid = child.relnamespace
      join pg_class parent on parent.oid = c.confrelid
      where c.contype = 'f'
        and n.nspname = 'public'
        and child.relname = 'transaction_history'
        and parent.relname = 'products'
        and c.confdeltype = 'c'
    ) then 'PASS' else 'FAIL' end,
    'Expected transaction_history.product_id -> products.id ON DELETE CASCADE; proposal therefore snapshots receipt identity without an external FK'

  union all
  select 9, 'proposal object-name conflicts',
    case when conflict_count = 0 then 'PASS' else 'FAIL' end,
    format('%s conflicting live tables/functions/triggers found', conflict_count)
  from proposal_conflicts

  union all
  select 10, 'pgcrypto SHA-256 prerequisite',
    case when exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'extensions'
        and p.proname = 'digest'
        and pg_get_function_identity_arguments(p.oid) = 'bytea, text'
    ) then 'PASS' else 'FAIL' end,
    'Expected extensions.digest(bytea,text) for request-payload hashes'

  union all
  select 11, 'inventory_movements dependency',
    case when to_regclass('public.inventory_movements') is null then 'PASS' else 'PASS' end,
    case
      when to_regclass('public.inventory_movements') is null
        then 'No inventory_movements table exists; verified transaction_history is authoritative for receipts'
      else 'inventory_movements exists but the proposal intentionally reads only verified transaction_history stock_in receipts'
    end

  union all
  select 12, 'inactive-product deletion exercise',
    case when count(*) filter (where not is_active) > 0
      then 'NOT VERIFIED' else 'NOT VERIFIED' end,
    format('%s inactive products exist; SQL metadata cannot safely exercise deletion in this read-only preflight',
      count(*) filter (where not is_active))
  from public.products

  union all
  select 13, 'secure product-deletion RPC deployment',
    case when exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = 'product_delete_inactive_v1'
    ) then 'PASS' else 'NOT VERIFIED' end,
    case when exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = 'product_delete_inactive_v1'
    ) then 'RPC exists' else 'RPC is not deployed; current application behavior must be verified from repository code' end

  union all
  select 14, 'current operational-table RLS posture',
    case when count(*) filter (where not c.relrowsecurity) = 0 then 'PASS' else 'FAIL' end,
    format('%s of 4 inspected operational tables have RLS disabled (existing risk; not changed by this proposal)',
      count(*) filter (where not c.relrowsecurity))
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('products', 'transaction_history', 'locations', 'profiles')

  union all
  select 15, 'trusted persistence caller currently deployed',
    'NOT VERIFIED',
    'Database metadata cannot prove the FastAPI credential boundary; do not activate persistence until the server-only service-role caller is separately reviewed'
)
select check_number, check_name, status, details
from checks
order by check_number;

-- Exact referenced-column metadata.
select
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name in (
    'products', 'transaction_history', 'locations', 'profiles',
    'forecast_replenishment_configs', 'approval_requests'
  )
order by c.table_name, c.ordinal_position;

-- Exact foreign keys and deletion actions affecting referenced tables.
select
  child.relname as child_table,
  c.conname as constraint_name,
  pg_get_constraintdef(c.oid, true) as definition,
  case c.confdeltype
    when 'a' then 'NO ACTION'
    when 'r' then 'RESTRICT'
    when 'c' then 'CASCADE'
    when 'n' then 'SET NULL'
    when 'd' then 'SET DEFAULT'
  end as on_delete
from pg_constraint c
join pg_class child on child.oid = c.conrelid
join pg_namespace n on n.oid = child.relnamespace
where c.contype = 'f'
  and n.nspname = 'public'
  and (
    child.relname in (
      'products', 'transaction_history', 'forecast_replenishment_configs',
      'approval_requests'
    )
    or c.confrelid in (
      'public.products'::regclass,
      'public.locations'::regclass,
      'public.profiles'::regclass,
      'public.transaction_history'::regclass
    )
  )
order by child.relname, c.conname;

-- Required function signatures, volatility, security mode, and ACLs.
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  pg_get_function_result(p.oid) as result_type,
  case p.provolatile when 'i' then 'IMMUTABLE' when 's' then 'STABLE' else 'VOLATILE' end as volatility,
  p.prosecdef as security_definer,
  coalesce(array_to_string(p.proacl, ','), '') as acl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where (n.nspname, p.proname) in (
  ('private', 'require_app_session_v1'),
  ('public', 'adjust_inventory_quantity_v1'),
  ('public', 'approve_inventory_approval_request_v1'),
  ('public', 'create_inventory_approval_request_v2'),
  ('public', 'forecast_daily_demand_v1'),
  ('public', 'forecast_product_context_v1'),
  ('public', 'forecast_replenishment_config_v1'),
  ('public', 'upsert_forecast_replenishment_config_v1'),
  ('public', 'product_set_active_v1'),
  ('public', 'product_delete_inactive_v1')
)
order by n.nspname, p.proname, identity_arguments;

-- Observed receipt types and integrity. This exposes no credentials/tokens.
select
  transaction_type,
  count(*) as row_count,
  count(*) filter (where quantity_change > 0) as positive_quantity_rows,
  count(*) filter (where quantity_change is null or quantity_change <= 0) as invalid_quantity_rows,
  min(created_at) as first_recorded_at,
  max(created_at) as last_recorded_at
from public.transaction_history
group by transaction_type
order by transaction_type;
