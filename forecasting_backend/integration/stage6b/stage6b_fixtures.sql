\set ON_ERROR_STOP on

\if :{?stage6b_persist_fixtures}
\else
\set stage6b_persist_fixtures false
\endif

\if :{?stage6b_expected_project_ref}
\else
\echo 'stage6b_expected_project_ref is required'
\quit
\endif

begin;
set local inventory_plus.stage6b_expected_project_ref = :'stage6b_expected_project_ref';

do $guard$
begin
  if to_regclass('private.stage6b_isolated_environment') is null then
    raise exception 'Stage 6B fixture guard: isolated marker table is absent';
  end if;
  if not exists (
    select 1
    from private.stage6b_isolated_environment
    where marker = 'inventory-plus-stage6b'
      and allow_fixture_writes is true
      and project_ref = current_setting(
        'inventory_plus.stage6b_expected_project_ref')
      and purpose = 'inventory-plus-stage6b-isolated-integration'
  ) then
    raise exception 'Stage 6B fixture guard: isolated identity is not authorized';
  end if;
end;
$guard$;

insert into public.locations (id, location_name, store_key)
values
  ('61000000-0000-4000-8000-000000000001', 'Stage6B Location A', 'stage6b-a'),
  ('61000000-0000-4000-8000-000000000002', 'Stage6B Location B', 'stage6b-b');

insert into public.profiles (
  id, name, username, password, role, location_id
) values
  (-61001, 'Stage6B Admin A', 'stage6b_admin_a', 'not-used', 'admin',
    '61000000-0000-4000-8000-000000000001'),
  (-61002, 'Stage6B Cashier A', 'stage6b_cashier_a', 'not-used', 'staff',
    '61000000-0000-4000-8000-000000000001'),
  (-61003, 'Stage6B Helper A', 'stage6b_helper_a', 'not-used', 'helper',
    '61000000-0000-4000-8000-000000000001'),
  (-61004, 'Stage6B Admin B', 'stage6b_admin_b', 'not-used', 'admin',
    '61000000-0000-4000-8000-000000000002');

insert into private.app_sessions (token_hash, profile_id, expires_at)
values
  (extensions.digest(convert_to('stage6b-admin-a', 'UTF8'), 'sha256'),
    -61001, '2099-01-01T00:00:00Z'),
  (extensions.digest(convert_to('stage6b-cashier-a', 'UTF8'), 'sha256'),
    -61002, '2099-01-01T00:00:00Z'),
  (extensions.digest(convert_to('stage6b-helper-a', 'UTF8'), 'sha256'),
    -61003, '2099-01-01T00:00:00Z'),
  (extensions.digest(convert_to('stage6b-admin-b', 'UTF8'), 'sha256'),
    -61004, '2099-01-01T00:00:00Z'),
  (extensions.digest(convert_to('stage6b-expired', 'UTF8'), 'sha256'),
    -61001, '2000-01-01T00:00:00Z');

insert into public.products (
  id, sku, product_name, unit, product_quantity, max_quantity,
  location_id, created_at, updated_at, is_active
) values
  ('61a00000-0000-4000-8000-000000000001', 'S6B-A-1',
    'Stage6B Product A', 'pcs', 20, 100,
    '61000000-0000-4000-8000-000000000001',
    '2026-11-01T00:00:00+08', '2026-11-04T00:00:00+08', true),
  ('61a00000-0000-4000-8000-000000000002', 'S6B-A-EMPTY',
    'Stage6B No History', 'pcs', 5, 50,
    '61000000-0000-4000-8000-000000000001',
    '2026-11-04T00:00:00+08', '2026-11-04T00:00:00+08', true),
  ('61b00000-0000-4000-8000-000000000001', 'S6B-B-1',
    'Stage6B Product B', 'pcs', 20, 100,
    '61000000-0000-4000-8000-000000000002',
    '2026-10-01T00:00:00+08', '2026-11-04T00:00:00+08', true);

-- Location A: valid, excluded-status, returned, and midnight cases.
insert into public.order_history (
  order_id, location_id, status, items, created_at, completed_at, returned_at
) values
  ('stage6b-a-completed-1', '61000000-0000-4000-8000-000000000001',
    'completed',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","product_name":"Stage6B Product A","unit":"pcs","quantity":2},{"productId":"61a00000-0000-4000-8000-000000000001","productName":"Stage6B Product A","unit":"pcs","quantity":1}]',
    '2026-11-01T15:00:00Z', '2026-11-01T15:59:59Z', null),
  ('stage6b-a-completed-2', '61000000-0000-4000-8000-000000000001',
    'completed',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","product_name":"Stage6B Product A","unit":"pcs","quantity":4}]',
    '2026-11-01T15:10:00Z', '2026-11-01T15:30:00Z', null),
  ('stage6b-a-midnight', '61000000-0000-4000-8000-000000000001',
    'completed',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","product_name":"Stage6B Product A","unit":"pcs","quantity":5}]',
    '2026-11-01T16:00:00Z', '2026-11-01T16:00:00Z', null),
  ('stage6b-a-pending', '61000000-0000-4000-8000-000000000001',
    'pending',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","quantity":99}]',
    '2026-11-01T12:00:00Z', null, null),
  ('stage6b-a-cancelled', '61000000-0000-4000-8000-000000000001',
    'cancelled',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","quantity":99}]',
    '2026-11-01T12:00:00Z', null, null),
  ('stage6b-a-returned', '61000000-0000-4000-8000-000000000001',
    'completed',
    '[{"product_id":"61a00000-0000-4000-8000-000000000001","quantity":99}]',
    '2026-11-01T12:00:00Z', '2026-11-01T13:00:00Z',
    '2026-11-02T13:00:00Z'),
  ('stage6b-a-legacy-product', '61000000-0000-4000-8000-000000000001',
    'completed',
    '[{"product_id":"61a00000-0000-4000-8000-000000000099","product_name":"Legacy Snapshot","unit":"pcs","quantity":3}]',
    '2026-11-01T10:00:00Z', '2026-11-01T11:00:00Z', null);

-- Location B contains malformed cases in separate time windows.
insert into public.order_history (
  order_id, location_id, status, items, created_at, completed_at, returned_at
) values
  ('stage6b-b-valid', '61000000-0000-4000-8000-000000000002',
    'completed',
    '[{"product_id":"61b00000-0000-4000-8000-000000000001","quantity":2}]',
    '2026-09-01T00:00:00Z', '2026-09-01T01:00:00Z', null),
  ('stage6b-b-empty', '61000000-0000-4000-8000-000000000002',
    'completed', '[]', '2026-10-01T00:00:00Z', '2026-10-01T01:00:00Z', null),
  ('stage6b-b-invalid-id', '61000000-0000-4000-8000-000000000002',
    'completed', '[{"product_id":"not-a-uuid","quantity":1}]',
    '2026-10-02T00:00:00Z', '2026-10-02T01:00:00Z', null),
  ('stage6b-b-invalid-quantity', '61000000-0000-4000-8000-000000000002',
    'completed',
    '[{"product_id":"61b00000-0000-4000-8000-000000000001","quantity":0}]',
    '2026-10-03T00:00:00Z', '2026-10-03T01:00:00Z', null),
  ('stage6b-b-unit-pcs', '61000000-0000-4000-8000-000000000002',
    'completed',
    '[{"product_id":"61b00000-0000-4000-8000-000000000001","unit":"pcs","quantity":1}]',
    '2026-10-04T00:00:00Z', '2026-10-04T01:00:00Z', null),
  ('stage6b-b-unit-box', '61000000-0000-4000-8000-000000000002',
    'completed',
    '[{"product_id":"61b00000-0000-4000-8000-000000000001","unit":"box","quantity":1}]',
    '2026-10-04T02:00:00Z', '2026-10-04T03:00:00Z', null),
  ('stage6b-b-missing-completion', '61000000-0000-4000-8000-000000000002',
    'completed',
    '[{"product_id":"61b00000-0000-4000-8000-000000000001","quantity":1}]',
    '2026-10-05T00:00:00Z', null, null);

-- Exact aggregation, status filtering, midnight conversion, legacy snapshot,
-- and location isolation.
do $positive$
declare
  v_quantity numeric;
  v_orders bigint;
  v_count bigint;
begin
  select quantity, completed_order_count into v_quantity, v_orders
  from public.forecast_daily_demand_v1(
    'stage6b-admin-a', '2026-11-01T00:00:00+08',
    '2026-11-02T00:00:00+08', 'Asia/Manila'
  )
  where product_id = '61a00000-0000-4000-8000-000000000001';
  if v_quantity is distinct from 7 or v_orders is distinct from 2 then
    raise exception 'Stage 6B aggregation assertion failed';
  end if;

  select count(*) into v_count
  from public.forecast_daily_demand_v1(
    'stage6b-admin-a', '2026-11-01T00:00:00+08',
    '2026-11-02T00:00:00+08', 'Asia/Manila'
  ) where business_date <> '2026-11-01' or
    location_id <> '61000000-0000-4000-8000-000000000001';
  if v_count <> 0 then
    raise exception 'Stage 6B boundary or location assertion failed';
  end if;

  select count(*) into v_count
  from public.forecast_daily_demand_v1(
    'stage6b-admin-a', '2026-11-02T00:00:00+08',
    '2026-11-03T00:00:00+08', 'Asia/Manila'
  ) where business_date = '2026-11-02' and quantity = 5;
  if v_count <> 1 then
    raise exception 'Stage 6B Philippine-midnight assertion failed';
  end if;

  select count(*) into v_count
  from public.forecast_daily_demand_v1(
    'stage6b-admin-a', '2026-11-01T00:00:00+08',
    '2026-11-02T00:00:00+08', 'Asia/Manila'
  ) where product_id = '61a00000-0000-4000-8000-000000000099'
    and sku is null and product_name = 'Legacy Snapshot';
  if v_count <> 1 then
    raise exception 'Stage 6B legacy-snapshot assertion failed';
  end if;
end;
$positive$;

-- Denied role, invalid, and expired session paths.
do $denials$
declare
  v_denied boolean;
  v_token text;
begin
  foreach v_token in array array[
    'stage6b-cashier-a', 'stage6b-helper-a',
    'stage6b-expired', 'stage6b-invalid'
  ] loop
    v_denied := false;
    begin
      perform * from public.forecast_daily_demand_v1(
        v_token, '2026-11-01T00:00:00+08',
        '2026-11-02T00:00:00+08', 'Asia/Manila'
      );
    exception when others then
      v_denied := true;
    end;
    if not v_denied then
      raise exception 'Stage 6B denial assertion failed';
    end if;
  end loop;
end;
$denials$;

-- Malformed cases must fail closed.
do $malformed$
declare
  v_failed boolean;
  v_day date;
begin
  foreach v_day in array array['2026-10-01'::date, '2026-10-02'::date,
    '2026-10-03'::date] loop
    v_failed := false;
    begin
      perform * from public.forecast_daily_demand_v1(
        'stage6b-admin-b', v_day::timestamptz,
        (v_day + 1)::timestamptz, 'Asia/Manila'
      );
    exception when others then
      v_failed := true;
    end;
    if not v_failed then
      raise exception 'Stage 6B malformed snapshot did not fail closed';
    end if;
  end loop;
end;
$malformed$;

-- A missing completion timestamp is relevant when the record's possible
-- completion interval overlaps the requested window. Both SQL and Python must
-- reject it rather than silently understating demand.
do $missing_completion_contract$
declare
  v_failed boolean := false;
begin
  begin
    perform * from public.forecast_daily_demand_v1(
      'stage6b-admin-b', '2026-10-05T00:00:00+00',
      '2026-10-06T00:00:00+00', 'Asia/Manila'
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Stage 6B missing completed_at was silently omitted';
  end if;
end;
$missing_completion_contract$;

\if :stage6b_persist_fixtures

commit;

\else

rollback;

\endif
