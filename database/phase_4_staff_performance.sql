-- Phase 4: derived, Admin-only Staff Performance Monitoring V1.
-- Deploy after the live schema and Phase 2C discount approvals. This script
-- creates reporting functions/indexes only; it does not persist employee scores.

create or replace function private.order_complexity_v1(
  p_items jsonb,
  p_location_id uuid,
  p_include_location boolean,
  p_payment_mode text default null,
  p_discount_amount numeric default 0,
  p_has_discount_approval boolean default false
) returns numeric
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  -- V1 constants live together here for straightforward formula tuning.
  with constants as (
    select 1.0::numeric as base_points,
           1.0::numeric as line_points,
           0.50::numeric as location_step,
           0.50::numeric as gcash_points,
           0.50::numeric as discount_points,
           1.00::numeric as approval_points
  ), raw_lines as (
    select
      coalesce(
        nullif(trim(item.value ->> 'product_id'), ''),
        nullif(trim(item.value ->> 'productId'), ''),
        'name:' || coalesce(
          nullif(trim(item.value ->> 'product_name'), ''),
          nullif(trim(item.value ->> 'productName'), ''),
          item.ordinality::text
        )
      ) as line_key,
      coalesce(
        nullif(trim(item.value ->> 'product_id'), ''),
        nullif(trim(item.value ->> 'productId'), '')
      ) as product_id,
      case
        when trim(coalesce(item.value ->> 'quantity', '')) ~
             '^[+]?[0-9]+([.][0-9]+)?$'
          then greatest((item.value ->> 'quantity')::numeric, 0)
        else 0
      end as quantity
    from jsonb_array_elements(
      case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end
    ) with ordinality as item(value, ordinality)
  ), lines as (
    select line_key, max(product_id) as product_id, sum(quantity) as quantity
    from raw_lines
    group by line_key
  ), item_factors as (
    select
      count(*)::numeric as line_count,
      coalesce(sum(case
        when quantity <= 1 then 0
        when quantity <= 5 then 0.25
        when quantity <= 10 then 0.50
        when quantity <= 20 then 0.75
        else 1.00
      end), 0)::numeric as quantity_burden
    from lines
  ), location_factor as (
    select case when p_include_location then
      greatest(count(distinct nullif(trim(product.map_element_id), '')) - 1, 0)
        * (select location_step from constants)
    else 0 end::numeric as burden
    from lines
    left join public.products product
      on product.id::text = lines.product_id
     and product.location_id = p_location_id
  )
  select round(
    constants.base_points
    + item_factors.line_count * constants.line_points
    + item_factors.quantity_burden
    + location_factor.burden
    + case when lower(trim(coalesce(p_payment_mode, ''))) = 'gcash'
           then constants.gcash_points else 0 end
    + case when coalesce(p_discount_amount, 0) > 0
           then constants.discount_points else 0 end
    + case when p_has_discount_approval
           then constants.approval_points else 0 end,
    2
  )
  from constants cross join item_factors cross join location_factor
$$;

revoke all on function private.order_complexity_v1(
  jsonb, uuid, boolean, text, numeric, boolean
) from public, anon, authenticated;

create or replace function public.staff_performance_v1(
  p_session_token text,
  p_role text,
  p_period_start timestamptz,
  p_period_end timestamptz
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_session record;
  v_role text := lower(trim(coalesce(p_role, '')));
  v_result jsonb;
begin
  select * into v_session
  from private.require_app_session_v1(p_session_token);

  if not found or v_session.role <> 'admin' then
    raise exception 'Staff Performance is available to Admin accounts only';
  end if;
  if v_role not in ('helper', 'cashier') then
    raise exception 'Unsupported performance role';
  end if;
  if p_period_start is null or p_period_end is null
     or p_period_end <= p_period_start then
    raise exception 'A valid performance period is required';
  end if;

  if v_role = 'helper' then
    with constants as (
      select 30.0::numeric as delay_minutes,
             5::integer as minimum_sample,
             0.40::numeric as on_time_weight,
             0.30::numeric as throughput_weight,
             0.20::numeric as efficiency_weight,
             0.10::numeric as reliability_weight
    ), prepared_orders as (
      select
        history.order_id,
        history.prepared_by_id as employee_id,
        coalesce(nullif(trim(history.prepared_by_name), ''), 'Former staff member')
          as employee_name,
        private.order_complexity_v1(
          history.items, history.location_id, true, null, 0, false
        ) as complexity_points,
        case when history.assigned_at is not null
                   and history.prepared_at >= history.assigned_at
             then extract(epoch from (history.prepared_at - history.assigned_at)) / 60.0
        end::numeric as duration_minutes
      from public.order_history history
      where history.location_id = v_session.location_id
        and history.prepared_at >= p_period_start
        and history.prepared_at < p_period_end
        and nullif(trim(history.prepared_by_id), '') is not null
    ), employee_candidates as (
      select profile.id::text as employee_id, profile.name as employee_name,
             2 as source_priority
      from public.profiles profile
      where profile.location_id = v_session.location_id
        and lower(profile.role) = 'helper'
      union all
      select employee_id, max(employee_name), 1
      from prepared_orders
      group by employee_id
    ), employees as (
      select employee_id,
             (array_agg(employee_name order by source_priority desc))[1]
               as employee_name
      from employee_candidates
      group by employee_id
    ), aggregates as (
      select
        employee.employee_id,
        employee.employee_name,
        count(prepared.order_id)::integer as completed_count,
        count(prepared.duration_minutes)::integer as valid_timing_count,
        (count(prepared.order_id) - count(prepared.duration_minutes))::integer
          as excluded_timing_count,
        coalesce(sum(prepared.complexity_points), 0)::numeric as workload_points,
        round(avg(prepared.duration_minutes), 2) as average_minutes,
        round((percentile_cont(0.5) within group
          (order by prepared.duration_minutes))::numeric, 2) as median_minutes,
        round(min(prepared.duration_minutes), 2) as fastest_minutes,
        count(*) filter (
          where prepared.duration_minutes < constants.delay_minutes
        )::integer as on_time_count,
        count(*) filter (
          where prepared.duration_minutes >= constants.delay_minutes
        )::integer as delayed_count,
        case when count(prepared.duration_minutes) = 0 then 0 else round(
          100.0 * count(*) filter (
            where prepared.duration_minutes < constants.delay_minutes
          ) / count(prepared.duration_minutes), 2
        ) end::numeric as on_time_rate,
        case when count(prepared.duration_minutes) = 0 then 0 else round(
          100.0 * count(*) filter (
            where prepared.duration_minutes >= constants.delay_minutes
          ) / count(prepared.duration_minutes), 2
        ) end::numeric as delay_rate,
        case when coalesce(sum(prepared.duration_minutes), 0) <= 0 then null
             else round(
               sum(prepared.complexity_points) filter (
                 where prepared.duration_minutes is not null
               ) / sum(prepared.duration_minutes), 4
             ) end as efficiency
      from employees employee
      cross join constants
      left join prepared_orders prepared
        on prepared.employee_id = employee.employee_id
      group by employee.employee_id, employee.employee_name
    ), eligible_base as (
      select aggregates.*,
        count(*) over ()::integer as peer_count,
        (percent_rank() over (order by workload_points) * 100)::numeric
          as throughput_peer,
        (percent_rank() over (order by coalesce(efficiency, 0)) * 100)::numeric
          as efficiency_peer
      from aggregates, constants
      where valid_timing_count >= constants.minimum_sample
    ), eligible_spread as (
      select count(distinct workload_points)::integer as workload_spread,
             count(distinct coalesce(efficiency, 0))::integer
               as efficiency_spread
      from eligible_base
    ), eligible as (
      select eligible_base.*, eligible_spread.workload_spread,
             eligible_spread.efficiency_spread
      from eligible_base cross join eligible_spread
    ), scored as (
      select aggregates.*,
        coalesce(eligible.peer_count, 0) as peer_count,
        case when aggregates.valid_timing_count < constants.minimum_sample then null
        else round(
          constants.on_time_weight * aggregates.on_time_rate
          + constants.throughput_weight * case
              when eligible.peer_count = 1 or eligible.workload_spread = 1 then 50
              else eligible.throughput_peer end
          + constants.efficiency_weight * case
              when eligible.peer_count = 1 or eligible.efficiency_spread = 1 then 50
              else eligible.efficiency_peer end
          + constants.reliability_weight * (100 - aggregates.delay_rate),
          2
        ) end as score
      from aggregates
      cross join constants
      left join eligible using (employee_id)
    ), enriched as (
      select scored.*,
        exists (
          select 1 from public.staff_presence presence
          where presence.user_id = scored.employee_id
            and presence.location_id = v_session.location_id::text
            and lower(presence.user_role) = 'helper'
            and presence.is_online = true
            and presence.last_seen_at >= now() - interval '2 minutes'
        ) as is_active,
        (select count(*)::integer
         from public.orders active_order
         where active_order.location_id = v_session.location_id
           and lower(active_order.status) = 'pending'
           and active_order.assigned_helper_id = scored.employee_id
        ) as current_workload
      from scored
    )
    select jsonb_build_object(
      'role', 'helper',
      'active_hours_available', false,
      'location_complexity_coverage',
        'Current product map locations when the product reference still resolves',
      'records', coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', employee_id,
        'employee_name', employee_name,
        'is_active', is_active,
        'completed_count', completed_count,
        'valid_timing_count', valid_timing_count,
        'excluded_timing_count', excluded_timing_count,
        'workload_points', round(workload_points, 2),
        'average_minutes', average_minutes,
        'median_minutes', median_minutes,
        'fastest_minutes', fastest_minutes,
        'on_time_rate', on_time_rate,
        'delayed_count', delayed_count,
        'delay_rate', delay_rate,
        'reliability', round(100 - delay_rate, 2),
        'efficiency', efficiency,
        'current_workload', current_workload,
        'sales_handled', 0,
        'discounted_transactions', 0,
        'discount_usage_rate', 0,
        'discount_approval_requests', 0,
        'discount_approvals_approved', 0,
        'discount_approvals_rejected', 0,
        'discount_approvals_pending', 0,
        'score', score,
        'peer_count', peer_count
      ) order by score desc nulls last, employee_name), '[]'::jsonb)
    ) into v_result
    from enriched;
  else
    with constants as (
      select 15.0::numeric as delay_minutes,
             5::integer as minimum_sample,
             0.40::numeric as on_time_weight,
             0.30::numeric as throughput_weight,
             0.20::numeric as efficiency_weight,
             0.10::numeric as reliability_weight
    ), completed_orders as (
      select
        history.order_id,
        history.completed_by_id as employee_id,
        coalesce(nullif(trim(history.completed_by_name), ''), 'Former staff member')
          as employee_name,
        history.total_amount,
        history.discount_amount,
        private.order_complexity_v1(
          history.items,
          history.location_id,
          false,
          history.payment_mode,
          history.discount_amount,
          exists (
            select 1
            from public.approval_requests approval
            where approval.request_type = 'discount'
              and approval.status = 'approved'
              and to_jsonb(approval) ->> 'used_order_id' = history.order_id
          )
        ) as complexity_points,
        case when history.prepared_at is not null
                   and history.completed_at >= history.prepared_at
             then extract(epoch from (history.completed_at - history.prepared_at)) / 60.0
        end::numeric as duration_minutes
      from public.order_history history
      where history.location_id = v_session.location_id
        and history.completed_at >= p_period_start
        and history.completed_at < p_period_end
        and nullif(trim(history.completed_by_id), '') is not null
    ), approval_counts as (
      select approval.requested_by_id::text as employee_id,
        count(*)::integer as request_count,
        count(*) filter (where approval.status = 'approved')::integer as approved_count,
        count(*) filter (where approval.status = 'rejected')::integer as rejected_count,
        count(*) filter (where approval.status = 'pending')::integer as pending_count
      from public.approval_requests approval
      where approval.location_id = v_session.location_id
        and approval.request_type = 'discount'
        and approval.requested_at >= p_period_start
        and approval.requested_at < p_period_end
      group by approval.requested_by_id
    ), employee_candidates as (
      select profile.id::text as employee_id, profile.name as employee_name,
             2 as source_priority
      from public.profiles profile
      where profile.location_id = v_session.location_id
        and lower(profile.role) = 'staff'
      union all
      select employee_id, max(employee_name), 1
      from completed_orders
      group by employee_id
    ), employees as (
      select employee_id,
             (array_agg(employee_name order by source_priority desc))[1]
               as employee_name
      from employee_candidates
      group by employee_id
    ), aggregates as (
      select
        employee.employee_id,
        employee.employee_name,
        count(completed.order_id)::integer as completed_count,
        count(completed.duration_minutes)::integer as valid_timing_count,
        (count(completed.order_id) - count(completed.duration_minutes))::integer
          as excluded_timing_count,
        coalesce(sum(completed.complexity_points), 0)::numeric as workload_points,
        round(avg(completed.duration_minutes), 2) as average_minutes,
        round((percentile_cont(0.5) within group
          (order by completed.duration_minutes))::numeric, 2) as median_minutes,
        round(min(completed.duration_minutes), 2) as fastest_minutes,
        count(*) filter (
          where completed.duration_minutes >= constants.delay_minutes
        )::integer as delayed_count,
        case when count(completed.duration_minutes) = 0 then 0 else round(
          100.0 * count(*) filter (
            where completed.duration_minutes < constants.delay_minutes
          ) / count(completed.duration_minutes), 2
        ) end::numeric as on_time_rate,
        case when count(completed.duration_minutes) = 0 then 0 else round(
          100.0 * count(*) filter (
            where completed.duration_minutes >= constants.delay_minutes
          ) / count(completed.duration_minutes), 2
        ) end::numeric as delay_rate,
        case when coalesce(sum(completed.duration_minutes), 0) <= 0 then null
             else round(
               sum(completed.complexity_points) filter (
                 where completed.duration_minutes is not null
               ) / sum(completed.duration_minutes), 4
             ) end as efficiency,
        coalesce(sum(completed.total_amount), 0)::numeric as sales_handled,
        count(*) filter (
          where coalesce(completed.discount_amount, 0) > 0
        )::integer as discounted_transactions
      from employees employee
      cross join constants
      left join completed_orders completed
        on completed.employee_id = employee.employee_id
      group by employee.employee_id, employee.employee_name
    ), eligible_base as (
      select aggregates.*,
        count(*) over ()::integer as peer_count,
        (percent_rank() over (order by workload_points) * 100)::numeric
          as throughput_peer,
        (percent_rank() over (order by coalesce(efficiency, 0)) * 100)::numeric
          as efficiency_peer
      from aggregates, constants
      where valid_timing_count >= constants.minimum_sample
    ), eligible_spread as (
      select count(distinct workload_points)::integer as workload_spread,
             count(distinct coalesce(efficiency, 0))::integer
               as efficiency_spread
      from eligible_base
    ), eligible as (
      select eligible_base.*, eligible_spread.workload_spread,
             eligible_spread.efficiency_spread
      from eligible_base cross join eligible_spread
    ), scored as (
      select aggregates.*,
        coalesce(eligible.peer_count, 0) as peer_count,
        case when aggregates.valid_timing_count < constants.minimum_sample then null
        else round(
          constants.on_time_weight * aggregates.on_time_rate
          + constants.throughput_weight * case
              when eligible.peer_count = 1 or eligible.workload_spread = 1 then 50
              else eligible.throughput_peer end
          + constants.efficiency_weight * case
              when eligible.peer_count = 1 or eligible.efficiency_spread = 1 then 50
              else eligible.efficiency_peer end
          + constants.reliability_weight * (100 - aggregates.delay_rate),
          2
        ) end as score
      from aggregates
      cross join constants
      left join eligible using (employee_id)
    ), enriched as (
      select scored.*,
        exists (
          select 1 from public.staff_presence presence
          where presence.user_id = scored.employee_id
            and presence.location_id = v_session.location_id::text
            and lower(presence.user_role) in ('staff', 'cashier')
            and presence.is_online = true
            and presence.last_seen_at >= now() - interval '2 minutes'
        ) as is_active,
        coalesce(approval_counts.request_count, 0) as approval_requests,
        coalesce(approval_counts.approved_count, 0) as approvals_approved,
        coalesce(approval_counts.rejected_count, 0) as approvals_rejected,
        coalesce(approval_counts.pending_count, 0) as approvals_pending
      from scored
      left join approval_counts using (employee_id)
    )
    select jsonb_build_object(
      'role', 'cashier',
      'active_hours_available', false,
      'location_complexity_coverage', 'Not used for Cashier scoring',
      'records', coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', employee_id,
        'employee_name', employee_name,
        'is_active', is_active,
        'completed_count', completed_count,
        'valid_timing_count', valid_timing_count,
        'excluded_timing_count', excluded_timing_count,
        'workload_points', round(workload_points, 2),
        'average_minutes', average_minutes,
        'median_minutes', median_minutes,
        'fastest_minutes', fastest_minutes,
        'on_time_rate', on_time_rate,
        'delayed_count', delayed_count,
        'delay_rate', delay_rate,
        'reliability', round(100 - delay_rate, 2),
        'efficiency', efficiency,
        'current_workload', 0,
        'sales_handled', round(sales_handled, 2),
        'discounted_transactions', discounted_transactions,
        'discount_usage_rate', case when completed_count = 0 then 0
          else round(100.0 * discounted_transactions / completed_count, 2) end,
        'discount_approval_requests', approval_requests,
        'discount_approvals_approved', approvals_approved,
        'discount_approvals_rejected', approvals_rejected,
        'discount_approvals_pending', approvals_pending,
        'score', score,
        'peer_count', peer_count
      ) order by score desc nulls last, employee_name), '[]'::jsonb)
    ) into v_result
    from enriched;
  end if;

  return coalesce(v_result, jsonb_build_object(
    'role', v_role,
    'active_hours_available', false,
    'records', '[]'::jsonb
  ));
end;
$$;

revoke all on function public.staff_performance_v1(
  text, text, timestamptz, timestamptz
) from public, authenticated;
grant execute on function public.staff_performance_v1(
  text, text, timestamptz, timestamptz
) to anon;

create index if not exists order_history_helper_period_v1_idx
  on public.order_history (location_id, prepared_at, prepared_by_id)
  where prepared_at is not null and prepared_by_id is not null;

create index if not exists order_history_cashier_period_v1_idx
  on public.order_history (location_id, completed_at, completed_by_id)
  where completed_at is not null and completed_by_id is not null;

create index if not exists orders_helper_current_workload_v1_idx
  on public.orders (location_id, assigned_helper_id)
  where status = 'pending' and assigned_helper_id is not null;
