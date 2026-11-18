-- Run after phase_2a_inventory_approvals.sql to enable date-filtered approval pages.
create or replace function public.approval_requests_page_v2(
  p_session_token text,
  p_status text default 'pending',
  p_page integer default 1,
  p_page_size integer default 10,
  p_requested_from timestamptz default null,
  p_requested_before timestamptz default null
) returns jsonb
language plpgsql stable security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_status text := lower(trim(coalesce(p_status, 'pending')));
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 100);
  v_total integer;
  v_records jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may review approval requests';
  end if;
  if v_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Unsupported approval status';
  end if;

  select count(*)::integer into v_total
  from public.approval_requests request
  where request.location_id = v_profile.location_id
    and request.status = v_status
    and (p_requested_from is null or request.requested_at >= p_requested_from)
    and (p_requested_before is null or request.requested_at < p_requested_before);

  select coalesce(jsonb_agg(private.approval_request_json_v1(scoped.row_value)
      order by scoped.requested_at desc, scoped.id desc), '[]'::jsonb)
    into v_records
  from (
    select request as row_value, request.requested_at, request.id
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.status = v_status
      and (p_requested_from is null or request.requested_at >= p_requested_from)
      and (p_requested_before is null or request.requested_at < p_requested_before)
    order by request.requested_at desc, request.id desc
    limit v_page_size
    offset ((v_page - 1)::bigint * v_page_size::bigint)
  ) scoped;

  return jsonb_build_object(
    'records', v_records,
    'total_count', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
end;
$$;

revoke all on function public.approval_requests_page_v2(
  text, text, integer, integer, timestamptz, timestamptz
) from public, authenticated;
grant execute on function public.approval_requests_page_v2(
  text, text, integer, integer, timestamptz, timestamptz
) to anon;
