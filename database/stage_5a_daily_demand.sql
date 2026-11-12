-- Stage 5A: authenticated, location-scoped completed-sales extraction.
--
-- Demand comes from the durable order_history snapshot, not inventory
-- movements. Checkout inventory movements occur before payment and can later
-- be reversed by cancellation, so they are not an authoritative sales ledger.

create or replace function public.forecast_daily_demand_v1(
  p_session_token text,
  p_period_start timestamp with time zone,
  p_period_end timestamp with time zone,
  p_business_timezone text default 'Asia/Manila'
)
returns table (
  business_date date,
  location_id uuid,
  product_id uuid,
  sku text,
  product_name text,
  unit text,
  quantity numeric,
  completed_order_count bigint
)
language plpgsql
stable
security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_timezone text := nullif(trim(coalesce(p_business_timezone, '')), '');
  v_order record;
  v_item jsonb;
  v_product_id_text text;
  v_quantity_text text;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Forecasting session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Demand history is not allowed for this profile';
  end if;
  if p_period_start is null or p_period_end is null
      or p_period_end <= p_period_start then
    raise exception 'Invalid demand-history period';
  end if;
  if p_period_end - p_period_start > interval '5 years' then
    raise exception 'Demand-history period exceeds five years';
  end if;
  if v_timezone is null or not exists (
    select 1 from pg_catalog.pg_timezone_names zone
    where zone.name = v_timezone
  ) then
    raise exception 'Invalid business timezone';
  end if;

  -- A completed row without completed_at cannot be assigned to one exact
  -- business date. Treat its possible completion interval as the period from
  -- order creation through durable snapshot update. If that interval overlaps
  -- the requested half-open window, fail closed rather than understating
  -- demand. Rows proven entirely outside the window do not block extraction.
  if exists (
    select 1
    from public.order_history history
    where history.location_id = v_profile.location_id
      and lower(trim(history.status)) = 'completed'
      and history.completed_at is null
      and history.returned_at is null
      and history.created_at < p_period_end
      and (
        history.snapshot_updated_at >= p_period_start
        or history.snapshot_updated_at < history.created_at
      )
  ) then
    raise exception
      'Completed sales overlapping the requested period have no completion timestamp';
  end if;

  -- Fail closed on corrupt completed-sale snapshots. Silently skipping an
  -- invalid line would understate demand and make later forecasts unauditable.
  for v_order in
    select history.order_id, history.items
    from public.order_history history
    where history.location_id = v_profile.location_id
      and lower(trim(history.status)) = 'completed'
      and history.completed_at is not null
      and history.completed_at >= p_period_start
      and history.completed_at < p_period_end
      and history.returned_at is null
  loop
    if jsonb_typeof(v_order.items) is distinct from 'array' then
      raise exception 'Completed order % has invalid item data',
        v_order.order_id;
    end if;
    if jsonb_array_length(v_order.items) = 0 then
      raise exception 'Completed order % has no item lines', v_order.order_id;
    end if;
    for v_item in select value from jsonb_array_elements(v_order.items)
    loop
      v_product_id_text := coalesce(
        v_item ->> 'product_id', v_item ->> 'productId');
      v_quantity_text := v_item ->> 'quantity';
      if v_product_id_text is null or v_quantity_text is null
          or v_quantity_text !~ '^[0-9]+([.][0-9]+)?$' then
        raise exception 'Completed order % has an invalid item line',
          v_order.order_id;
      end if;
      if v_quantity_text::numeric <= 0 then
        raise exception 'Completed order % has an invalid item quantity',
          v_order.order_id;
      end if;
      begin
        perform v_product_id_text::uuid;
      exception when invalid_text_representation then
        raise exception 'Completed order % has an invalid product identifier',
          v_order.order_id;
      end;
    end loop;
  end loop;

  return query
  with completed_orders as (
    select
      history.order_id,
      history.location_id,
      history.completed_at,
      history.items
    from public.order_history history
    where history.location_id = v_profile.location_id
      and lower(trim(history.status)) = 'completed'
      and history.completed_at is not null
      and history.completed_at >= p_period_start
      and history.completed_at < p_period_end
      -- No line-level refund quantity exists in the verified schema. A whole
      -- order marked returned is therefore excluded rather than estimated.
      and history.returned_at is null
  ), expanded as (
    select
      orders.order_id,
      orders.location_id,
      (orders.completed_at at time zone v_timezone)::date as business_date,
      coalesce(item.value ->> 'product_id', item.value ->> 'productId') as product_id_text,
      coalesce(
        nullif(trim(item.value ->> 'product_name'), ''),
        nullif(trim(item.value ->> 'productName'), ''),
        'Unknown product'
      ) as product_name,
      coalesce(nullif(trim(item.value ->> 'unit'), ''), 'pcs') as unit,
      item.value ->> 'quantity' as quantity_text
    from completed_orders orders
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(orders.items) = 'array'
        then orders.items else '[]'::jsonb end
    ) item
  ), validated as (
    select
      expanded.order_id,
      expanded.location_id,
      expanded.business_date,
      expanded.product_id_text::uuid as product_id,
      expanded.product_name,
      expanded.unit,
      expanded.quantity_text::numeric as quantity
    from expanded
  )
  select
    validated.business_date,
    validated.location_id,
    validated.product_id,
    product.sku,
    max(validated.product_name) as product_name,
    validated.unit,
    sum(validated.quantity) as quantity,
    count(distinct validated.order_id) as completed_order_count
  from validated
  left join public.products product
    on product.id = validated.product_id
   and product.location_id = validated.location_id
  group by validated.business_date, validated.location_id,
    validated.product_id, product.sku, validated.unit
  order by validated.business_date, validated.product_id;
end;
$function$;

grant execute on function public.forecast_daily_demand_v1(
  text, timestamp with time zone, timestamp with time zone, text
) to anon, service_role, postgres;

revoke all on function public.forecast_daily_demand_v1(
  text, timestamp with time zone, timestamp with time zone, text
) from public, authenticated;

