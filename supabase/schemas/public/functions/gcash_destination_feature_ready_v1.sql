create or replace function public.gcash_destination_feature_ready_v1()
returns boolean language sql stable
set search_path to 'public', 'pg_temp'
as $function$ select true $function$;

grant execute on function public.gcash_destination_feature_ready_v1()
  to anon, authenticated, service_role, postgres;
