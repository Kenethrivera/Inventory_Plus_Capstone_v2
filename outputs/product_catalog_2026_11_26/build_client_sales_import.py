import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
folder = Path(__file__).parent
lines = json.loads((folder / 'source_lines.json').read_text(encoding='utf-8'))
categories = json.loads((folder / 'category_map.json').read_text(encoding='utf-8'))
source = [dict(source=x['source'], sheet=x['sheet'], row_number=x['row'],
               group_number=str(x['group']), date_text=x['date'],
               name=x['name'], unit=x['unit'], qty=x['qty'], amount=x['amount'],
               source_unit_price=x['unit_price'],
               category=categories.get(x['name'].strip().casefold(), {}).get('category', 'Needs category review'),
               notes=x['notes'], variance=x['variance'])
          for x in lines if x['source'] in ('Sales', 'Receipts', 'Materials')]
payload = json.dumps(source, ensure_ascii=False, separators=(',', ':'))
sql = r'''-- Backfill customer sales from the three supplied workbooks.
-- Run after import_product_catalog.sql as one SQL Editor query.
-- Re-runs use stable operation IDs.
-- 158 completed orders, 427 item lines, PHP 255,110 of source line amounts.
-- Staff and payment details are unknown in the source and remain unassigned.
-- Source dates have no times; noon Asia/Manila is a placeholder time.
-- The user confirmed Oct 13-18 materials are customer sales and that the
-- conflicting receipt date cells should be interpreted as Nov 2-9, 2026.
-- Seven lines have arithmetic discrepancies; source amounts are kept.
-- Current product_quantity balances are not adjusted.
begin;

create temp table _ch_config on commit drop as
select id as location_id
from public.locations
where id = coalesce(null::uuid, -- Set store UUID here if multiple stores exist.
  case when (select count(*) from public.locations) = 1 then id end);

do $check$
begin
  if (select count(*) from _ch_config) <> 1 then
    raise exception 'Select exactly one store in _ch_config';
  end if;
  if exists (select 1 from public.transaction_history t join _ch_config c
      on c.location_id=t.location_id
      where t.operation_id like '%-stock-v1:%') then
    raise exception 'Earlier synthetic opening balances exist; reconcile them before importing';
  end if;
  if exists (select 1 from public.orders o join _ch_config c on c.location_id=o.location_id
    where (o.checkout_operation_id like 'sales-categorized-fixed:%'
       or (o.checkout_operation_id like '%history-v1:%'
           and o.checkout_operation_id not like 'client-sales-history-v1:%'))) then
    raise exception 'A previous historical sales import exists; stop to avoid duplicates';
  end if;
  if to_regclass('public.order_history') is null or
     to_regclass('public.bodegero_loading_clocks') is null then
    raise exception 'Order history/loading migrations are missing';
  end if;
end $check$;

create temp table _ch_source on commit drop as
select x.* from jsonb_to_recordset($ch_source$SOURCE_JSON$ch_source$::jsonb) as x(
  source text, sheet text, row_number integer, group_number text,
  date_text text, name text, unit text, qty numeric, amount numeric,
  source_unit_price numeric,
  category text, notes text, variance numeric);

do $check$
begin
  if (select count(*) from _ch_source) <> 427 or
     (select count(*) from _ch_source where source='Sales') <> 153 or
     (select count(*) from _ch_source where source='Receipts') <> 126 or
     (select count(*) from _ch_source where source='Materials') <> 148 or
     (select count(distinct sheet || ':' || group_number) from _ch_source where source='Sales') <> 45 or
     (select count(distinct sheet || ':' || group_number) from _ch_source where source='Receipts') <> 47 or
     (select count(distinct sheet || ':' || group_number) from _ch_source where source='Materials') <> 66 or
     (select sum(amount) from _ch_source) <> 255110 or
     exists (select 1 from _ch_source where qty <= 0 or amount < 0 or date_text is null) then
    raise exception 'Sales source count, dates or totals changed';
  end if;
end $check$;

create temp table _ch_lines on commit drop as
with base as (
  select s.*, c.location_id,
    coalesce(nullif(trim(s.name),''),
      'Unidentified item (' || s.source || ' ' || s.sheet || ' row ' || s.row_number || ')') as product_name,
    coalesce(nullif(trim(s.category),''),'Needs category review') as product_category,
    'client-sales-history-v1:' || c.location_id::text || ':' ||
      md5(s.source || '|' || s.sheet || '|' || s.group_number) as operation_id,
    ((s.date_text::date + time '12:00') at time zone 'Asia/Manila') as sale_at
  from _ch_source s cross join _ch_config c
)
select base.*,
  'client-records-v1:' || location_id::text || ':product:' ||
    md5(lower(product_name) || '|' || lower(coalesce(unit,'')) || '|' ||
        lower(product_category) || '|' || (lower(trim(coalesce(unit,'')))='tin')::text) as product_key
from base;

insert into public.products
  (sku,product_name,category,unit,product_price,product_quantity,
   location_id,is_active,create_operation_id,description,requires_loading)
select distinct on (product_key)
  'SKU-' || substr(md5(product_key),1,24), product_name,
  product_category, coalesce(nullif(trim(unit),''),'unspecified'),0,0,
  location_id,false,product_key,
  'Historical receipt item; current stock and selling price not established',
  lower(trim(coalesce(unit,'')))='tin'
from _ch_lines
where not exists (
  select 1 from public.products p
  where p.location_id=_ch_lines.location_id
    and lower(trim(p.product_name))=lower(trim(_ch_lines.product_name))
    and lower(coalesce(nullif(trim(p.unit),''),'unspecified'))=
      lower(coalesce(nullif(trim(_ch_lines.unit),''),'unspecified'))
)
order by product_key,product_name
on conflict do nothing;

create temp table _ch_mapped (
  source text, sheet text, row_number integer, group_number text,
  date_text text, name text, unit text, qty numeric, amount numeric,
  source_unit_price numeric, category text, notes text, variance numeric,
  location_id uuid, product_name text, product_category text,
  operation_id text, sale_at timestamptz, product_key text,
  product_id uuid, product_requires_loading boolean
) on commit drop;
insert into _ch_mapped
select l.*,p.id as product_id,p.requires_loading as product_requires_loading
from _ch_lines l
join lateral (
  select p.id,p.requires_loading from public.products p
  where p.location_id=l.location_id
    and (p.create_operation_id=l.product_key or (
      lower(trim(p.product_name))=lower(trim(l.product_name))
      and lower(coalesce(nullif(trim(p.unit),''),'unspecified'))=
        lower(coalesce(nullif(trim(l.unit),''),'unspecified'))))
  order by (p.create_operation_id=l.product_key) desc, p.is_active desc, p.id
  limit 1
) p on true;

do $check$
begin
  if (select count(*) from _ch_mapped) <> 427 then
    raise exception 'One or more sale lines did not map to a product';
  end if;
end $check$;

with grouped as (
  select m.location_id,m.operation_id,min(m.sale_at) as sale_at,
    sum(m.amount) as total_amount,
    jsonb_agg(jsonb_build_object(
      'product_id',m.product_id,'product_name',m.product_name,
      'quantity',m.qty,'unit',m.unit,
      'requires_loading',m.product_requires_loading,
      'unit_price',round(m.amount/m.qty,2),'line_total',m.amount,
      'source_file',case m.source
        when 'Sales' then 'Sales  (1).xlsx'
        when 'Materials' then 'Paint_and_Hardware_Materials_Transcription-v2.xlsx'
        else 'Receipt_List_Nov2-Nov9.xlsx' end,
      'source_date_only',true,
      'date_basis',case m.source when 'Receipts' then 'filename' else 'workbook' end,
      'source_sheet',m.sheet,
      'source_group',m.group_number,'source_row',m.row_number,
      'source_note',m.notes,'source_variance',m.variance,
      'written_unit_price',m.source_unit_price
    ) order by m.row_number) as items
  from _ch_mapped m
  group by m.location_id,m.operation_id
)
insert into public.orders
  (status,items,location_id,created_at,updated_at,completed_at,
   total_amount,discount_amount,payment_mode,cash_given,change_amount,
   checkout_operation_id)
select 'completed',items,location_id,sale_at,sale_at,sale_at,
  total_amount,0,'Unspecified',null,null,operation_id
from grouped
on conflict (checkout_operation_id) where checkout_operation_id is not null do nothing;

-- A current loading trigger may auto-assign an online Bodegero on insertion.
-- Clear such an assignment because the old receipts name no worker.
update public.orders o set assigned_bodegero_id=null,
  assigned_bodegero_name=null
where o.checkout_operation_id in (select distinct operation_id from _ch_mapped)
  and o.assigned_bodegero_id is not null;
delete from public.bodegero_loading_clocks c
using public.orders o
where c.order_id=o.id
  and o.checkout_operation_id in (select distinct operation_id from _ch_mapped);

insert into public.transaction_history
  (created_at,product_id,transaction_type,quantity_change,new_quantity,
   location_id,note,operation_id,operation_scope)
select min(m.sale_at),m.product_id,'checkout',-sum(m.qty),null,
  m.location_id,'Backfilled sale from client receipts; current stock unchanged',
  m.operation_id,'client_historical_sale'
from _ch_mapped m
group by m.location_id,m.operation_id,m.product_id
on conflict (location_id,operation_id,product_id,transaction_type)
  where operation_id is not null do nothing;

do $check$
begin
  if (select count(*) from public.orders o join _ch_config c on c.location_id=o.location_id
      where o.checkout_operation_id like 'client-sales-history-v1:%') <> 158 then
    raise exception 'Expected 158 imported historical orders';
  end if;
  raise notice 'Imported 158 historical orders and 427 sale lines; current stock unchanged';
end $check$;
commit;
'''
destination = root / 'database' / 'import_historical_sales.sql'
destination.write_text(sql.replace('SOURCE_JSON', payload), encoding='utf-8')
print(destination, len(source), 'source lines')
