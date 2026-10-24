CREATE OR REPLACE FUNCTION public.history_page_v1 (
  p_session_token text,
  p_domain        text,
  p_period_start  timestamp with time zone,
  p_period_end    timestamp with time zone,
  p_filter        text                     DEFAULT 'all'::text,
  p_search        text                     DEFAULT ''::text,
  p_page          integer                  DEFAULT 1,
  p_page_size     integer                  DEFAULT 20
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  -- 10,000 pages is well beyond expected interactive history use while
  -- preventing abusive ultra-deep offsets. Keep bigint offset arithmetic.
  v_page bigint := least(greatest(coalesce(p_page, 1), 1), 10000)::bigint;
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_offset bigint;
  v_search text := lower(trim(coalesce(p_search, '')));
  v_filter text := lower(trim(coalesce(p_filter, 'all')));
  v_account_id text;
  v_role text;
  v_location_id uuid;
  v_result jsonb;
begin
  -- Both operands are bounded before bigint offset arithmetic.
  v_offset := (v_page - 1) * v_page_size::bigint;

  if p_period_start is null or p_period_end is null
    or p_period_end <= p_period_start then
    raise exception 'Invalid history period';
  end if;

  select session_profile.profile_id::text, session_profile.role,
      session_profile.location_id
    into v_account_id, v_role, v_location_id
  from private.require_app_session_v1(p_session_token) session_profile;
  if not found then raise exception 'History session is invalid or expired'; end if;

  if (p_domain in ('adminSales', 'adminActivity') and v_role <> 'admin')
    or (p_domain = 'helperWork' and v_role <> 'helper')
    or (p_domain in ('cashierOrders', 'cashierRestocks')
      and v_role not in ('staff', 'cashier'))
  then raise exception 'History domain is not allowed for this role'; end if;

  if p_domain in ('adminSales', 'cashierOrders', 'helperWork') then
    with scoped as (
      select
        o.order_id as id,
        o.status,
        o.items,
        o.created_at,
        o.created_by_id,
        o.created_by_name,
        o.assigned_helper_id,
        o.assigned_at,
        o.prepared_by_id,
        o.prepared_by_name,
        o.prepared_at,
        o.completed_by_id,
        o.completed_by_name,
        o.completed_at,
        o.cancelled_by_id,
        o.cancelled_by_name,
        o.cancelled_at,
        o.returned_by_id,
        o.returned_at,
        o.total_amount,
        o.discount_amount,
        o.cash_given,
        o.change_amount,
        o.payment_mode,
        o.payment_reference,
        case
          when p_domain = 'helperWork' then coalesce(greatest(
            case when o.assigned_helper_id = v_account_id then o.assigned_at end,
            case when o.prepared_by_id = v_account_id then o.prepared_at end
          ), o.created_at)
          when p_domain = 'cashierOrders' then coalesce(greatest(
            case when o.created_by_id = v_account_id then o.created_at end,
            case when o.completed_by_id = v_account_id then o.completed_at end,
            case when o.cancelled_by_id = v_account_id then o.cancelled_at end,
            case when o.returned_by_id = v_account_id then o.returned_at end
          ), o.created_at)
          else coalesce(o.completed_at, o.prepared_at, o.created_at)
        end as event_at,
        coalesce(o.created_by_name, (
          select name from public.profiles
          where id::text = o.created_by_id::text
        )) as history_created_by_name,
        coalesce(o.prepared_by_name, (
          select name from public.profiles
          where id::text = o.prepared_by_id::text
        )) as history_prepared_by_name,
        coalesce(o.completed_by_name, (
          select name from public.profiles
          where id::text = o.completed_by_id::text
        )) as history_completed_by_name,
        coalesce(o.cancelled_by_name, (
          select name from public.profiles
          where id::text = o.cancelled_by_id::text
        )) as history_cancelled_by_name
      from public.order_history o
      where o.location_id = v_location_id and (
        p_domain = 'adminSales'
        or (p_domain = 'helperWork' and (
          o.assigned_helper_id = v_account_id
          or o.prepared_by_id = v_account_id))
        or (p_domain = 'cashierOrders' and (
          o.created_by_id = v_account_id
          or o.completed_by_id = v_account_id
          or o.cancelled_by_id = v_account_id
          or o.returned_by_id = v_account_id))
      )
    ), period_base as (
      select * from scoped
      where event_at >= p_period_start and event_at < p_period_end
    ), matched as (
      select * from period_base
      where (
        v_filter = 'all'
        or (p_domain = 'adminSales' and (
          (v_filter = 'pending'
            and lower(status) in ('pending', 'solo_picking'))
          or (v_filter <> 'pending' and lower(status) = v_filter)))
        or (p_domain = 'helperWork' and v_filter = 'assigned'
          and assigned_helper_id = v_account_id)
        or (p_domain = 'helperWork' and v_filter = 'prepared'
          and prepared_by_id = v_account_id)
        or (p_domain = 'cashierOrders' and v_filter = 'created'
          and created_by_id = v_account_id)
        or (p_domain = 'cashierOrders' and v_filter = 'completed'
          and completed_by_id = v_account_id)
        or (p_domain = 'cashierOrders' and v_filter = 'cancelled' and (
          cancelled_by_id = v_account_id
          or returned_by_id = v_account_id))
      ) and (
        v_search = ''
        -- strpos makes '%' and '_' literal search text rather than wildcards.
        or strpos(lower(id::text), v_search) > 0
        or strpos(lower(status), v_search) > 0
        or exists (
          select 1
          from jsonb_array_elements(coalesce(items::jsonb, '[]'::jsonb)) item
          where strpos(lower(coalesce(
              item ->> 'product_name', item ->> 'productName', '')), v_search) > 0
            or strpos(lower(coalesce(
              item ->> 'sku', item ->> 'product_sku', '')), v_search) > 0
        )
      )
    ), page_rows as (
      select * from matched
      order by event_at desc, id desc
      offset v_offset limit v_page_size
    ), page_json as (
      select coalesce(jsonb_agg(
        case
          -- Helper output is a fail-closed allowlist. No order/item financial
          -- column is selected into either page or detail responses.
          when p_domain = 'helperWork' then jsonb_build_object(
            'id', id, 'status', status, 'created_at', created_at,
            'assigned_helper_id', assigned_helper_id, 'assigned_at', assigned_at,
            'prepared_by_id', prepared_by_id, 'prepared_at', prepared_at,
            'items', coalesce((
              select jsonb_agg(jsonb_build_object(
                'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
                'product_name', coalesce(
                  item ->> 'product_name', item ->> 'productName', 'Unknown'),
                'quantity', item -> 'quantity'
              ))
              from jsonb_array_elements(
                coalesce(page_rows.items::jsonb, '[]'::jsonb)) item
            ), '[]'::jsonb)
          )
          when p_domain = 'cashierOrders' then jsonb_build_object(
            'id', id, 'status', status, 'created_at', created_at,
            'total_amount', total_amount, 'created_by_id', created_by_id,
            'assigned_helper_id', assigned_helper_id, 'assigned_at', assigned_at,
            'prepared_by_id', prepared_by_id, 'prepared_at', prepared_at,
            'completed_by_id', completed_by_id, 'completed_at', completed_at,
            'cancelled_by_id', cancelled_by_id, 'cancelled_at', cancelled_at,
            'returned_by_id', returned_by_id, 'returned_at', returned_at,
            'payment_mode', payment_mode,
            'payment_reference', payment_reference,
            'items', coalesce((
              select jsonb_agg(jsonb_build_object(
                'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
                'product_name', coalesce(
                  item ->> 'product_name', item ->> 'productName', 'Unknown'),
                'quantity', item -> 'quantity'
              ))
              from jsonb_array_elements(
                coalesce(page_rows.items::jsonb, '[]'::jsonb)) item
            ), '[]'::jsonb)
          )
          else jsonb_build_object(
            'id', id, 'status', status, 'created_at', created_at,
            'total_amount', total_amount, 'discount_amount', discount_amount,
            'cash_given', cash_given, 'change_amount', change_amount,
            'payment_mode', payment_mode,
            'payment_reference', payment_reference,
            'created_by_name', history_created_by_name,
            'prepared_by_name', history_prepared_by_name,
            'completed_by_name', history_completed_by_name,
            'cancelled_by_name', history_cancelled_by_name,
            'prepared_at', prepared_at, 'completed_at', completed_at,
            'cancelled_at', cancelled_at,
            'items', coalesce((
              select jsonb_agg(jsonb_build_object(
                'product_id', coalesce(item ->> 'product_id', item ->> 'productId'),
                'product_name', coalesce(
                  item ->> 'product_name', item ->> 'productName', 'Unknown'),
                'quantity', item -> 'quantity',
                'price', coalesce(item -> 'price', item -> 'unit_price')
              ))
              from jsonb_array_elements(
                coalesce(page_rows.items::jsonb, '[]'::jsonb)) item
            ), '[]'::jsonb)
          )
        end order by event_at desc, id desc
      ), '[]'::jsonb) records
      from page_rows
    ), totals as (
      select count(*) total_count from matched
    ), metrics as (
      select case when p_domain = 'adminSales' then jsonb_build_object(
        'orders', count(*) filter (where lower(status) <> 'cancelled'),
        'pending', count(*) filter (
          where lower(status) in ('pending', 'prepared', 'solo_picking')),
        'revenue', coalesce(sum(total_amount) filter (
          where lower(status) = 'completed'), 0),
        'records', count(*)
      ) else jsonb_build_object(
        'records', count(*),
        'active', count(*) filter (where lower(status) in ('pending', 'prepared')),
        'completed', count(*) filter (where case
          when p_domain = 'helperWork'
            then prepared_by_id = v_account_id
          else completed_by_id = v_account_id end),
        'cancelled', count(*) filter (where p_domain <> 'helperWork' and (
          cancelled_by_id = v_account_id
          or returned_by_id = v_account_id))
      ) end value
      from period_base
    )
    select jsonb_build_object(
      'records', page_json.records,
      'total_count', totals.total_count,
      'metrics', metrics.value)
    into v_result
    from page_json cross join totals cross join metrics;

  elsif p_domain in ('adminActivity', 'cashierRestocks') then
    with period_base as (
      select
        t.id, t.product_id, t.transaction_type, t.quantity_change,
        t.new_quantity, t.user_id, t.user_name, t.created_at,
        p.product_name, p.sku, pr.name as profile_name
      from public.transaction_history t
      left join public.products p on p.id = t.product_id
      left join public.profiles pr on pr.id = t.user_id
      where t.location_id = v_location_id
        and t.created_at >= p_period_start and t.created_at < p_period_end
        and (
          p_domain = 'adminActivity'
          or (p_domain = 'cashierRestocks'
            and t.user_id::text = v_account_id
            and t.transaction_type = 'stock_in'
            and t.quantity_change > 0)
        )
    ), matched as (
      select * from period_base
      where (
        p_domain = 'cashierRestocks' or v_filter = 'all'
        or (v_filter = 'stock in' and quantity_change > 0)
        or (v_filter = 'stock out' and quantity_change < 0)
        or (v_filter = 'adjustments'
          and transaction_type = 'manual_adjustment')
      ) and (
        v_search = ''
        or strpos(lower(coalesce(product_name, '')), v_search) > 0
        or strpos(lower(coalesce(sku, '')), v_search) > 0
      )
    ), page_rows as (
      select * from matched
      order by created_at desc, id desc
      offset v_offset limit v_page_size
    ), page_json as (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'product_id', product_id,
        'transaction_type', transaction_type,
        'quantity_change', quantity_change, 'new_quantity', new_quantity,
        'user_id', user_id, 'user_name', user_name, 'created_at', created_at,
        'products', jsonb_build_object(
          'product_name', product_name, 'sku', sku),
        -- Activity needs only the actor display name. Restocks need no profile.
        'profiles', case when p_domain = 'adminActivity'
          then jsonb_build_object('name', profile_name) else null end
      ) order by created_at desc, id desc), '[]'::jsonb) records
      from page_rows
    ), totals as (
      select count(*) total_count from matched
    ), metrics as (
      select case when p_domain = 'adminActivity' then (
        select jsonb_build_object(
          'changes', count(*),
          'stock_in', coalesce(sum(quantity_change) filter (
            where quantity_change > 0), 0),
          'stock_out', coalesce(sum(abs(quantity_change)) filter (
            where quantity_change < 0), 0),
          'records', count(*), 'active', 0, 'completed', 0, 'cancelled', 0)
        from period_base
      ) else (
        -- Accepted Staff History retains order-work cards on the Restocks tab.
        -- This branch is not evaluated for Admin Activity.
        select jsonb_build_object(
          'records', count(*),
          'active', count(*) filter (
            where lower(status) in ('pending', 'prepared')),
          'completed', count(*) filter (
            where completed_by_id = v_account_id),
          'cancelled', count(*) filter (
            where cancelled_by_id = v_account_id
              or returned_by_id = v_account_id)
        )
        from (
          select
            o.status,
            o.created_by_id,
            o.completed_by_id,
            o.cancelled_by_id,
            o.returned_by_id,
            coalesce(greatest(
              case when o.created_by_id = v_account_id then o.created_at end,
              case when o.completed_by_id = v_account_id then o.completed_at end,
              case when o.cancelled_by_id = v_account_id then o.cancelled_at end,
              case when o.returned_by_id = v_account_id then o.returned_at end
            ), o.created_at) event_at
          from public.order_history o
          where o.location_id = v_location_id and (
            o.created_by_id = v_account_id
            or o.completed_by_id = v_account_id
            or o.cancelled_by_id = v_account_id
            or o.returned_by_id = v_account_id)
        ) cashier_orders
        where event_at >= p_period_start and event_at < p_period_end
      ) end value
    )
    select jsonb_build_object(
      'records', page_json.records,
      'total_count', totals.total_count,
      'metrics', metrics.value)
    into v_result
    from page_json cross join totals cross join metrics;
  else
    raise exception 'Unsupported history domain: %', p_domain;
  end if;

  return coalesce(v_result, jsonb_build_object(
    'records', '[]'::jsonb, 'total_count', 0, 'metrics', '{}'::jsonb));
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."history_page_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone, text, text, integer, integer) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."history_page_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone, text, text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."history_page_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone, text, text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."history_page_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone, text, text, integer, integer) TO "postgres";

REVOKE ALL ON FUNCTION "public"."history_page_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone, text, text, integer, integer) FROM PUBLIC, "authenticated";
