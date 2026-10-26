CREATE OR REPLACE FUNCTION public.staff_performance_v1 (
  p_session_token text,
  p_role          text,
  p_period_start  timestamp with time zone,
  p_period_end    timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
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
    ), period_orders as (
      select
        history.order_id,
        nullif(trim(history.prepared_by_id), '') as employee_id,
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
    ), prepared_orders as (
      select * from period_orders where employee_id is not null
    ), period_totals as (
      select
        count(*)::integer as total_store_orders,
        count(*) filter (where employee_id is not null)::integer
          as total_role_handled_orders,
        coalesce(sum(complexity_points) filter (
          where employee_id is not null
        ), 0)::numeric as total_role_workload_points,
        count(*) filter (where employee_id is null)::integer
          as unattributed_order_count,
        count(duration_minutes) filter (where employee_id is not null)::integer
          as total_valid_timing_count,
        count(*) filter (
          where employee_id is not null and duration_minutes is null
        )::integer as total_excluded_timing_count
      from period_orders
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
        coalesce(sum(prepared.duration_minutes), 0)::numeric
          as total_service_minutes,
        coalesce(sum(prepared.complexity_points) filter (
          where prepared.duration_minutes is not null
        ), 0)::numeric as timed_workload_points,
        avg(prepared.duration_minutes)::numeric as average_minutes,
        (percentile_cont(0.5) within group
          (order by prepared.duration_minutes))::numeric as median_minutes,
        min(prepared.duration_minutes)::numeric as fastest_minutes,
        count(*) filter (
          where prepared.duration_minutes < constants.delay_minutes
        )::integer as on_time_count,
        count(*) filter (
          where prepared.duration_minutes >= constants.delay_minutes
        )::integer as delayed_count,
        case when count(prepared.duration_minutes) = 0 then 0 else
          100.0 * count(*) filter (
            where prepared.duration_minutes < constants.delay_minutes
          ) / count(prepared.duration_minutes)
        end::numeric as on_time_rate,
        case when count(prepared.duration_minutes) = 0 then 0 else
          100.0 * count(*) filter (
            where prepared.duration_minutes >= constants.delay_minutes
          ) / count(prepared.duration_minutes)
        end::numeric as delay_rate,
        case when coalesce(sum(prepared.duration_minutes), 0) <= 0 then null
             else
               (sum(prepared.complexity_points) filter (
                 where prepared.duration_minutes is not null
               )) / sum(prepared.duration_minutes) end as efficiency
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
              when eligible.peer_count = 1 or eligible.workload_spread = 1
                then 50::numeric
              else eligible.throughput_peer end as adjusted_throughput,
         case when aggregates.valid_timing_count < constants.minimum_sample then null
              when eligible.peer_count = 1 or eligible.efficiency_spread = 1
                then 50::numeric
              else eligible.efficiency_peer end as adjusted_efficiency
      from aggregates
      cross join constants
      left join eligible using (employee_id)
    ), final_scores as (
      select scored.*,
        case when scored.valid_timing_count < constants.minimum_sample then null
        else
          constants.on_time_weight * scored.on_time_rate
          + constants.throughput_weight * scored.adjusted_throughput
          + constants.efficiency_weight * scored.adjusted_efficiency
          + constants.reliability_weight * (100 - scored.delay_rate)
        end as score
      from scored cross join constants
    ), enriched as (
      select final_scores.*,
        exists (
          select 1 from public.staff_presence presence
          where presence.user_id = final_scores.employee_id
            and presence.location_id = v_session.location_id::text
            and lower(presence.user_role) = 'helper'
            and presence.is_online = true
            and presence.last_seen_at >= now() - interval '2 minutes'
        ) as is_active,
        (select count(*)::integer
         from public.orders active_order
         where active_order.location_id = v_session.location_id
           and lower(active_order.status) = 'pending'
            and active_order.assigned_helper_id = final_scores.employee_id
        ) as current_workload
      from final_scores
    )
    select jsonb_build_object(
      'role', 'helper',
      'total_store_orders', totals.total_store_orders,
      'total_role_handled_orders', totals.total_role_handled_orders,
      'total_role_workload_points', totals.total_role_workload_points,
      'unattributed_order_count', totals.unattributed_order_count,
      'total_valid_timing_count', totals.total_valid_timing_count,
      'total_excluded_timing_count', totals.total_excluded_timing_count,
      'active_hours_available', false,
      'total_role_active_hours', null,
      'location_complexity_coverage',
        'Current product map locations when the product reference still resolves',
      'records', coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', employee_id,
        'employee_name', employee_name,
        'is_active', is_active,
        'completed_count', completed_count,
        'order_share', case when totals.total_store_orders = 0 then 0
          else 100.0 * completed_count / totals.total_store_orders end,
        'valid_timing_count', valid_timing_count,
        'excluded_timing_count', excluded_timing_count,
        'workload_points', workload_points,
        'workload_share', case when totals.total_role_workload_points = 0 then 0
          else 100.0 * workload_points / totals.total_role_workload_points end,
        'on_time_count', on_time_count,
        'total_service_minutes', total_service_minutes,
        'timed_workload_points', timed_workload_points,
        'average_minutes', average_minutes,
        'median_minutes', median_minutes,
        'fastest_minutes', fastest_minutes,
        'on_time_rate', on_time_rate,
        'delayed_count', delayed_count,
        'delay_rate', delay_rate,
        'reliability', 100 - delay_rate,
        'efficiency', efficiency,
        'adjusted_throughput', adjusted_throughput,
        'adjusted_efficiency', adjusted_efficiency,
        'active_hours', null,
        'active_time_share', null,
        'contribution_index', null,
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
      ) order by score desc nulls last, employee_name)
        filter (where employee_id is not null), '[]'::jsonb)
    ) into v_result
    from period_totals totals
    left join enriched on true
    group by totals.total_store_orders, totals.total_role_handled_orders,
      totals.total_role_workload_points, totals.unattributed_order_count,
      totals.total_valid_timing_count, totals.total_excluded_timing_count;
  else
    with constants as (
      select 15.0::numeric as delay_minutes,
             5::integer as minimum_sample,
             0.40::numeric as on_time_weight,
             0.30::numeric as throughput_weight,
             0.20::numeric as efficiency_weight,
             0.10::numeric as reliability_weight
    ), period_orders as (
      select
        history.order_id,
        nullif(trim(history.completed_by_id), '') as employee_id,
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
               and approval.used_order_id::text = history.order_id
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
    ), completed_orders as (
      select * from period_orders where employee_id is not null
    ), period_totals as (
      select
        count(*)::integer as total_store_orders,
        count(*) filter (where employee_id is not null)::integer
          as total_role_handled_orders,
        coalesce(sum(complexity_points) filter (
          where employee_id is not null
        ), 0)::numeric as total_role_workload_points,
        count(*) filter (where employee_id is null)::integer
          as unattributed_order_count,
        count(duration_minutes) filter (where employee_id is not null)::integer
          as total_valid_timing_count,
        count(*) filter (
          where employee_id is not null and duration_minutes is null
        )::integer as total_excluded_timing_count
      from period_orders
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
        coalesce(sum(completed.duration_minutes), 0)::numeric
          as total_service_minutes,
        coalesce(sum(completed.complexity_points) filter (
          where completed.duration_minutes is not null
        ), 0)::numeric as timed_workload_points,
        avg(completed.duration_minutes)::numeric as average_minutes,
        (percentile_cont(0.5) within group
          (order by completed.duration_minutes))::numeric as median_minutes,
        min(completed.duration_minutes)::numeric as fastest_minutes,
        count(*) filter (
          where completed.duration_minutes < constants.delay_minutes
        )::integer as on_time_count,
        count(*) filter (
          where completed.duration_minutes >= constants.delay_minutes
        )::integer as delayed_count,
        case when count(completed.duration_minutes) = 0 then 0 else
          100.0 * count(*) filter (
            where completed.duration_minutes < constants.delay_minutes
          ) / count(completed.duration_minutes)
        end::numeric as on_time_rate,
        case when count(completed.duration_minutes) = 0 then 0 else
          100.0 * count(*) filter (
            where completed.duration_minutes >= constants.delay_minutes
          ) / count(completed.duration_minutes)
        end::numeric as delay_rate,
        case when coalesce(sum(completed.duration_minutes), 0) <= 0 then null
             else
               (sum(completed.complexity_points) filter (
                 where completed.duration_minutes is not null
               )) / sum(completed.duration_minutes) end as efficiency,
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
              when eligible.peer_count = 1 or eligible.workload_spread = 1
                then 50::numeric
              else eligible.throughput_peer end as adjusted_throughput,
         case when aggregates.valid_timing_count < constants.minimum_sample then null
              when eligible.peer_count = 1 or eligible.efficiency_spread = 1
                then 50::numeric
              else eligible.efficiency_peer end as adjusted_efficiency
      from aggregates
      cross join constants
      left join eligible using (employee_id)
    ), final_scores as (
      select scored.*,
        case when scored.valid_timing_count < constants.minimum_sample then null
        else
          constants.on_time_weight * scored.on_time_rate
          + constants.throughput_weight * scored.adjusted_throughput
          + constants.efficiency_weight * scored.adjusted_efficiency
          + constants.reliability_weight * (100 - scored.delay_rate)
        end as score
      from scored cross join constants
    ), enriched as (
      select final_scores.*,
        exists (
          select 1 from public.staff_presence presence
          where presence.user_id = final_scores.employee_id
            and presence.location_id = v_session.location_id::text
            and lower(presence.user_role) in ('staff', 'cashier')
            and presence.is_online = true
            and presence.last_seen_at >= now() - interval '2 minutes'
        ) as is_active,
        coalesce(approval_counts.request_count, 0) as approval_requests,
        coalesce(approval_counts.approved_count, 0) as approvals_approved,
        coalesce(approval_counts.rejected_count, 0) as approvals_rejected,
        coalesce(approval_counts.pending_count, 0) as approvals_pending
      from final_scores
      left join approval_counts using (employee_id)
    )
    select jsonb_build_object(
      'role', 'cashier',
      'total_store_orders', totals.total_store_orders,
      'total_role_handled_orders', totals.total_role_handled_orders,
      'total_role_workload_points', totals.total_role_workload_points,
      'unattributed_order_count', totals.unattributed_order_count,
      'total_valid_timing_count', totals.total_valid_timing_count,
      'total_excluded_timing_count', totals.total_excluded_timing_count,
      'active_hours_available', false,
      'total_role_active_hours', null,
      'location_complexity_coverage', 'Not used for Cashier scoring',
      'records', coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', employee_id,
        'employee_name', employee_name,
        'is_active', is_active,
        'completed_count', completed_count,
        'order_share', case when totals.total_store_orders = 0 then 0
          else 100.0 * completed_count / totals.total_store_orders end,
        'valid_timing_count', valid_timing_count,
        'excluded_timing_count', excluded_timing_count,
        'workload_points', workload_points,
        'workload_share', case when totals.total_role_workload_points = 0 then 0
          else 100.0 * workload_points / totals.total_role_workload_points end,
        'on_time_count', on_time_count,
        'total_service_minutes', total_service_minutes,
        'timed_workload_points', timed_workload_points,
        'average_minutes', average_minutes,
        'median_minutes', median_minutes,
        'fastest_minutes', fastest_minutes,
        'on_time_rate', on_time_rate,
        'delayed_count', delayed_count,
        'delay_rate', delay_rate,
        'reliability', 100 - delay_rate,
        'efficiency', efficiency,
        'adjusted_throughput', adjusted_throughput,
        'adjusted_efficiency', adjusted_efficiency,
        'active_hours', null,
        'active_time_share', null,
        'contribution_index', null,
        'current_workload', 0,
        'sales_handled', sales_handled,
        'discounted_transactions', discounted_transactions,
        'discount_usage_rate', case when completed_count = 0 then 0
          else 100.0 * discounted_transactions / completed_count end,
        'discount_approval_requests', approval_requests,
        'discount_approvals_approved', approvals_approved,
        'discount_approvals_rejected', approvals_rejected,
        'discount_approvals_pending', approvals_pending,
        'score', score,
        'peer_count', peer_count
      ) order by score desc nulls last, employee_name)
        filter (where employee_id is not null), '[]'::jsonb)
    ) into v_result
    from period_totals totals
    left join enriched on true
    group by totals.total_store_orders, totals.total_role_handled_orders,
      totals.total_role_workload_points, totals.unattributed_order_count,
      totals.total_valid_timing_count, totals.total_excluded_timing_count;
  end if;

  return coalesce(v_result, jsonb_build_object(
    'role', v_role,
    'total_store_orders', 0,
    'total_role_handled_orders', 0,
    'total_role_workload_points', 0,
    'unattributed_order_count', 0,
    'total_valid_timing_count', 0,
    'total_excluded_timing_count', 0,
    'active_hours_available', false,
    'total_role_active_hours', null,
    'records', '[]'::jsonb
  ));
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."staff_performance_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."staff_performance_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."staff_performance_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."staff_performance_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."staff_performance_v1"(text, text, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "authenticated";
