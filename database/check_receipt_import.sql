-- Read-only check before reverting the historical receipt import.
-- Shows the affected store, orders, amount, products and stock-log entries.
with tagged_orders as (
  select location_id, count(*) as order_count,
         coalesce(sum(total_amount), 0) as order_total
  from public.orders
  where checkout_operation_id like 'client-sales-history-v1:%'
     or checkout_operation_id like 'capstone-history-v1:%'
  group by location_id
), tagged_products as (
  select location_id, count(*) as product_count
  from public.products
  where create_operation_id like 'client-records-v1:%:product:%'
     or create_operation_id like 'capstone-history-v1:%:product:%'
  group by location_id
), tagged_movements as (
  select location_id, count(*) as movement_count
  from public.transaction_history
  where operation_scope in ('client_historical_sale', 'capstone_demo_stock')
  group by location_id
)
select l.id as location_id,
       coalesce(o.order_count, 0) as imported_orders,
       coalesce(o.order_total, 0) as imported_sales_amount,
       coalesce(p.product_count, 0) as imported_products,
       coalesce(m.movement_count, 0) as imported_stock_logs
from public.locations l
left join tagged_orders o on o.location_id = l.id
left join tagged_products p on p.location_id = l.id
left join tagged_movements m on m.location_id = l.id
where o.order_count is not null
   or p.product_count is not null
   or m.movement_count is not null
order by l.id;
