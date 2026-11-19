-- Apply after phase_bodegero_worker_tabs.sql. Filters before pagination.
create or replace function public.bodegero_loading_history_v2(
  p_session_token text,
  p_page integer default 1,
  p_search text default '',
  p_page_size integer default 20,
  p_start timestamptz default null,
  p_end timestamptz default null,
  p_status text default 'all'
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_actor record;
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_total integer;
  v_records jsonb;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'bodegero' then
    raise exception 'Bodegero session required' using errcode = '42501';
  end if;
  if v_status not in ('all', 'waiting', 'ready', 'completed', 'cancelled')
     or (p_start is not null and p_end is not null and p_start >= p_end) then
    raise exception 'Invalid loading history filters';
  end if;

  with scoped as (
    select proof.order_id, proof.truck_plate, proof.captured_at,
      orders.status, orders.items
    from public.order_loading_proofs proof
    join public.orders orders on orders.id = proof.order_id
    where proof.location_id = v_actor.location_id
      and orders.location_id = v_actor.location_id
      and proof.bodegero_id = v_actor.profile_id
      and (p_start is null or proof.captured_at >= p_start)
      and (p_end is null or proof.captured_at < p_end)
      and (
        v_status = 'all'
        or (v_status = 'waiting' and orders.status in ('pending', 'solo_picking'))
        or (v_status = 'ready' and orders.status = 'prepared')
        or (v_status = 'completed' and orders.status = 'completed')
        or (v_status = 'cancelled' and orders.status in ('cancelled', 'returned'))
      )
      and (
        v_search = ''
        or strpos(lower(proof.order_id::text), v_search) > 0
        or strpos(lower(proof.truck_plate), v_search) > 0
        or exists (
          select 1
          from jsonb_array_elements(coalesce(orders.items::jsonb, '[]'::jsonb)) item
          where coalesce(item ->> 'requires_loading', 'false') = 'true'
            and strpos(lower(coalesce(item ->> 'product_name', '')), v_search) > 0
        )
      )
  ), page_rows as (
    select * from scoped
    order by captured_at desc, order_id desc
    offset (v_page::bigint - 1) * v_page_size limit v_page_size
  )
  select
    (select count(*) from scoped),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'order_id', row.order_id,
        'truck_plate', row.truck_plate,
        'captured_at', row.captured_at,
        'status', row.status,
        'items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'product_name', coalesce(item ->> 'product_name', 'Unknown product'),
            'quantity', item -> 'quantity'
          ))
          from jsonb_array_elements(coalesce(row.items::jsonb, '[]'::jsonb)) item
          where coalesce(item ->> 'requires_loading', 'false') = 'true'
        ), '[]'::jsonb)
      ) order by row.captured_at desc, row.order_id desc)
      from page_rows row
    ), '[]'::jsonb)
  into v_total, v_records;

  return jsonb_build_object(
    'records', v_records,
    'total_count', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
end;
$$;
revoke all on function public.bodegero_loading_history_v2(text, integer, text, integer, timestamptz, timestamptz, text)
  from public, authenticated;
grant execute on function public.bodegero_loading_history_v2(text, integer, text, integer, timestamptz, timestamptz, text)
  to anon, service_role;
