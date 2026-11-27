import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
lines = json.loads((Path(__file__).with_name('source_lines.json')).read_text(encoding='utf-8'))
category_map = json.loads((Path(__file__).with_name('category_map.json')).read_text(encoding='utf-8'))
source = [dict(source=x['source'], sheet=x['sheet'], row_number=x['row'],
               group_number=str(x['group']), date_text=x['date'],
               name=x['name'], unit=x['unit'], qty=x['qty'],
               unit_price=x['unit_price'], amount=x['amount'],
               category=category_map.get(x['name'].strip().casefold(), {}).get('category', 'Needs category review'),
               notes=x['notes'], variance=x['variance'])
          for x in lines]
payload = json.dumps(source, ensure_ascii=False, separators=(',', ':'))
sql = r'''-- Capstone historical transaction import. Run as ONE statement in Supabase SQL Editor.
-- Creates demo-history products, completed sales orders, and stock movement history.
-- Existing product_quantity balances are not changed. Re-running is idempotent.
-- STAFF ATTRIBUTION IS SIMULATED: Abdul/Allen are chosen per eligible order;
-- Yves is assigned to orders containing a TIN; Keneth is the cashier.
-- No historical picking/loading proof or staff timing is fabricated.
-- Receipts: 47 customer-sale groups (Nov 2-9 per filename; source date cells conflict).
-- Materials: 66 groups. Set materials_mode below to 'stock_in' for stock
-- purchases or 'sale' for customer sales. Six source amount variances remain
-- in item metadata. Receipt lines with missing names use explicit placeholders.
begin;

create temp table _cap_config on commit drop as
select id as location_id, 'CONFIRM_MATERIALS_MODE'::text as materials_mode
from public.locations
where id = coalesce(null::uuid, -- Set a location UUID here if more than one store exists.
  case when (select count(*) from public.locations) = 1 then id end);

do $check$
begin
  if (select count(*) from _cap_config) <> 1 then
    raise exception 'Select exactly one store in _cap_config';
  end if;
  if (select materials_mode from _cap_config) not in ('stock_in','sale') then
    raise exception 'materials_mode must be stock_in or sale';
  end if;
  if exists (select 1 from public.orders o join _cap_config c
      on c.location_id = o.location_id
      where o.checkout_operation_id like 'sales-categorized-fixed:%') then
    raise exception 'The older sales-only import is already present; stop to avoid duplicate November 18-23 orders';
  end if;
  if to_regclass('public.order_history') is null or
     to_regclass('public.bodegero_loading_clocks') is null then
    raise exception 'Required order history/loading migrations are missing';
  end if;
  if (select count(*) from pg_trigger where tgrelid = 'public.orders'::regclass
      and tgname in ('orders_assign_loading_v1','orders_sync_order_history_v1',
                     'orders_zz_bodegero_clock_v1') and not tgisinternal) <> 3 then
    raise exception 'Required order triggers are missing';
  end if;
end $check$;

create temp table _cap_staff on commit drop as
select p.id, p.name, lower(p.role) as role, lower(trim(p.name)) as name_key
from public.profiles p join _cap_config c on c.location_id = p.location_id
where p.is_active and lower(trim(p.name)) in ('abdul','allen','yves','keneth');

do $check$
begin
  if (select count(*) from _cap_staff where name_key = 'abdul' and role = 'helper') <> 1 or
     (select count(*) from _cap_staff where name_key = 'allen' and role = 'helper') <> 1 or
     (select count(*) from _cap_staff where name_key = 'yves' and role = 'bodegero') <> 1 or
     (select count(*) from _cap_staff where name_key = 'keneth' and role in ('staff','cashier')) <> 1 then
    raise exception 'Create exactly one active Abdul/Allen helper, Yves bodegero, and Keneth cashier/staff at the selected store';
  end if;
end $check$;

create temp table _cap_source on commit drop as
select x.source, x.sheet, x.row_number, x.group_number, x.date_text,
       x.name, x.unit, x.qty, x.unit_price, x.amount, x.category,
       x.notes, x.variance
from jsonb_to_recordset($cap_source$SOURCE_JSON$cap_source$::jsonb) as x(
  source text, sheet text, row_number integer, group_number text,
  date_text text, name text, unit text, qty numeric, unit_price numeric,
  amount numeric, category text, notes text, variance numeric);

do $check$
begin
  if (select count(*) from _cap_source) <> 427 or
     (select count(*) from _cap_source where source = 'Sales') <> 153 or
     (select count(*) from _cap_source where source = 'Receipts') <> 126 or
     (select count(*) from _cap_source where source = 'Materials') <> 148 or
     (select count(distinct sheet || ':' || group_number) from _cap_source where source = 'Sales') <> 45 or
     (select count(distinct group_number) from _cap_source where source = 'Receipts') <> 47 or
     (select count(distinct sheet || ':' || group_number) from _cap_source where source = 'Materials') <> 66 or
     (select sum(amount) from _cap_source where source = 'Sales') <> 96420 or
     (select sum(amount) from _cap_source where source = 'Receipts') <> 75270 or
     (select sum(amount) from _cap_source where source = 'Materials') <> 83420 or
     exists (select 1 from _cap_source where qty <= 0 or amount < 0 or date_text is null) then
    raise exception 'Source counts, dates or totals differ from reviewed workbooks';
  end if;
end $check$;

create temp table _cap_lines on commit drop as
with base as (
  select s.*,
         c.location_id,
         case when s.source = 'Materials' then c.materials_mode else 'sale' end as direction,
         coalesce(nullif(trim(s.name),''),
           'Unidentified item (' || s.source || ' ' || s.sheet || ' row ' || s.row_number || ')') as product_name,
         coalesce(nullif(trim(s.category),''),'Historical Import') as product_category,
         lower(trim(coalesce(s.unit,''))) = 'tin' as requires_loading,
         ('capstone-history-v1:' || c.location_id::text || ':' ||
           md5(s.source || '|' || s.sheet || '|' || s.group_number)) as operation_id,
         ((s.date_text::date + time '12:00') at time zone 'Asia/Manila') as event_at
  from _cap_source s cross join _cap_config c
)
select base.*,
  'capstone-history-v1:' || location_id::text || ':product:' ||
    md5(lower(product_name) || '|' || lower(coalesce(unit,'')) || '|' ||
        lower(product_category) || '|' || requires_loading::text) as product_key
from base;

insert into public.products
  (sku, product_name, category, unit, product_price, product_quantity,
   location_id, is_active, create_operation_id, description, requires_loading)
select distinct on (product_key)
  'HIST-CAP-' || substr(md5(product_key),1,24), product_name,
  product_category, coalesce(unit,''), 0, 0, location_id, false,
  product_key, 'Imported capstone history; source preserved in order items/movement notes',
  requires_loading
from _cap_lines
order by product_key, product_name
on conflict (sku) do nothing;

create temp table _cap_mapped on commit drop as
select l.*, p.id as product_id
from _cap_lines l
join public.products p on p.location_id = l.location_id
  and p.create_operation_id = l.product_key;

do $check$
begin
  if (select count(*) from _cap_mapped) <> 427 then
    raise exception 'Not every historical line mapped to a product';
  end if;
end $check$;

with sale_orders as (
  select m.location_id, m.operation_id, min(m.event_at) as sale_at,
    sum(m.amount) as total_amount,
    bool_or(not m.requires_loading) as has_helper_items,
    bool_or(m.requires_loading) as has_loading_items,
    jsonb_agg(jsonb_build_object(
      'product_id', m.product_id, 'product_name', m.product_name,
      'quantity', m.qty, 'unit', m.unit,
      'unit_price', round(m.amount / m.qty, 2), 'line_total', m.amount,
      'source_file', m.source, 'source_sheet', m.sheet,
      'source_group', m.group_number, 'source_row', m.row_number,
      'source_unit_price', m.unit_price, 'source_variance', m.variance,
      'source_note', m.notes, 'historical_staff_assignment', 'simulated'
    ) order by m.row_number) as items
  from _cap_mapped m where m.direction = 'sale'
  group by m.location_id, m.operation_id
), assigned as (
  select o.*, h.id as helper_id, h.name as helper_name,
    b.id as bodegero_id, b.name as bodegero_name,
    k.id as cashier_id, k.name as cashier_name
  from sale_orders o
  left join lateral (
    select p.id,p.name from _cap_staff p where p.role='helper'
    order by md5(o.operation_id || ':' || p.id::text) limit 1
  ) h on o.has_helper_items
  left join lateral (
    select p.id,p.name from _cap_staff p where p.name_key='yves' and p.role='bodegero'
    limit 1
  ) b on o.has_loading_items
  cross join lateral (
    select p.id,p.name from _cap_staff p where p.name_key='keneth'
      and p.role in ('staff','cashier') limit 1
  ) k
)
insert into public.orders
  (status, items, location_id, created_at, updated_at, completed_at,
   assigned_at, prepared_at, total_amount, discount_amount, payment_mode,
   cash_given, change_amount, created_by_id, created_by_name,
   assigned_helper_id, assigned_helper_name, prepared_by_id, prepared_by_name,
   assigned_bodegero_id, assigned_bodegero_name,
   completed_by_id, completed_by_name, checkout_operation_id)
select 'completed', a.items, a.location_id, a.sale_at, a.sale_at, a.sale_at,
       case when a.has_helper_items then a.sale_at end,
       case when a.has_helper_items then a.sale_at end,
       a.total_amount, 0, 'Unspecified', null, null,
       a.cashier_id::text, a.cashier_name,
       case when a.has_helper_items then a.helper_id::text end,
       case when a.has_helper_items then a.helper_name end,
       case when a.has_helper_items then a.helper_id::text end,
       case when a.has_helper_items then a.helper_name end,
       case when a.has_loading_items then a.bodegero_id::text end,
       case when a.has_loading_items then a.bodegero_name end,
       a.cashier_id::text, a.cashier_name, a.operation_id
from assigned a
on conflict (checkout_operation_id) where checkout_operation_id is not null do nothing;

-- The regular Bodegero trigger creates a clock at import time. Remove that
-- synthetic clock so historical demo orders do not appear as current overdue
-- loading work or receive invented timing scores. Keep the assignment name.
delete from public.bodegero_loading_clocks c
using public.orders o, _cap_mapped m
where c.order_id = o.id and o.checkout_operation_id = m.operation_id
  and m.direction = 'sale';
update public.order_history h set
  bodegero_assigned_at = null, loading_started_at = null,
  loading_verified_at = null, loading_paused_seconds = null
from public.orders o, _cap_mapped m
where h.order_id = o.id::text and o.checkout_operation_id = m.operation_id
  and m.direction = 'sale';

-- Historical movements only. Current product_quantity is not changed.
insert into public.transaction_history
  (created_at, product_id, transaction_type, quantity_change, new_quantity,
   location_id, note, operation_id, operation_scope)
select min(m.event_at), m.product_id, 'checkout', -sum(m.qty), null,
       m.location_id, 'Simulated staff attribution; historical sale from ' ||
       min(m.source) || '; current stock unchanged',
       m.operation_id, 'capstone_historical_sale'
from _cap_mapped m where m.direction = 'sale'
group by m.location_id, m.operation_id, m.product_id
on conflict (location_id, operation_id, product_id, transaction_type)
  where operation_id is not null do nothing;

insert into public.transaction_history
  (created_at, product_id, transaction_type, quantity_change, new_quantity,
   location_id, note, operation_id, operation_scope)
select m.event_at, m.product_id, 'stock_in', m.qty, null, m.location_id,
       'Historical materials purchase, ' || m.sheet || ' group ' ||
       m.group_number || ' row ' || m.row_number ||
       '; written amount PHP ' || m.amount ||
       '; current stock unchanged',
       m.operation_id || ':row:' || m.row_number, 'capstone_historical_purchase'
from _cap_mapped m where m.direction = 'stock_in'
on conflict (location_id, operation_id, product_id, transaction_type)
  where operation_id is not null do nothing;

do $check$
declare expected_sales integer;
begin
  expected_sales := case when (select materials_mode from _cap_config)='sale' then 158 else 92 end;
  if (select count(*) from public.orders o join _cap_config c on c.location_id=o.location_id
      where o.checkout_operation_id like 'capstone-history-v1:%') < expected_sales then
    raise exception 'Historical order count incomplete';
  end if;
  raise notice 'Imported % historical sale groups and 427 source lines; staff attribution simulated; current stock unchanged', expected_sales;
end $check$;
commit;
'''
sql = sql.replace('SOURCE_JSON', payload)
destination = root / 'database' / 'import_capstone_history.sql'
destination.write_text(sql, encoding='utf-8')
print(destination, len(sql), 'characters')
