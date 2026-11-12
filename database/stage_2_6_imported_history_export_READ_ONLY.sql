-- Inventory Plus Stage 2.6 imported-history export.
-- READ ONLY: this script performs no database or schema changes.
--
-- Run in Supabase SQL Editor and export the FIRST result grid as CSV. It has
-- the same dense product/date shape as expanded_seasonal_daily_demand.csv,
-- including explicit zero-demand days. The SECOND result grid keeps the
-- original active products separate for preservation reporting.

begin transaction read only;

with imported_products as (
  select
    product.id as product_id,
    product.sku,
    product.product_name,
    product.category,
    product.unit,
    case
      when product.sku like 'SIM-SUM-%' then 'SUMMER'
      when product.sku like 'SIM-RAIN-%' then 'RAINY'
      when product.sku like 'SIM-NEU-%' then 'NEUTRAL'
      else 'UNKNOWN'
    end as seasonal_group
  from public.products product
  where product.create_operation_id like 'sim-season-v1:product:%'
),
calendar as (
  select business_date::date
  from generate_series(
    date '2022-11-10',
    date '2026-11-09',
    interval '1 day'
  ) business_date
),
sales as (
  select
    (history.completed_at at time zone 'Asia/Manila')::date as business_date,
    coalesce(item.value ->> 'product_id', item.value ->> 'productId')::uuid
      as product_id,
    sum((item.value ->> 'quantity')::numeric) as quantity
  from public.order_history history
  cross join lateral jsonb_array_elements(
    case
      when jsonb_typeof(history.items) = 'array' then history.items
      else '[]'::jsonb
    end
  ) item
  where lower(trim(history.status)) = 'completed'
    and history.completed_at is not null
    and history.returned_at is null
    and item.value ->> 'simulation_batch' =
      'expanded-ph-seasonal-simulation-v1'
  group by
    (history.completed_at at time zone 'Asia/Manila')::date,
    coalesce(item.value ->> 'product_id', item.value ->> 'productId')::uuid
)
select
  calendar.business_date,
  product.product_id,
  product.sku,
  product.product_name,
  product.category,
  product.unit,
  product.seasonal_group,
  coalesce(sales.quantity, 0) as quantity
from imported_products product
cross join calendar
left join sales
  on sales.product_id = product.product_id
 and sales.business_date = calendar.business_date
order by calendar.business_date, product.product_id;

with imported_ids as (
  select product.id
  from public.products product
  where product.create_operation_id like 'sim-season-v1:product:%'
),
original_active_products as (
  select product.id, product.sku, product.product_name, product.unit
  from public.products product
  where product.is_active
    and not exists (
      select 1 from imported_ids imported where imported.id = product.id
    )
),
completed_sales as (
  select
    coalesce(item.value ->> 'product_id', item.value ->> 'productId')::uuid
      as product_id,
    (history.completed_at at time zone 'Asia/Manila')::date as business_date,
    (item.value ->> 'quantity')::numeric as quantity
  from public.order_history history
  cross join lateral jsonb_array_elements(
    case
      when jsonb_typeof(history.items) = 'array' then history.items
      else '[]'::jsonb
    end
  ) item
  where lower(trim(history.status)) = 'completed'
    and history.completed_at is not null
    and history.returned_at is null
)
select
  product.id as product_id,
  product.sku,
  product.product_name,
  product.unit,
  min(sales.business_date) as first_sales_date,
  max(sales.business_date) as last_sales_date,
  count(distinct sales.business_date) as selling_days,
  coalesce(sum(sales.quantity), 0) as completed_sales_quantity
from original_active_products product
left join completed_sales sales on sales.product_id = product.id
group by product.id, product.sku, product.product_name, product.unit
order by lower(product.product_name), product.id;

commit;
