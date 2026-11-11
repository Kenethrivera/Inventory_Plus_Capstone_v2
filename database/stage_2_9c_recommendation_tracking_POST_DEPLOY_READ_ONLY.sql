-- INVENTORY PLUS - STAGE 2.9C POST-DEPLOYMENT VERIFICATION
-- READ ONLY. Safe to run after the manual migration and before backend enablement.

begin transaction read only;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

with
expected_tables(table_name) as (
  values
    ('forecast_recommendation_snapshots'),
    ('forecast_recommendation_receipt_allocations'),
    ('forecast_recommendation_reconciliations')
),
expected_functions(signature, expected_stable) as (
  values
    ('public.forecast_recommendation_snapshot_by_request_v1(text,uuid)', true),
    ('public.save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamptz,timestamptz,integer,date,date,numeric,numeric,text,jsonb)', false),
    ('public.match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)', false),
    ('public.reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)', false),
    ('public.forecast_recommendation_tracking_v1(text,uuid)', true)
),
expected_constraints(table_name, constraint_name) as (
  values
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_request_unique'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_model_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_horizon_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_period_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_predicted_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_inventory_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_recommended_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_identity_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_assumptions_check'),
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_hash_check'),
    ('forecast_recommendation_receipt_allocations',
      'forecast_recommendation_receipt_pair_unique'),
    ('forecast_recommendation_receipt_allocations',
      'forecast_recommendation_receipt_quantity_check'),
    ('forecast_recommendation_receipt_allocations',
      'forecast_recommendation_receipt_identity_check'),
    ('forecast_recommendation_receipt_allocations',
      'forecast_recommendation_receipt_unit_evidence_check'),
    ('forecast_recommendation_reconciliations',
      'forecast_recommendation_reconcile_request_unique'),
    ('forecast_recommendation_reconciliations',
      'forecast_recommendation_reconcile_quantity_check'),
    ('forecast_recommendation_reconciliations',
      'forecast_recommendation_reconcile_receipt_state_check'),
    ('forecast_recommendation_reconciliations',
      'forecast_recommendation_reconcile_actor_check')
),
expected_indexes(index_name) as (
  values
    ('forecast_recommendation_snapshots_product_created_idx'),
    ('forecast_recommendation_receipts_recommendation_idx'),
    ('forecast_recommendation_receipts_transaction_idx')
),
expected_triggers(table_name, trigger_name) as (
  values
    ('forecast_recommendation_snapshots',
      'forecast_recommendation_snapshots_immutable_v1'),
    ('forecast_recommendation_receipt_allocations',
      'forecast_recommendation_receipts_immutable_v1'),
    ('forecast_recommendation_reconciliations',
      'forecast_recommendation_reconciliations_immutable_v1')
),
checks as (
  select
    '01_tables_exist_and_rls_enabled'::text as check_name,
    case when count(c.oid) = 3 and bool_and(c.relrowsecurity)
      then 'PASS' else 'FAIL' end as status,
    format('found=%s rls_enabled=%s', count(c.oid),
      count(*) filter (where c.relrowsecurity)) as details
  from expected_tables expected
  left join pg_class c
    on c.relname = expected.table_name and c.relkind = 'r'
   and c.relnamespace = 'public'::regnamespace

  union all
  select
    '02_rpc_signatures_security_and_owner',
    case when count(p.oid) = 5
          and bool_and(p.prosecdef)
          and bool_and(pg_get_userbyid(p.proowner) = 'postgres')
          and bool_and(coalesce(obj_description(p.oid, 'pg_proc'), '') =
            'Inventory Plus Stage 2.9C recommendation tracking.')
          and bool_and(
            has_function_privilege('service_role', p.oid, 'EXECUTE'))
          and bool_and(
            not has_function_privilege('anon', p.oid, 'EXECUTE'))
          and bool_and(
            not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
          and bool_and(
            (expected.expected_stable and p.provolatile = 's')
            or (not expected.expected_stable and p.provolatile = 'v'))
      then 'PASS' else 'FAIL' end,
    format('found=%s service_only=%s security_definer=%s postgres_owned=%s identified=%s',
      count(p.oid),
      count(*) filter (where
        has_function_privilege('service_role', p.oid, 'EXECUTE')
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and not has_function_privilege('authenticated', p.oid, 'EXECUTE')),
      count(*) filter (where p.prosecdef),
      count(*) filter (where pg_get_userbyid(p.proowner) = 'postgres'),
      count(*) filter (where coalesce(obj_description(p.oid, 'pg_proc'), '') =
        'Inventory Plus Stage 2.9C recommendation tracking.'))
  from expected_functions expected
  left join pg_proc p on p.oid = to_regprocedure(expected.signature)

  union all
  select
    '03_named_constraints',
    case when count(con.oid) = (select count(*) from expected_constraints)
      then 'PASS' else 'FAIL' end,
    format('found=%s expected=%s', count(con.oid),
      (select count(*) from expected_constraints))
  from expected_constraints expected
  left join pg_class c
    on c.relname = expected.table_name
   and c.relnamespace = 'public'::regnamespace
  left join pg_constraint con
    on con.conrelid = c.oid and con.conname = expected.constraint_name

  union all
  select
    '04_internal_foreign_keys_only',
    case when count(*) = 2
          and bool_and(con.confrelid =
            'public.forecast_recommendation_snapshots'::regclass)
      then 'PASS' else 'FAIL' end,
    format('foreign_keys=%s external_foreign_keys=%s', count(*),
      count(*) filter (where con.confrelid <>
        'public.forecast_recommendation_snapshots'::regclass))
  from pg_constraint con
  where con.contype = 'f'
    and con.conrelid in (
      'public.forecast_recommendation_snapshots'::regclass,
      'public.forecast_recommendation_receipt_allocations'::regclass,
      'public.forecast_recommendation_reconciliations'::regclass
    )

  union all
  select
    '05_supporting_indexes',
    case when count(indexes.indexname) = 3
      then 'PASS' else 'FAIL' end,
    format('found=%s expected=3', count(indexes.indexname))
  from expected_indexes expected
  left join pg_indexes indexes
    on indexes.schemaname = 'public'
   and indexes.indexname = expected.index_name

  union all
  select
    '06_immutability_triggers',
    case when count(t.oid) = 3
          and bool_and(t.tgenabled in ('O', 'A'))
          and bool_and(proc.proname =
            'reject_forecast_recommendation_mutation_v1')
          and bool_and(coalesce(obj_description(proc.oid, 'pg_proc'), '') =
            'Inventory Plus Stage 2.9C recommendation tracking.')
          and bool_and(not has_function_privilege(
            'service_role', proc.oid, 'EXECUTE'))
          and bool_and(not has_function_privilege(
            'anon', proc.oid, 'EXECUTE'))
          and bool_and(not has_function_privilege(
            'authenticated', proc.oid, 'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    format('found=%s enabled=%s correct_function=%s', count(t.oid),
      count(*) filter (where t.tgenabled in ('O', 'A')),
      count(*) filter (where proc.proname =
        'reject_forecast_recommendation_mutation_v1'))
  from expected_triggers expected
  left join pg_class c
    on c.relname = expected.table_name
   and c.relnamespace = 'public'::regnamespace
  left join pg_trigger t
    on t.tgrelid = c.oid and t.tgname = expected.trigger_name
   and not t.tgisinternal
  left join pg_proc proc on proc.oid = t.tgfoid

  union all
  select
    '07_no_direct_table_access',
    case when count(*) filter (where
        has_table_privilege(role_name, table_name, 'SELECT,INSERT,UPDATE,DELETE')) = 0
      then 'PASS' else 'FAIL' end,
    format('unexpected_role_table_grants=%s', count(*) filter (where
      has_table_privilege(role_name, table_name,
        'SELECT,INSERT,UPDATE,DELETE')))
  from (values ('anon'), ('authenticated'), ('service_role')) roles(role_name)
  cross join (values
    ('public.forecast_recommendation_snapshots'),
    ('public.forecast_recommendation_receipt_allocations'),
    ('public.forecast_recommendation_reconciliations')
  ) tables(table_name)

  union all
  select
    '08_no_direct_sequence_access',
    case when count(*) filter (where
        has_sequence_privilege(role_name, sequence_name, 'USAGE')) = 0
      then 'PASS' else 'FAIL' end,
    format('unexpected_role_sequence_grants=%s', count(*) filter (where
      has_sequence_privilege(role_name, sequence_name, 'USAGE')))
  from (values ('anon'), ('authenticated'), ('service_role')) roles(role_name)
  cross join (values
    ('public.forecast_recommendation_snapshots_id_seq'),
    ('public.forecast_recommendation_receipt_allocations_id_seq'),
    ('public.forecast_recommendation_reconciliations_id_seq')
  ) sequences(sequence_name)

  union all
  select
    '09_base_objects_unchanged',
    case when to_regclass('public.products') is not null
          and to_regclass('public.transaction_history') is not null
          and to_regclass('public.locations') is not null
          and to_regclass('public.profiles') is not null
          and to_regclass('public.approval_requests') is not null
          and to_regclass('private.app_sessions') is not null
          and to_regprocedure('private.require_app_session_v1(text)') is not null
      then 'PASS' else 'FAIL' end,
    'products, transaction_history, locations, profiles, approvals and app sessions'
),
reported as (
  select * from checks
  union all
  select
    'OVERALL',
    case when bool_and(status = 'PASS') then 'PASS' else 'FAIL' end,
    format('checks=%s passed=%s', count(*),
      count(*) filter (where status = 'PASS'))
  from checks
)
select check_name, status, details
from reported
order by case when check_name = 'OVERALL' then 2 else 1 end, check_name;

-- Informational row counts. Nonzero values are valid after tracking is used.
select
  (select count(*) from public.forecast_recommendation_snapshots)
    as recommendation_snapshots,
  (select count(*) from public.forecast_recommendation_receipt_allocations)
    as receipt_allocations,
  (select count(*) from public.forecast_recommendation_reconciliations)
    as reconciliations,
  (select count(*) from public.products) as products_unchanged_reference,
  (select count(*) from public.transaction_history)
    as transaction_history_unchanged_reference;

commit;
