-- Apply this migration before using server-side Stock movements pagination.
create index if not exists approval_requests_transaction_id_idx
  on public.approval_requests (location_id, transaction_id)
  where transaction_id is not null;

create or replace function public.stock_movements_page_v1(
  p_session_token text,
  p_page integer default 1,
  p_page_size integer default 10,
  p_filter text default 'all',
  p_search text default '',
  p_period_start timestamptz default null,
  p_period_end timestamptz default null
)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_actor record;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 10), 1), 100);
  v_filter text := lower(trim(coalesce(p_filter, 'all')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_total bigint;
  v_records jsonb;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found or v_actor.role <> 'admin' then
    raise exception 'Admin session required' using errcode = '42501';
  end if;
  if v_page > 100000 or v_filter not in
      ('all', 'all movement types', 'sale', 'restock', 'write-off') then
    raise exception 'Invalid stock movement page or filter';
  end if;

  with matched as (
    select t.id, t.created_at, t.product_id, t.transaction_type,
      t.quantity_change, t.new_quantity, t.user_name, t.note,
      p.product_name, p.sku
    from public.transaction_history t
    left join public.products p on p.id = t.product_id
    where t.location_id = v_actor.location_id
      and (p_period_start is null or t.created_at >= p_period_start)
      and (p_period_end is null or t.created_at < p_period_end)
      and (v_filter in ('all', 'all movement types')
        or (v_filter = 'sale' and t.transaction_type in ('checkout', 'stock_out'))
        or (v_filter = 'restock' and t.transaction_type in ('stock_in', 'add'))
        or (v_filter = 'write-off' and t.transaction_type = 'write_off'))
      and (v_search = ''
        or strpos(lower(coalesce(p.product_name, '')), v_search) > 0
        or strpos(lower(coalesce(p.sku, '')), v_search) > 0
        or strpos(lower(coalesce(t.note, '')), v_search) > 0
        or strpos(lower(coalesce(t.transaction_type, '')), v_search) > 0
        or strpos(case
          when t.transaction_type in ('checkout', 'stock_out') then 'sale'
          when t.transaction_type in ('stock_in', 'add') then 'restock'
          when t.transaction_type = 'write_off' then 'write-off'
          when t.transaction_type = 'manual_adjustment' then 'adjustment'
          when t.transaction_type = 'order_cancelled' then 'return'
          else coalesce(t.transaction_type, '')
        end, v_search) > 0)
  ), total as (
    select count(*) as count from matched
  ), page_rows as (
    select * from matched
    order by created_at desc, id desc
    offset (v_page::bigint - 1) * v_size limit v_size
  ), enriched as (
    select page_rows.*, approval.requested_by_name,
      approval.reviewed_by_name, approval.reason, approval.request_note
    from page_rows
    left join lateral (
      select a.requested_by_name, a.reviewed_by_name,
        a.reason, a.note as request_note
      from public.approval_requests a
      where a.transaction_id = page_rows.id
        and a.location_id = v_actor.location_id
        and a.request_type = 'write_off'
        and a.status = 'approved'
      order by a.reviewed_at desc, a.id desc
      limit 1
    ) approval on page_rows.transaction_type = 'write_off'
  )
  select total.count, coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', row.id, 'created_at', row.created_at,
      'product_id', row.product_id, 'transaction_type', row.transaction_type,
      'quantity_change', row.quantity_change,
      'new_quantity', row.new_quantity, 'user_name', row.user_name,
      'note', row.note,
      'products', jsonb_build_object(
        'product_name', row.product_name, 'sku', row.sku),
      'requested_by_name', row.requested_by_name,
      'approved_by_name', row.reviewed_by_name,
      'write_off_reason', row.reason,
      'write_off_note', row.request_note
    ) order by row.created_at desc, row.id desc)
    from enriched row
  ), '[]'::jsonb)
  into v_total, v_records from total;

  return jsonb_build_object('records', v_records, 'total_count', v_total);
end;
$$;

revoke all on function public.stock_movements_page_v1(
  text, integer, integer, text, text, timestamptz, timestamptz
) from public;
grant execute on function public.stock_movements_page_v1(
  text, integer, integer, text, text, timestamptz, timestamptz
) to anon, service_role;

notify pgrst, 'reload schema';
