CREATE OR REPLACE FUNCTION public.my_inventory_approval_requests_v1 (
  p_session_token text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_records jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Approval session is invalid or expired';
  end if;
  if v_profile.role not in ('helper', 'staff', 'cashier') then
    raise exception 'Only Cashier or Helper accounts may view requests';
  end if;

  select coalesce(jsonb_agg(private.approval_request_json_v1(scoped.row_value)
    order by scoped.requested_at desc, scoped.id desc), '[]'::jsonb)
  into v_records
  from (
    select request as row_value, request.requested_at, request.id
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.requested_by_id = v_profile.profile_id
      and request.request_type in ('restock', 'write_off')
    order by request.requested_at desc, request.id desc
    limit 30
  ) scoped;

  return v_records;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.my_inventory_approval_requests_v1(text)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.my_inventory_approval_requests_v1(text)
  FROM PUBLIC, authenticated;
