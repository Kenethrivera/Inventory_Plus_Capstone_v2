CREATE OR REPLACE FUNCTION public.approval_requests_page_v1 (
  p_session_token text,
  p_status        text    DEFAULT 'pending'::text,
  p_page          integer DEFAULT 1,
  p_page_size     integer DEFAULT 20
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_status text := lower(trim(coalesce(p_status, 'pending')));
  v_page integer := least(greatest(coalesce(p_page, 1), 1), 10000);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
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
    and request.status = v_status;

  select coalesce(jsonb_agg(private.approval_request_json_v1(scoped.row_value)
      order by scoped.requested_at desc, scoped.id desc), '[]'::jsonb)
    into v_records
  from (
    select request as row_value, request.requested_at, request.id
    from public.approval_requests request
    where request.location_id = v_profile.location_id
      and request.status = v_status
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."approval_requests_page_v1"(text, text, integer, integer) TO "anon";

GRANT EXECUTE ON FUNCTION "public"."approval_requests_page_v1"(text, text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."approval_requests_page_v1"(text, text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."approval_requests_page_v1"(text, text, integer, integer) TO "postgres";

REVOKE ALL ON FUNCTION "public"."approval_requests_page_v1"(text, text, integer, integer) FROM PUBLIC, "authenticated";
