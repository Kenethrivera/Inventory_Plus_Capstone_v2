-- INVENTORY PLUS STAGE 2.4 -- CONTROLLED SEASONAL TEST IMPORT
--
-- This file is intentionally DISABLED. It has not been executed by Codex.
-- Stage 2.3 accepted the candidate for controlled testing, not normal use.
-- Live Supabase metadata must still be rechecked before any manual run.
--
-- If a later review authorizes this disposable-STAGING import:
--   1. Take a Supabase database backup / branch snapshot.
--   2. Run stage_2_4_expanded_seasonal_simulation_PREFLIGHT_READ_ONLY.sql.
--      Continue only when every check, including OVERALL, reports PASS.
--   3. Confirm profile 1 is the intended Admin at the target location.
--   4. Change the single _stage21_authorization value below from false to true.
--   5. Run the complete import block once in Supabase SQL Editor.
--
-- The import adds 24 NEW products and tagged synthetic orders/movements. It
-- does not update any existing product, user, location, setting, or RLS policy.
-- SUMMER/RAINY/NEUTRAL labels are deliberately NOT stored in operational data.

begin;

set local timezone = 'Asia/Manila';
set local lock_timeout = '10s';
set local statement_timeout = '15min';

create temporary table _stage21_authorization (
  approved boolean not null
) on commit drop;

-- REVIEW SAFETY SWITCH: leave false until a separate manual approval.
insert into _stage21_authorization values (false);

do $guard$
begin
  if not (select approved from _stage21_authorization) then
    raise exception
      'Stage 2.4 proposal is disabled. Complete manual review before import.';
  end if;
end;
$guard$;

create temporary table _stage21_plan (
  plan_index integer primary key,
  product_id uuid unique not null,
  sku text unique not null,
  product_name text not null,
  category text not null,
  description text not null,
  unit text not null,
  product_type text not null,
  seasonal_group text not null,
  baseline_daily double precision not null,
  primary_amplitude double precision not null,
  secondary_amplitude double precision not null,
  trend_per_year double precision not null,
  weekend_effect double precision not null,
  intermittency_probability double precision not null,
  quantity_step numeric not null,
  product_price numeric(12,2) not null,
  opening_stock numeric not null
) on commit drop;

insert into _stage21_plan values
  (1, '31000000-0000-4000-8000-000000000001', 'SIM-SUM-001', 'Concrete Hollow Blocks 4-inch', 'Masonry Materials', 'Concrete masonry units for walls and partitions.', 'pcs', 'concrete_hollow_block', 'SUMMER', 13.0, .28, .00, .03, -.08, 1.00, 1, 22, 300),
  (2, '31000000-0000-4000-8000-000000000002', 'SIM-SUM-002', 'Portland Cement 40kg', 'Cement and Concrete', 'Hydraulic binder for concrete, mortar, plaster and masonry work.', 'bag', 'portland_cement', 'SUMMER', 9.5, .24, .05, .01, -.05, 1.00, 1, 285, 180),
  (3, '31000000-0000-4000-8000-000000000003', 'SIM-SUM-003', 'Washed Construction Sand', 'Aggregates', 'Fine aggregate for concrete, mortar, plaster, bedding and filling.', 'cu.m.', 'sand_aggregate', 'SUMMER', 1.8, .38, .00, -.01, -.12, .78, .5, 1450, 45),
  (4, '31000000-0000-4000-8000-000000000004', 'SIM-SUM-004', 'Construction Gravel 3/4-inch', 'Aggregates', 'Coarse aggregate for concrete, drainage bases and filling.', 'cu.m.', 'gravel_aggregate', 'SUMMER', 1.5, .31, .08, .00, -.10, .72, .5, 1650, 40),
  (5, '31000000-0000-4000-8000-000000000005', 'SIM-SUM-005', 'Steel Reinforcing Bar 10mm', 'Steel Materials', 'Deformed reinforcing bar embedded in concrete structural work.', 'pcs', 'rebar', 'SUMMER', 6.5, .15, .04, .04, -.08, .94, 1, 195, 160),
  (6, '31000000-0000-4000-8000-000000000006', 'SIM-SUM-006', 'Exterior Masonry Paint 4L', 'Paint and Coatings', 'Exterior coating for masonry walls and weather-exposed surfaces.', 'pail', 'exterior_paint', 'SUMMER', 2.4, .42, .00, .02, .08, .88, 1, 680, 65),
  (7, '31000000-0000-4000-8000-000000000007', 'SIM-SUM-007', 'Cementitious Tile Adhesive 25kg', 'Tile Installation', 'Cementitious bonding material for wall and floor tile installation.', 'bag', 'tile_adhesive', 'SUMMER', 3.8, .16, .07, .05, .03, .94, 1, 330, 90),
  (8, '31000000-0000-4000-8000-000000000008', 'SIM-SUM-008', 'Masonry Mortar Mix 25kg', 'Cement and Concrete', 'Preblended mortar for laying masonry units and patching masonry.', 'bag', 'masonry_mortar_mix', 'SUMMER', 4.2, .22, .06, -.02, -.04, .91, 1, 245, 100),
  (9, '32000000-0000-4000-8000-000000000001', 'SIM-RAIN-001', 'Roof Waterproofing Sealant', 'Waterproofing and Sealants', 'Flexible compound for sealing roof joints, cracks and leak points.', 'tube', 'roofing_sealant', 'RAINY', 3.1, .38, .08, .03, .10, .94, 1, 185, 90),
  (10, '32000000-0000-4000-8000-000000000002', 'SIM-RAIN-002', 'Waterproofing Membrane Roll', 'Waterproofing and Sealants', 'Sheet membrane used to form a water-resistant barrier on compatible building surfaces.', 'roll', 'waterproofing_membrane', 'RAINY', 1.3, .42, .10, .00, .02, .68, 1, 1850, 35),
  (11, '32000000-0000-4000-8000-000000000003', 'SIM-RAIN-003', 'Galvanized Roof Flashing', 'Roofing Materials', 'Formed sheet material that directs water away from roof joints and penetrations.', 'sheet', 'roof_flashing', 'RAINY', 1.7, .18, .15, .01, -.04, .68, 1, 420, 45),
  (12, '32000000-0000-4000-8000-000000000004', 'SIM-RAIN-004', 'PVC Rain Gutter 3m', 'Roof Drainage', 'Roof-edge channel for collecting and directing rainwater.', 'pcs', 'rain_gutter', 'RAINY', 2.6, .26, .10, .02, .06, .86, 1, 390, 70),
  (13, '32000000-0000-4000-8000-000000000005', 'SIM-RAIN-005', 'PVC Gutter Downspout 3m', 'Roof Drainage', 'Vertical pipe that carries roof runoff from a gutter to drainage.', 'pcs', 'rain_gutter', 'RAINY', 2.1, .30, .09, -.01, .05, .88, 1, 360, 60),
  (14, '32000000-0000-4000-8000-000000000006', 'SIM-RAIN-006', 'Heavy-Duty Tarpaulin 4x6m', 'Protective Coverings', 'Water-resistant sheet used as a temporary cover and weather barrier.', 'pcs', 'heavy_duty_tarpaulin', 'RAINY', 3.7, .45, .05, .00, .12, .92, 1, 620, 85),
  (15, '32000000-0000-4000-8000-000000000007', 'SIM-RAIN-007', 'Drainage Sump Pump 1HP', 'Pumps and Drainage', 'Electric pump for removing accumulated water from pits and low areas.', 'pcs', 'drainage_sump_pump', 'RAINY', .42, .50, .00, .06, .00, .22, 1, 4850, 12),
  (16, '32000000-0000-4000-8000-000000000008', 'SIM-RAIN-008', 'Roof Leak Repair Tape', 'Waterproofing and Sealants', 'Adhesive-backed repair tape for temporary sealing of compatible roof leak points.', 'roll', 'roof_leak_repair_tape', 'RAINY', 1.8, .50, .04, .02, .08, .68, 1, 275, 50),
  (17, '33000000-0000-4000-8000-000000000001', 'SIM-NEU-001', 'Combination Pliers 8-inch', 'Hand Tools', 'General-purpose gripping, bending and cutting hand tool.', 'pcs', 'combination_pliers', 'NEUTRAL', 2.5, .00, .00, .02, .05, .90, 1, 290, 75),
  (18, '33000000-0000-4000-8000-000000000002', 'SIM-NEU-002', 'Hex Bolts M8 Box', 'Fasteners', 'Boxed threaded fasteners for compatible assembly and construction work.', 'box', 'hex_bolts', 'NEUTRAL', 5.8, .03, .00, .00, -.03, .98, 1, 240, 140),
  (19, '33000000-0000-4000-8000-000000000003', 'SIM-NEU-003', 'Retractable Utility Knife', 'Hand Tools', 'General-purpose cutting tool with a replaceable retractable blade.', 'pcs', 'utility_knife', 'NEUTRAL', 3.2, .00, .00, -.02, .07, .91, 1, 165, 80),
  (20, '33000000-0000-4000-8000-000000000004', 'SIM-NEU-004', 'HSS Drill Bit Set', 'Power Tool Accessories', 'Set of high-speed steel drill bits for compatible drilling tasks.', 'set', 'drill_bit', 'NEUTRAL', .95, .02, .02, .04, .08, .42, 1, 780, 28),
  (21, '33000000-0000-4000-8000-000000000005', 'SIM-NEU-005', 'Electrical Insulation Tape', 'Electrical Supplies', 'Pressure-sensitive insulating tape for compatible electrical wiring work.', 'roll', 'electrical_insulation_tape', 'NEUTRAL', 4.4, .00, .00, .01, .03, .97, 1, 45, 160),
  (22, '33000000-0000-4000-8000-000000000006', 'SIM-NEU-006', 'Wood Screws 2-inch Box', 'Fasteners', 'Boxed threaded fasteners for joining compatible timber and fixtures.', 'box', 'wood_screws', 'NEUTRAL', 3.6, .00, .04, .03, .02, .94, 1, 210, 110),
  (23, '33000000-0000-4000-8000-000000000007', 'SIM-NEU-007', 'Brass Padlock 40mm', 'Security Hardware', 'Portable keyed lock for compatible doors, gates, cabinets and storage.', 'pcs', 'padlock', 'NEUTRAL', 1.5, .00, .00, -.01, .05, .66, 1, 320, 45),
  (24, '33000000-0000-4000-8000-000000000008', 'SIM-NEU-008', 'LED Utility Bulb 9W Control', 'Electrical Supplies', 'No-sales control product retained to detect pooled-model false positives.', 'pcs', 'led_light_bulb', 'NEUTRAL', .00, .00, .00, .00, .00, .00, 1, 95, 20);

do $preflight$
declare
  v_count bigint;
  v_enabled_count bigint;
  v_missing text;
begin
  if to_regclass('public.products') is null
      or to_regclass('public.orders') is null
      or to_regclass('public.order_history') is null
      or to_regclass('public.transaction_history') is null then
    raise exception 'Required Inventory Plus tables are unavailable.';
  end if;

  if to_regprocedure(
    'public.forecast_daily_demand_v1(text,timestamptz,timestamptz,text)'
  ) is null then
    raise exception 'forecast_daily_demand_v1 signature changed.';
  end if;

  select string_agg(required.column_name, ', ' order by required.table_name,
    required.column_name)
  into v_missing
  from (values
    ('products', 'id'), ('products', 'sku'),
    ('products', 'product_name'), ('products', 'category'),
    ('products', 'description'), ('products', 'unit'),
    ('products', 'product_price'), ('products', 'product_quantity'),
    ('products', 'max_quantity'), ('products', 'created_at'),
    ('products', 'updated_at'), ('products', 'location_id'),
    ('products', 'is_active'), ('products', 'create_operation_id'),
    ('orders', 'id'), ('orders', 'status'), ('orders', 'items'),
    ('orders', 'location_id'), ('orders', 'created_by'),
    ('orders', 'prepared_by'), ('orders', 'created_at'),
    ('orders', 'updated_at'), ('orders', 'total_amount'),
    ('orders', 'discount_amount'), ('orders', 'payment_mode'),
    ('orders', 'cash_given'), ('orders', 'change_amount'),
    ('orders', 'completed_at'), ('orders', 'prepared_at'),
    ('orders', 'created_by_id'), ('orders', 'created_by_name'),
    ('orders', 'prepared_by_id'), ('orders', 'prepared_by_name'),
    ('orders', 'completed_by_id'), ('orders', 'completed_by_name'),
    ('orders', 'checkout_operation_id'),
    ('transaction_history', 'id'), ('transaction_history', 'created_at'),
    ('transaction_history', 'product_id'),
    ('transaction_history', 'user_id'),
    ('transaction_history', 'user_name'),
    ('transaction_history', 'transaction_type'),
    ('transaction_history', 'quantity_change'),
    ('transaction_history', 'new_quantity'),
    ('transaction_history', 'location_id'),
    ('transaction_history', 'note'),
    ('transaction_history', 'operation_id'),
    ('transaction_history', 'operation_scope')
  ) required(table_name, column_name)
  where not exists (
    select 1
    from information_schema.columns actual
    where actual.table_schema = 'public'
      and actual.table_name = required.table_name
      and actual.column_name = required.column_name
  );
  if v_missing is not null then
    raise exception 'Required import columns are missing: %.', v_missing;
  end if;

  select count(*) into v_count
  from public.profiles
  where id = 1
    and role = 'admin'
    and location_id = '11111111-1111-1111-1111-111111111111'::uuid;
  if v_count <> 1 then
    raise exception 'Expected existing Admin profile 1 at the target location.';
  end if;

  select count(*) into v_count
  from public.products product
  join _stage21_plan plan
    on plan.product_id = product.id or plan.sku = product.sku;
  if v_count <> 0 then
    raise exception 'A Stage 2.1 product ID or SKU already exists; aborting duplicate import.';
  end if;

  select count(*) into v_count
  from public.orders
  where checkout_operation_id like 'sim-season-v1:%';
  if v_count <> 0 then
    raise exception 'Stage 2.1 tagged orders already exist; use the rollback block first.';
  end if;

  select count(*) into v_count
  from public.transaction_history
  where operation_id like 'sim-season-v1:%';
  if v_count <> 0 then
    raise exception 'Stage 2.1 tagged movements already exist; use rollback first.';
  end if;

  select count(*) into v_count
  from pg_trigger trigger_row
  join pg_class table_row on table_row.oid = trigger_row.tgrelid
  join pg_namespace schema_row on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and table_row.relname = 'orders'
    and trigger_row.tgname = 'orders_sync_order_history_v1'
    and not trigger_row.tgisinternal
    and trigger_row.tgenabled <> 'D';
  if v_count <> 1 then
    raise exception 'orders -> order_history synchronization trigger changed.';
  end if;

  select
    count(*),
    count(*) filter (
      where trigger_row.tgenabled in ('O', 'A')
        and trigger_row.tgtype = 23
        and trigger_row.tgfoid = to_regprocedure(
          'private.assert_completed_order_snapshot_v1()'
        )
    )
  into v_count, v_enabled_count
  from pg_trigger trigger_row
  join pg_class table_row on table_row.oid = trigger_row.tgrelid
  join pg_namespace schema_row on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and table_row.relname = 'orders'
    and trigger_row.tgname = 'orders_validate_completed_snapshot_v1'
    and not trigger_row.tgisinternal;
  if v_count <> 1 or v_enabled_count <> 1 then
    raise exception
      'Expected exactly one enabled completed-order validation trigger; found %, enabled and correctly bound %.',
      v_count, v_enabled_count;
  end if;
end;
$preflight$;

create temporary table _stage21_runtime on commit drop as
select id::bigint as admin_profile_id, name as admin_name, location_id
from public.profiles
where id = 1
  and role = 'admin'
  and location_id = '11111111-1111-1111-1111-111111111111'::uuid;

create temporary table _stage21_preservation_baseline on commit drop as
select
  (select count(*) from public.products) as products_count,
  (select count(*) from public.orders) as orders_count,
  (select count(*) from public.order_history) as history_count,
  (select count(*) from public.transaction_history) as movements_count;

insert into public.products (
  id, sku, product_name, category, description, unit,
  product_price, product_quantity, max_quantity,
  created_at, updated_at, location_id, is_active, create_operation_id
)
select
  product_id, sku, product_name, category, description, unit,
  product_price, opening_stock,
  greatest(
    opening_stock * 3,
    opening_stock + baseline_daily * 62,
    opening_stock + 1
  ),
  '2022-11-10T00:00:00+08:00'::timestamptz,
  statement_timestamp(),
  '11111111-1111-1111-1111-111111111111'::uuid,
  true,
  'sim-season-v1:product:' || sku
from _stage21_plan
order by plan_index;

-- The following generator mirrors expanded_seasonal_fixture.py. MD5 streams
-- replace random(), so reruns produce the same daily quantities.
create temporary table _stage21_daily on commit drop as
with calendar as (
  select business_date::date
  from generate_series(
    date '2022-11-10', date '2026-11-09', interval '1 day'
  ) business_date
), expanded as (
  select plan.*, calendar.business_date,
    (calendar.business_date - date '2022-11-10')::double precision / 365.25
      as year_index,
    (1 + cos(2 * pi() *
      (extract(doy from calendar.business_date) - 100) / 365.25)) / 2
      as summer_curve,
    (1 + cos(2 * pi() *
      (extract(doy from calendar.business_date) - 230) / 365.25)) / 2
      as rainy_curve,
    calendar.business_date
      - (extract(isodow from calendar.business_date)::integer - 1)
      as week_start,
    make_date(extract(year from calendar.business_date)::integer, 1, 1)
      as year_start
  from _stage21_plan plan
  cross join calendar
), randoms as (
  select expanded.*,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|gate'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_gate,
    (('x' || substr(md5('26061110|' || sku || '|' || year_start || '|annual_strength'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_annual,
    (('x' || substr(md5('26061110|' || sku || '|' || week_start || '|weekly'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_weekly,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|daily_0'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_daily_0,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|daily_1'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_daily_1,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|daily_2'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_daily_2,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|shock'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_shock,
    (('x' || substr(md5('26061110|' || sku || '|' || business_date || '|shock_size'), 1, 13))::bit(52)::bigint)::double precision / 4503599627370496.0 as u_shock_size
  from expanded
), factors as (
  select randoms.*,
    case seasonal_group when 'RAINY' then rainy_curve else summer_curve end
      as primary_curve,
    case seasonal_group when 'RAINY' then summer_curve else rainy_curve end
      as secondary_curve,
    greatest(.60, 1 + trend_per_year * year_index) as trend_factor,
    .88 + .24 * u_annual as annual_strength,
    case when extract(isodow from business_date) >= 6
      then 1 + weekend_effect else 1 end as weekday_factor,
    (u_weekly - .5) * .30 as weekly_noise
  from randoms
), means as (
  select factors.*,
    baseline_daily * trend_factor
      * greatest(.20,
          1 + annual_strength * primary_amplitude * (2 * primary_curve - 1)
            + secondary_amplitude * (2 * secondary_curve - 1))
      * weekday_factor * (1 + weekly_noise) as mean_demand
  from factors
), candidates as (
  select means.*,
    mean_demand
      + (u_daily_0 + u_daily_1 + u_daily_2 - 1.5)
        * 1.15 * sqrt(greatest(mean_demand, .1))
      + case when u_shock < .018
          then mean_demand * (.25 + .75 * u_shock_size)
          else 0 end as noisy_demand
  from means
), rounded as (
  select candidates.*,
    case
      when baseline_daily = 0 or u_gate > intermittency_probability then 0
      else floor(greatest(noisy_demand, 0) / quantity_step + .5)
        * quantity_step
    end::numeric as quantity
  from candidates
)
select * from rounded where quantity > 0;

create temporary table _stage21_expected_totals (
  sku text primary key,
  expected_quantity numeric not null
) on commit drop;

insert into _stage21_expected_totals values
  ('SIM-SUM-001', 19994), ('SIM-SUM-002', 13940),
  ('SIM-SUM-003', 1927), ('SIM-SUM-004', 1558),
  ('SIM-SUM-005', 9671), ('SIM-SUM-006', 3338),
  ('SIM-SUM-007', 5899), ('SIM-SUM-008', 5404),
  ('SIM-RAIN-001', 4853), ('SIM-RAIN-002', 1302),
  ('SIM-RAIN-003', 1739), ('SIM-RAIN-004', 3498),
  ('SIM-RAIN-005', 2730), ('SIM-RAIN-006', 5146),
  ('SIM-RAIN-007', 140), ('SIM-RAIN-008', 1827),
  ('SIM-NEU-001', 3493), ('SIM-NEU-002', 8378),
  ('SIM-NEU-003', 4287), ('SIM-NEU-004', 651),
  ('SIM-NEU-005', 6432), ('SIM-NEU-006', 5329),
  ('SIM-NEU-007', 1431), ('SIM-NEU-008', 0);

do $generator_check$
declare v_count bigint;
begin
  select count(*) into v_count
  from (
    select plan.sku, coalesce(sum(daily.quantity), 0) as actual_quantity,
      expected.expected_quantity
    from _stage21_plan plan
    join _stage21_expected_totals expected using (sku)
    left join _stage21_daily daily using (sku)
    group by plan.sku, expected.expected_quantity
  ) compared
  where actual_quantity is distinct from expected_quantity;
  if v_count <> 0 then
    raise exception 'SQL generator does not match the frozen offline manifest.';
  end if;
end;
$generator_check$;

create temporary table _stage21_orders on commit drop as
select
  md5('expanded-ph-seasonal-simulation-v1|order|' || business_date)::uuid
    as order_id,
  business_date,
  jsonb_agg(
    jsonb_build_object(
      'product_id', product_id,
      'product_name', product_name,
      'name', product_name,
      'sku', sku,
      'unit', unit,
      'quantity', quantity,
      'unit_price', product_price,
      'price', product_price,
      'line_total', round(quantity * product_price, 2),
      'subtotal', round(quantity * product_price, 2),
      'simulation_batch', 'expanded-ph-seasonal-simulation-v1'
    ) order by plan_index
  ) as items,
  round(sum(quantity * product_price), 2) as total_amount,
  (business_date + time '17:00') at time zone 'Asia/Manila' as created_at,
  (business_date + time '17:20') at time zone 'Asia/Manila' as completed_at
from _stage21_daily
group by business_date;

insert into public.orders (
  id, status, items, location_id, created_by, prepared_by,
  created_at, updated_at, total_amount, discount_amount,
  payment_mode, cash_given, change_amount,
  completed_at, prepared_at,
  created_by_id, created_by_name,
  prepared_by_id, prepared_by_name,
  completed_by_id, completed_by_name,
  checkout_operation_id
)
select
  order_id, 'completed', items,
  runtime.location_id,
  runtime.admin_profile_id, runtime.admin_profile_id,
  created_at, completed_at, total_amount, 0,
  'Cash', total_amount::double precision, 0,
  completed_at, created_at + interval '10 minutes',
  runtime.admin_profile_id::text, runtime.admin_name,
  runtime.admin_profile_id::text, runtime.admin_name,
  runtime.admin_profile_id::text, runtime.admin_name,
  'sim-season-v1:order:' || business_date
from _stage21_orders
cross join _stage21_runtime runtime
order by business_date;

create temporary table _stage21_movements_raw (
  movement_key text primary key,
  product_id uuid not null,
  event_time timestamptz not null,
  event_order integer not null,
  transaction_type text not null,
  quantity_change numeric not null,
  operation_id text not null,
  operation_scope text not null,
  note text not null
) on commit drop;

insert into _stage21_movements_raw
select
  'receipt|' || to_char(date_trunc('month', business_date), 'YYYYMM')
    || '|' || sku,
  product_id,
  (greatest(
      date_trunc('month', business_date)::date,
      date '2022-11-10'
    ) + time '08:00')
    at time zone 'Asia/Manila',
  10,
  'stock_in',
  sum(quantity),
  'sim-season-v1:receipt:'
    || to_char(date_trunc('month', business_date), 'YYYYMM') || ':' || sku,
  'simulation_restock',
  'Synthetic monthly receipt matching the frozen Stage 2.1 sales batch'
from _stage21_daily
group by date_trunc('month', business_date), sku, product_id;

insert into _stage21_movements_raw
select
  'checkout|' || business_date || '|' || sku,
  product_id,
  (business_date + time '17:20') at time zone 'Asia/Manila',
  20,
  'checkout',
  -quantity,
  'sim-season-v1:checkout:' || business_date,
  'checkout',
  'Synthetic checkout matching the completed order snapshot'
from _stage21_daily;

create temporary table _stage21_movements on commit drop as
select raw.*,
  plan.opening_stock + sum(raw.quantity_change) over (
    partition by raw.product_id
    order by raw.event_time, raw.event_order, raw.movement_key
    rows between unbounded preceding and current row
  ) as new_quantity
from _stage21_movements_raw raw
join _stage21_plan plan using (product_id);

insert into public.transaction_history (
  id, created_at, product_id, user_id, user_name,
  transaction_type, quantity_change, new_quantity, location_id,
  note, operation_id, operation_scope
)
select
  md5('expanded-ph-seasonal-simulation-v1|movement|' || movement_key)::uuid,
  event_time, product_id, runtime.admin_profile_id, runtime.admin_name,
  transaction_type, quantity_change, new_quantity,
  runtime.location_id,
  note, operation_id, operation_scope
from _stage21_movements
cross join _stage21_runtime runtime
order by event_time, event_order, movement_key;

do $validate$
declare
  v_count bigint;
  v_expected_movements bigint;
begin
  select count(*) into v_count
  from public.products product
  join _stage21_plan plan on plan.product_id = product.id
  where product.location_id =
    '11111111-1111-1111-1111-111111111111'::uuid
    and product.sku = plan.sku
    and product.is_active;
  if v_count <> 24 then
    raise exception 'Expected 24 imported products; found %.', v_count;
  end if;

  select count(*) into v_count
  from public.orders
  where checkout_operation_id like 'sim-season-v1:%';
  if v_count <> 1461 then
    raise exception 'Expected 1461 tagged daily orders; found %.', v_count;
  end if;

  select count(*) into v_count
  from public.orders orders
  left join public.order_history history on history.order_id = orders.id::text
  where orders.checkout_operation_id like 'sim-season-v1:%'
    and (
      history.order_id is null
      or history.status <> 'completed'
      or history.items is distinct from orders.items
      or history.completed_at is distinct from orders.completed_at
    );
  if v_count <> 0 then
    raise exception 'Tagged orders and durable order history are inconsistent.';
  end if;

  select count(*) into v_count
  from (
    with sales as (
      select product_id, sum(quantity) as sales_quantity
      from _stage21_daily
      group by product_id
    ), checkouts as (
      select product_id, -sum(quantity_change) as checkout_quantity
      from public.transaction_history
      where operation_id like 'sim-season-v1:%'
        and transaction_type = 'checkout'
      group by product_id
    )
    select plan.product_id,
      coalesce(sales.sales_quantity, 0) as sales_quantity,
      coalesce(checkouts.checkout_quantity, 0) as checkout_quantity
    from _stage21_plan plan
    left join sales using (product_id)
    left join checkouts using (product_id)
  ) compared
  where sales_quantity is distinct from checkout_quantity;
  if v_count <> 0 then
    raise exception 'Tagged checkout quantities do not match synthetic sales.';
  end if;

  select count(*) into v_count
  from (
    select distinct on (history.product_id)
      history.product_id, history.new_quantity, product.product_quantity
    from public.transaction_history history
    join public.products product on product.id = history.product_id
    where history.operation_id like 'sim-season-v1:%'
    order by history.product_id, history.created_at desc, history.id desc
  ) latest
  where new_quantity is distinct from product_quantity;
  if v_count <> 0 then
    raise exception 'A tagged movement ledger does not end at catalog stock.';
  end if;

  select count(*) into v_count
  from public.transaction_history
  where operation_id like 'sim-season-v1:%'
    and new_quantity < 0;
  if v_count <> 0 then
    raise exception 'A tagged movement ledger contains a negative balance.';
  end if;

  select count(*) into v_count
  from public.transaction_history history
  join public.products product on product.id = history.product_id
  where history.operation_id like 'sim-season-v1:%'
    and history.new_quantity > product.max_quantity;
  if v_count <> 0 then
    raise exception 'A tagged movement ledger exceeds catalog max quantity.';
  end if;

  select count(*) into v_expected_movements from _stage21_movements;
  select count(*) into v_count
  from _stage21_preservation_baseline baseline
  where (select count(*) from public.products)
          is distinct from baseline.products_count + 24
     or (select count(*) from public.orders)
          is distinct from baseline.orders_count + 1461
     or (select count(*) from public.order_history)
          is distinct from baseline.history_count + 1461
     or (select count(*) from public.transaction_history)
          is distinct from baseline.movements_count + v_expected_movements;
  if v_count <> 0 then
    raise exception 'Pre-existing operational row counts were not preserved.';
  end if;
end;
$validate$;

commit;

-- Post-import read-only verification (only after an approved manual import):
select count(*) as imported_products
from public.products
where create_operation_id like 'sim-season-v1:product:%';

select count(*) as imported_orders,
  min((completed_at at time zone 'Asia/Manila')::date) as first_date,
  max((completed_at at time zone 'Asia/Manila')::date) as last_date
from public.orders
where checkout_operation_id like 'sim-season-v1:%';

-- -------------------------------------------------------------------------
-- TARGETED MANUAL ROLLBACK -- review separately, then uncomment as one block.
-- Existing rows are not targeted. A database backup remains recommended.
-- -------------------------------------------------------------------------
/*
begin;
set local lock_timeout = '10s';
set local statement_timeout = '10min';

create temporary table _stage21_order_ids on commit drop as
select id::text as order_id
from public.orders
where checkout_operation_id like 'sim-season-v1:%';

delete from public.transaction_history
where operation_id like 'sim-season-v1:%';

delete from public.orders
where checkout_operation_id like 'sim-season-v1:%';

-- orders has no DELETE history-sync trigger in the inspected schema.
delete from public.order_history history
using _stage21_order_ids target
where history.order_id = target.order_id;

delete from public.products
where create_operation_id like 'sim-season-v1:product:%'
  and id in (
    select product_id
    from (values
      ('31000000-0000-4000-8000-000000000001'::uuid),
      ('31000000-0000-4000-8000-000000000002'::uuid),
      ('31000000-0000-4000-8000-000000000003'::uuid),
      ('31000000-0000-4000-8000-000000000004'::uuid),
      ('31000000-0000-4000-8000-000000000005'::uuid),
      ('31000000-0000-4000-8000-000000000006'::uuid),
      ('31000000-0000-4000-8000-000000000007'::uuid),
      ('31000000-0000-4000-8000-000000000008'::uuid),
      ('32000000-0000-4000-8000-000000000001'::uuid),
      ('32000000-0000-4000-8000-000000000002'::uuid),
      ('32000000-0000-4000-8000-000000000003'::uuid),
      ('32000000-0000-4000-8000-000000000004'::uuid),
      ('32000000-0000-4000-8000-000000000005'::uuid),
      ('32000000-0000-4000-8000-000000000006'::uuid),
      ('32000000-0000-4000-8000-000000000007'::uuid),
      ('32000000-0000-4000-8000-000000000008'::uuid),
      ('33000000-0000-4000-8000-000000000001'::uuid),
      ('33000000-0000-4000-8000-000000000002'::uuid),
      ('33000000-0000-4000-8000-000000000003'::uuid),
      ('33000000-0000-4000-8000-000000000004'::uuid),
      ('33000000-0000-4000-8000-000000000005'::uuid),
      ('33000000-0000-4000-8000-000000000006'::uuid),
      ('33000000-0000-4000-8000-000000000007'::uuid),
      ('33000000-0000-4000-8000-000000000008'::uuid)
    ) ids(product_id)
  );

do $rollback_validate$
begin
  if exists (
    select 1 from public.products
    where create_operation_id like 'sim-season-v1:product:%'
  ) or exists (
    select 1 from public.orders
    where checkout_operation_id like 'sim-season-v1:%'
  ) or exists (
    select 1 from public.order_history history
    join _stage21_order_ids target using (order_id)
  ) or exists (
    select 1 from public.transaction_history
    where operation_id like 'sim-season-v1:%'
  ) then
    raise exception 'Stage 2.4 rollback validation failed.';
  end if;
end;
$rollback_validate$;

commit;
*/
