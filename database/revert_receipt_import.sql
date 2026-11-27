-- Removes one successful 158-order, PHP 255,110 historical receipt import.
-- Run the read-only check_receipt_import.sql first. This script does not
-- remove unrelated orders, existing products, or profiles. It is atomic:
-- any failed safety check rolls back the entire change.
-- It does not reset the loading flag of pre-existing TIN products, because
-- their prior values were not recorded by the import.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '2min';

create temp table _undo_location (location_id uuid primary key) on commit drop;
insert into _undo_location
select id from public.locations
where id = coalesce(null::uuid, -- Set store UUID here if multiple stores exist.
  case when (select count(*) from public.locations) = 1 then id end);

do $check$
begin
  if (select count(*) from _undo_location) <> 1 then
    raise exception 'Choose exactly one store before reverting';
  end if;
end $check$;

create temp table _undo_orders (
  id uuid primary key, token text not null, total_amount numeric not null,
  status text not null, completed_at timestamptz, updated_at timestamptz
) on commit drop;
insert into _undo_orders
select o.id, o.checkout_operation_id, o.total_amount, o.status,
       o.completed_at, o.updated_at
from public.orders o join _undo_location l on l.location_id = o.location_id
where o.checkout_operation_id like
        'client-sales-history-v1:' || l.location_id::text || ':%'
   or o.checkout_operation_id like
        'capstone-history-v1:' || l.location_id::text || ':%';

create temp table _undo_products (
  id uuid primary key, product_quantity numeric, created_at timestamptz,
  updated_at timestamptz
) on commit drop;
insert into _undo_products
select p.id, p.product_quantity, p.created_at, p.updated_at
from public.products p join _undo_location l on l.location_id = p.location_id
where p.create_operation_id like
        'client-records-v1:' || l.location_id::text || ':product:%'
   or p.create_operation_id like
        'capstone-history-v1:' || l.location_id::text || ':product:%';

do $check$
declare v_found boolean;
begin
  if (select count(*) from _undo_orders) <> 158 or
     (select sum(total_amount) from _undo_orders) <> 255110 then
    raise exception 'Imported order count/amount differs from 158 / PHP 255110. Stop and inspect the read-only check.';
  end if;
  if exists (select 1 from _undo_orders
      where status <> 'completed' or completed_at is null or
        updated_at > completed_at + interval '5 minutes') then
    raise exception 'An imported order appears to have changed after import';
  end if;
  if exists (select 1 from _undo_products
      where updated_at > created_at + interval '5 minutes') then
    raise exception 'An imported product appears to have changed after import';
  end if;
  if exists (
    select 1 from public.orders o
    cross join lateral jsonb_array_elements(o.items) item
    join _undo_products p on p.id::text =
      coalesce(item->>'product_id', item->>'productId')
    where not exists (select 1 from _undo_orders imported where imported.id=o.id)
  ) then
    raise exception 'An imported product is used by another order';
  end if;
  if exists (
    select 1 from public.order_history h
    cross join lateral jsonb_array_elements(h.items) item
    join _undo_products p on p.id::text =
      coalesce(item->>'product_id', item->>'productId')
    where not exists (select 1 from _undo_orders imported
      where imported.id::text=h.order_id)
  ) then
    raise exception 'An imported product is used by another order history row';
  end if;
  if exists (
    select 1 from public.transaction_history t
    join _undo_products p on p.id=t.product_id
    where not exists (select 1 from _undo_orders o where o.token=t.operation_id)
      and not (t.operation_scope='capstone_demo_stock' and
               t.operation_id like 'capstone-demo-stock-v1:%')
  ) then
    raise exception 'An imported product has a later or unrelated stock transaction';
  end if;
  if exists (
    select 1 from _undo_products p
    where coalesce(p.product_quantity,0) <> 0
      and not exists (select 1 from public.transaction_history t
        where t.product_id=p.id and t.operation_scope='capstone_demo_stock'
          and t.operation_id like 'capstone-demo-stock-v1:%'
          and t.new_quantity=p.product_quantity)
  ) then
    raise exception 'An imported product has an unexplained current stock balance';
  end if;
  if to_regclass('public.order_loading_proofs') is not null then
    execute 'select exists (select 1 from public.order_loading_proofs x join _undo_orders o on o.id=x.order_id)'
      into v_found;
    if v_found then raise exception 'An imported order has loading proof'; end if;
  end if;
  if to_regclass('public.order_heavy_scans') is not null then
    execute 'select exists (select 1 from public.order_heavy_scans x join _undo_orders o on o.id=x.order_id)'
      into v_found;
    if v_found then raise exception 'An imported order has a staff scan'; end if;
  end if;
  if to_regclass('public.forecast_replenishment_configs') is not null then
    execute 'select exists (select 1 from public.forecast_replenishment_configs x join _undo_products p on p.id=x.product_id)'
      into v_found;
    if v_found then raise exception 'An imported product has a replenishment configuration'; end if;
  end if;
  if to_regclass('public.approval_requests') is not null then
    execute 'select exists (select 1 from public.approval_requests x join _undo_orders o on o.id=x.used_order_id)'
      into v_found;
    if v_found then raise exception 'An imported order is linked to an approval request'; end if;
    execute 'select exists (select 1 from public.approval_requests x join _undo_products p on p.id=x.product_id)'
      into v_found;
    if v_found then raise exception 'An imported product is linked to an approval request'; end if;
  end if;
end $check$;

delete from public.order_history h using _undo_orders o
where h.order_id=o.id::text;

delete from public.transaction_history t using _undo_orders o,
  _undo_location l
where t.operation_id=o.token and t.location_id=l.location_id;

delete from public.transaction_history t using _undo_products p
where t.product_id=p.id and t.operation_scope='capstone_demo_stock'
  and t.operation_id like 'capstone-demo-stock-v1:%';

delete from public.orders o using _undo_orders imported
where o.id=imported.id;

delete from public.products p using _undo_products imported
where p.id=imported.id;

do $check$
begin
  if exists (select 1 from public.orders o join _undo_orders imported
      on o.id=imported.id) or
     exists (select 1 from public.products p join _undo_products imported
      on p.id=imported.id) then
    raise exception 'Rollback left imported records behind';
  end if;
  raise notice 'Removed % imported orders and % imported products; receipt stock logs and order history removed',
    (select count(*) from _undo_orders), (select count(*) from _undo_products);
end $check$;
commit;
