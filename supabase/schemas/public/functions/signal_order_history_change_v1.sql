CREATE OR REPLACE FUNCTION public.signal_order_history_change_v1()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
  AS $function$
declare
  v_location_id uuid;
begin
  -- If an order is ever moved between locations, invalidate both families.
  if tg_op = 'UPDATE'
     and old.location_id is distinct from new.location_id then
    insert into public.order_history_realtime_signals (
      location_id,
      revision,
      changed_at
    ) values (
      old.location_id,
      1,
      clock_timestamp()
    )
    on conflict (location_id) do update set
      revision = public.order_history_realtime_signals.revision + 1,
      changed_at = excluded.changed_at;
  end if;

  if tg_op = 'DELETE' then
    v_location_id := old.location_id;
  else
    v_location_id := new.location_id;
  end if;

  insert into public.order_history_realtime_signals (
    location_id,
    revision,
    changed_at
  ) values (
    v_location_id,
    1,
    clock_timestamp()
  )
  on conflict (location_id) do update set
    revision = public.order_history_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."signal_order_history_change_v1"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."signal_order_history_change_v1"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."signal_order_history_change_v1"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."signal_order_history_change_v1"() FROM PUBLIC, "anon", "authenticated";
