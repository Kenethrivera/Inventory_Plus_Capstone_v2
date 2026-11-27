import json
import re
from collections import defaultdict
from pathlib import Path

root = Path(__file__).resolve().parents[2]
folder = Path(__file__).parent
lines = json.loads((folder / 'source_lines.json').read_text(encoding='utf-8'))
categories = json.loads((folder / 'category_map.json').read_text(encoding='utf-8'))
groups = defaultdict(list)
for line in lines:
    if line['name'].strip():
        key = (re.sub(r'\s+', ' ', line['name'].strip()).casefold(),
               re.sub(r'\s+', ' ', line['unit'].strip()).casefold())
        groups[key].append(line)

catalog = []
for group in groups.values():
    preferred = next((x for x in group if x['source'] == 'Sales'), None) or next((x for x in group if x['source'] == 'Receipts'), None) or group[0]
    sold = sorted((x for x in group if x['source'] in ('Sales', 'Receipts') and x['qty'] > 0),
                  key=lambda x: (x['date'], x['source'], x['row']))
    latest = sold[-1] if sold else None
    product_name = preferred['name'].strip()
    category = categories[product_name.casefold()]['category']
    catalog.append(dict(name=product_name, unit=preferred['unit'].strip() or 'unspecified',
                        source_unit=preferred['unit'].strip(), category=category,
                        reference_price=round(latest['amount'] / latest['qty'], 2) if latest else 0,
                        price_basis='Historical sale or receipt' if latest else 'Price pending',
                        requires_loading=preferred['unit'].strip().casefold() == 'tin'))

catalog.sort(key=lambda x: (x['name'].casefold(), x['unit'].casefold()))
payload = json.dumps(catalog, ensure_ascii=False, separators=(',', ':'))
sql = r'''-- Product catalog import for one Supabase store.
-- Run as ONE script in Supabase SQL Editor. Re-running does not reset stock.
-- Source: the three workbooks consolidated in Inventory_Plus_Product_Catalog.xlsx.
-- Creates 295 named product+unit entries where no exact live name+unit exists.
-- Existing and new products with unit TIN are flagged for Bodegero loading.
-- Current on-hand quantities are unknown, so new products start at zero.
-- Latest historical sale/receipt price is a reference; materials-only price is 0.
-- Existing exact name+unit products are preserved. Review reference prices,
-- 32 uncertain categories, and missing source units before live transactions.
begin;

create temp table _ci_config on commit drop as
select id as location_id from public.locations
where id = coalesce(null::uuid, -- Set location UUID if there is more than one store.
  case when (select count(*) from public.locations) = 1 then id end);

do $check$
begin
  if (select count(*) from _ci_config) <> 1 then
    raise exception 'Select exactly one store in _ci_config';
  end if;
  if exists (select 1 from public.transaction_history t join _ci_config c
      on c.location_id=t.location_id
      where t.operation_id like '%-stock-v1:%') then
    raise exception 'Earlier synthetic opening balances exist; reconcile them before importing';
  end if;
end $check$;

create temp table _ci_source on commit drop as
select x.name, x.unit, x.source_unit, x.category, x.reference_price,
       x.price_basis, x.requires_loading
from jsonb_to_recordset($ci_source$SOURCE_JSON$ci_source$::jsonb) as x(
  name text, unit text, source_unit text, category text, reference_price numeric,
  price_basis text, requires_loading boolean);

do $check$
begin
  if (select count(*) from _ci_source) <> 295 or
     (select count(distinct (lower(trim(name)), lower(trim(source_unit)))) from _ci_source) <> 295 or
     exists (select 1 from _ci_source where nullif(trim(name),'') is null or
       nullif(trim(unit),'') is null or nullif(trim(category),'') is null or
       reference_price < 0 or requires_loading is null) then
    raise exception 'Catalog source is incomplete or changed';
  end if;
end $check$;

create temp table _ci_prepared on commit drop as
with keyed as (
  select s.*, c.location_id,
    'client-records-v1:' || c.location_id::text || ':product:' ||
      md5(lower(trim(s.name)) || '|' || lower(trim(s.source_unit)) || '|' ||
          lower(trim(s.category)) || '|' || s.requires_loading::text) as product_key
  from _ci_source s cross join _ci_config c
)
select keyed.* from keyed;

-- A product created by the history import may already exist at zero stock.
-- Activate it once; never overwrite active products on a later run.
update public.products p set
  is_active = true,
  product_price = c.reference_price,
  category = c.category,
  unit = c.unit,
  description = 'Imported from historical records. Current stock is uncounted; price is based on ' ||
    lower(c.price_basis) || '. Verify before live sales.' ||
    case when c.source_unit = '' then ' Unit missing in source.' else '' end,
  requires_loading = c.requires_loading
from _ci_prepared c
where p.location_id = c.location_id and p.create_operation_id = c.product_key
  and p.is_active = false and p.product_quantity = 0;

insert into public.products
  (sku, product_name, category, unit, product_price, product_quantity,
   max_quantity, description, location_id, is_active, create_operation_id,
   requires_loading)
select 'SKU-' || substr(md5(c.product_key),1,24), c.name,
       c.category, c.unit, c.reference_price, 0,
       100,
       'Imported from historical records. Current stock is uncounted; price is based on ' ||
         lower(c.price_basis) || '. Verify before live sales.' ||
         case when c.source_unit = '' then ' Unit missing in source.' else '' end,
       c.location_id, true, c.product_key, c.requires_loading
from _ci_prepared c
where not exists (select 1 from public.products p
  where p.location_id = c.location_id and p.is_active and
    lower(trim(p.product_name)) = lower(trim(c.name)) and
    lower(coalesce(nullif(trim(p.unit),''),'unspecified')) = lower(trim(c.unit)))
on conflict do nothing;

-- Correct the handling flag on existing products too. Order insertion reads
-- this flag to classify each line before selecting an online Bodegero.
update public.products p set
  requires_loading = true,
  updated_at = now()
from _ci_config c
where p.location_id = c.location_id
  and lower(trim(coalesce(p.unit,''))) = 'tin'
  and p.requires_loading = false;

do $check$
declare active_count integer;
begin
  if exists (select 1 from _ci_prepared c where not exists (
    select 1 from public.products p where p.location_id = c.location_id
      and p.is_active and lower(trim(p.product_name)) = lower(trim(c.name))
      and lower(coalesce(nullif(trim(p.unit),''),'unspecified')) = lower(trim(c.unit)))) then
    raise exception 'Some catalog products were not inserted or matched';
  end if;
  if exists (select 1 from public.products p join _ci_config c
      on c.location_id = p.location_id
      where lower(trim(coalesce(p.unit,''))) = 'tin'
        and p.requires_loading is distinct from true) then
    raise exception 'A TIN product is not flagged for loading';
  end if;
  select count(*) into active_count from public.products p
  join _ci_config c on c.location_id = p.location_id
  where p.create_operation_id like 'client-records-v1:%:product:%'
    and p.is_active;
  raise notice 'Catalog import complete. % active products with import keys; existing exact matches preserved.', active_count;
end $check$;
commit;
'''
destination = root / 'database' / 'import_product_catalog.sql'
destination.write_text(sql.replace('SOURCE_JSON', payload), encoding='utf-8')
print(destination, 'products', len(catalog), 'reference_prices', sum(x['reference_price'] > 0 for x in catalog), 'pending_prices', sum(x['reference_price'] == 0 for x in catalog))
