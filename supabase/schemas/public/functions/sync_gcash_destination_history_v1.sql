create or replace function public.sync_gcash_destination_history_v1()
returns trigger language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  update public.order_history set
    gcash_destination_slot = new.gcash_destination_slot,
    gcash_destination_name = new.gcash_destination_name,
    gcash_destination_number = new.gcash_destination_number
  where order_id = new.id::text;
  return new;
end;
$function$;

revoke all on function public.sync_gcash_destination_history_v1()
  from public, anon, authenticated;
grant execute on function public.sync_gcash_destination_history_v1()
  to service_role, postgres;
