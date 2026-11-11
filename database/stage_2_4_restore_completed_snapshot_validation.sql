-- Inventory Plus Stage 2.4 prerequisite restoration.
--
-- MANUAL EXECUTION ONLY. This file has not been executed by Codex.
--
-- Restores only the completed-order snapshot validator and the two triggers
-- originally defined in database/stage_6b5_data_integrity_remediation.sql.
-- Existing rows are not inspected or modified. No RLS, grants on tables,
-- seasonal data, products, orders, or order-history rows are changed.

begin;

-- Avoid waiting indefinitely for the brief table locks required by CREATE
-- TRIGGER. A timeout rolls the entire transaction back without a partial
-- installation.
set local lock_timeout = '5s';
set local statement_timeout = '2min';

-- Fail before DDL if the live tables no longer match the definitions against
-- which the original validator was authored.
do $preflight$
declare
  v_mismatch text;
begin
  if to_regnamespace('private') is null then
    raise exception 'Required schema private is missing.';
  end if;

  if to_regclass('public.orders') is null then
    raise exception 'Required table public.orders is missing.';
  end if;

  if to_regclass('public.order_history') is null then
    raise exception 'Required table public.order_history is missing.';
  end if;

  select string_agg(
    format(
      'public.%I.%I expected %s, found %s',
      required.table_name,
      required.column_name,
      required.udt_name,
      coalesce(actual.udt_name, '<missing>')
    ),
    '; ' order by required.table_name, required.column_name
  )
  into v_mismatch
  from (values
    ('orders', 'status', 'text'),
    ('orders', 'items', 'jsonb'),
    ('orders', 'completed_at', 'timestamptz'),
    ('order_history', 'status', 'text'),
    ('order_history', 'items', 'jsonb'),
    ('order_history', 'completed_at', 'timestamptz')
  ) as required(table_name, column_name, udt_name)
  left join information_schema.columns actual
    on actual.table_schema = 'public'
   and actual.table_name = required.table_name
   and actual.column_name = required.column_name
  where actual.column_name is null
     or actual.udt_name <> required.udt_name;

  if v_mismatch is not null then
    raise exception 'Completed-snapshot validator schema mismatch: %',
      v_mismatch;
  end if;
end;
$preflight$;

-- Exact intended definition from stage_6b5_data_integrity_remediation.sql.
create or replace function private.assert_completed_order_snapshot_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_item jsonb;
  v_product_id text;
  v_quantity text;
begin
  if lower(trim(coalesce(new.status, ''))) <> 'completed' then
    return new;
  end if;
  if new.completed_at is null then
    raise exception 'completed_order_timestamp_required';
  end if;
  if jsonb_typeof(new.items) is distinct from 'array'
      or jsonb_array_length(new.items) = 0 then
    raise exception 'order_item_snapshot_invalid';
  end if;

  for v_item in select value from jsonb_array_elements(new.items)
  loop
    v_product_id := coalesce(
      v_item ->> 'product_id', v_item ->> 'productId', '');
    v_quantity := coalesce(v_item ->> 'quantity', '');
    if v_product_id
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        or v_quantity !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'order_item_snapshot_invalid';
    end if;
    if v_quantity::numeric <= 0 then
      raise exception 'order_item_snapshot_invalid';
    end if;
  end loop;
  return new;
end;
$function$;

revoke all on function private.assert_completed_order_snapshot_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists orders_validate_completed_snapshot_v1
  on public.orders;
create trigger orders_validate_completed_snapshot_v1
before insert or update of status, items, completed_at on public.orders
for each row execute function private.assert_completed_order_snapshot_v1();

drop trigger if exists order_history_validate_completed_snapshot_v1
  on public.order_history;
create trigger order_history_validate_completed_snapshot_v1
before insert or update of status, items, completed_at on public.order_history
for each row execute function private.assert_completed_order_snapshot_v1();

-- Refuse to commit unless each intended trigger exists exactly once, is
-- enabled, has the intended BEFORE ROW INSERT/UPDATE event mask, and calls the
-- intended function.
do $postcondition$
declare
  v_failed text;
begin
  select string_agg(
    format(
      'public.%I trigger %I: found=%s, valid=%s',
      expected.table_name,
      expected.trigger_name,
      state.found_count,
      state.valid_count
    ),
    '; ' order by expected.table_name
  )
  into v_failed
  from (values
    ('orders', 'orders_validate_completed_snapshot_v1'),
    ('order_history', 'order_history_validate_completed_snapshot_v1')
  ) as expected(table_name, trigger_name)
  cross join lateral (
    select
      count(*) as found_count,
      count(*) filter (
        where trigger_row.tgenabled in ('O', 'A')
          and trigger_row.tgtype = 23
          and trigger_row.tgfoid = to_regprocedure(
            'private.assert_completed_order_snapshot_v1()'
          )
      ) as valid_count
    from pg_catalog.pg_trigger trigger_row
    join pg_catalog.pg_class table_row
      on table_row.oid = trigger_row.tgrelid
    join pg_catalog.pg_namespace schema_row
      on schema_row.oid = table_row.relnamespace
    where schema_row.nspname = 'public'
      and table_row.relname = expected.table_name
      and trigger_row.tgname = expected.trigger_name
      and not trigger_row.tgisinternal
  ) state
  where state.found_count <> 1
     or state.valid_count <> 1;

  if v_failed is not null then
    raise exception 'Completed-snapshot trigger postcondition failed: %',
      v_failed;
  end if;
end;
$postcondition$;

commit;

-- -------------------------------------------------------------------------
-- READ-ONLY VERIFICATION
-- This second transaction changes no data or schema. Run it independently if
-- the SQL Editor stops after the migration transaction.
-- -------------------------------------------------------------------------
begin transaction read only;

with expected_triggers(table_name, trigger_name) as (
  values
    ('orders', 'orders_validate_completed_snapshot_v1'),
    ('order_history', 'order_history_validate_completed_snapshot_v1')
),
function_state as (
  select
    function_row.oid,
    function_row.prosecdef as security_definer,
    namespace_row.nspname as schema_name,
    pg_catalog.pg_get_function_identity_arguments(function_row.oid)
      as identity_arguments
  from pg_catalog.pg_proc function_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = function_row.pronamespace
  where function_row.oid = to_regprocedure(
    'private.assert_completed_order_snapshot_v1()'
  )
),
trigger_state as (
  select
    expected.table_name,
    expected.trigger_name,
    count(trigger_row.oid) as found_count,
    count(trigger_row.oid) filter (
      where trigger_row.tgenabled in ('O', 'A')
        and trigger_row.tgtype = 23
        and trigger_row.tgfoid = to_regprocedure(
          'private.assert_completed_order_snapshot_v1()'
        )
    ) as valid_count
  from expected_triggers expected
  left join pg_catalog.pg_namespace schema_row
    on schema_row.nspname = 'public'
  left join pg_catalog.pg_class table_row
    on table_row.relnamespace = schema_row.oid
   and table_row.relname = expected.table_name
  left join pg_catalog.pg_trigger trigger_row
    on trigger_row.tgrelid = table_row.oid
   and trigger_row.tgname = expected.trigger_name
   and not trigger_row.tgisinternal
  group by expected.table_name, expected.trigger_name
),
checks(check_order, check_name, status, details) as (
  select
    10,
    'private.assert_completed_order_snapshot_v1()',
    case
      when count(*) = 1
       and bool_and(security_definer)
       and bool_and(schema_name = 'private')
       and bool_and(identity_arguments = '')
        then 'PASS'
      else 'FAIL'
    end,
    format(
      'found=%s, security_definer=%s',
      count(*),
      coalesce(bool_and(security_definer), false)
    )
  from function_state

  union all

  select
    case when table_name = 'orders' then 20 else 30 end,
    format('public.%I.%I', table_name, trigger_name),
    case when found_count = 1 and valid_count = 1
      then 'PASS' else 'FAIL' end,
    format('found=%s, enabled_type_and_binding_valid=%s',
      found_count, valid_count)
  from trigger_state
),
results as (
  select check_order, check_name, status, details from checks
  union all
  select
    99,
    'OVERALL',
    case when bool_and(status = 'PASS') then 'PASS' else 'FAIL' end,
    format('%s/3 checks passed', count(*) filter (where status = 'PASS'))
  from checks
)
select check_name, status, details
from results
order by check_order;

commit;
