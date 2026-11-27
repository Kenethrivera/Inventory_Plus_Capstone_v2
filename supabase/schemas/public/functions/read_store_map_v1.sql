CREATE OR REPLACE FUNCTION public.read_store_map_v1 (
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
  v_layout jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Map session is invalid or expired' using errcode = '28000';
  end if;

  select coalesce(location.layout_data, '[]'::jsonb) into v_layout
  from public.locations location
  where location.id = v_profile.location_id;
  if not found then raise exception 'map_location_not_found'; end if;

  return v_layout;
end;
$function$;

REVOKE ALL ON FUNCTION public.read_store_map_v1(text)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.read_store_map_v1(text)
  TO anon, service_role, postgres;
