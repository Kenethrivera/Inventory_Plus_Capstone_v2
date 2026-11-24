-- Deploy before the customer tracking page and cashier QR code.
-- Tracking tokens stay in the private schema, separate from public.orders.
create table if not exists private.order_tracking_links (
  order_id uuid primary key references public.orders(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);

revoke all on private.order_tracking_links from public, anon, authenticated;

create or replace function private.create_order_tracking_link_v1()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  insert into private.order_tracking_links (order_id)
  values (new.id)
  on conflict (order_id) do nothing;
  return new;
end;
$$;

revoke all on function private.create_order_tracking_link_v1()
  from public, anon, authenticated;

drop trigger if exists orders_create_tracking_link_v1 on public.orders;
create trigger orders_create_tracking_link_v1
after insert on public.orders
for each row execute function private.create_order_tracking_link_v1();

insert into private.order_tracking_links (order_id)
select id from public.orders
on conflict (order_id) do nothing;

-- Only the cashier who created the order, or an admin at the same store,
-- may retrieve the QR token. Repeated calls return the same token.
create or replace function public.customer_order_tracking_token_v1(
  p_session_token text,
  p_order_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_profile record;
  v_token uuid;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found or v_profile.role not in ('admin', 'staff', 'cashier') then
    raise exception 'order_tracking_not_allowed';
  end if;

  select link.token into v_token
  from private.order_tracking_links link
  join public.orders customer_order on customer_order.id = link.order_id
  where customer_order.id = p_order_id
    and customer_order.location_id = v_profile.location_id
    and (v_profile.role = 'admin'
      or customer_order.created_by = v_profile.profile_id);
  if not found then
    raise exception 'order_tracking_not_found';
  end if;
  return v_token;
end;
$$;

revoke all on function public.customer_order_tracking_token_v1(text, uuid)
  from public, anon, authenticated;
grant execute on function public.customer_order_tracking_token_v1(text, uuid)
  to anon;

-- A customer with the unguessable QR token receives only order status data.
-- No payment, staff, location, customer, or full order row is returned.
create or replace function public.customer_order_status_v1(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_items jsonb;
begin
  select customer_order.* into v_order
  from private.order_tracking_links link
  join public.orders customer_order on customer_order.id = link.order_id
  where link.token = p_token;
  if not found then return null; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'name', coalesce(item.value->>'product_name', item.value->>'productName', 'Item'),
      'quantity', coalesce((item.value->>'quantity')::numeric, 0),
      'requiresLoading', coalesce((item.value->>'requires_loading')::boolean, false),
      'picked', coalesce((item.value->>'picked')::boolean, false),
      'heavyVerified', coalesce((item.value->>'heavy_verified')::boolean, false)
    ) order by item.ordinality
  ), '[]'::jsonb) into v_items
  from jsonb_array_elements(v_order.items) with ordinality as item(value, ordinality);

  return jsonb_build_object(
    'orderNumber', upper(left(v_order.id::text, 8)),
    'status', v_order.status,
    'createdAt', v_order.created_at,
    'updatedAt', v_order.updated_at,
    'preparedAt', v_order.prepared_at,
    'completedAt', v_order.completed_at,
    'assigned', v_order.assigned_helper_id is not null
      or v_order.assigned_bodegero_id is not null,
    'items', v_items
  );
end;
$$;

revoke all on function public.customer_order_status_v1(uuid)
  from public, anon, authenticated;
grant execute on function public.customer_order_status_v1(uuid) to anon;
