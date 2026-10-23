CREATE OR REPLACE FUNCTION public.signal_approval_request_change_v1()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
  AS $function$
declare
  v_location_id uuid;
begin
  if tg_op = 'UPDATE'
     and old.location_id is distinct from new.location_id then
    insert into public.approval_request_realtime_signals (
      location_id, revision, changed_at
    ) values (old.location_id, 1, clock_timestamp())
    on conflict (location_id) do update set
      revision = public.approval_request_realtime_signals.revision + 1,
      changed_at = excluded.changed_at;
  end if;

  v_location_id := case when tg_op = 'DELETE'
    then old.location_id else new.location_id end;

  insert into public.approval_request_realtime_signals (
    location_id, revision, changed_at
  ) values (v_location_id, 1, clock_timestamp())
  on conflict (location_id) do update set
    revision = public.approval_request_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."signal_approval_request_change_v1"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."signal_approval_request_change_v1"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."signal_approval_request_change_v1"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."signal_approval_request_change_v1"() FROM PUBLIC, "anon", "authenticated";
