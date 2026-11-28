CREATE OR REPLACE FUNCTION public.signal_staff_presence_change_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  insert into public.staff_presence_realtime_signals (id, revision, changed_at)
  values (true, 1, clock_timestamp())
  on conflict (id) do update set
    revision = public.staff_presence_realtime_signals.revision + 1,
    changed_at = excluded.changed_at;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

REVOKE ALL ON FUNCTION public.signal_staff_presence_change_v1()
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.signal_staff_presence_change_v1()
  TO "service_role", "postgres";
