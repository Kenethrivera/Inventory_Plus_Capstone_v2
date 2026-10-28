CREATE OR REPLACE FUNCTION public.save_store_map_v1 (
  p_session_token   text,
  p_expected_layout jsonb,
  p_new_layout      jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_layout jsonb;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Map session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then raise exception 'map_save_not_allowed'; end if;
  if p_expected_layout is not null and jsonb_typeof(p_expected_layout) <> 'array' then
    raise exception 'map_layout_invalid';
  end if;
  if p_new_layout is not null and jsonb_typeof(p_new_layout) <> 'array' then
    raise exception 'map_layout_invalid';
  end if;

  update public.locations location
  set layout_data = p_new_layout
  where location.id = v_profile.location_id
    and coalesce(location.layout_data, '[]'::jsonb)
      = coalesce(p_expected_layout, '[]'::jsonb)
  returning location.layout_data into v_layout;

  if found then
    return jsonb_build_object(
      'status', 'saved',
      'layout_data', coalesce(v_layout, '[]'::jsonb)
    );
  end if;

  select coalesce(location.layout_data, '[]'::jsonb) into v_layout
  from public.locations location
  where location.id = v_profile.location_id;
  if not found then raise exception 'map_location_not_found'; end if;
  return jsonb_build_object('status', 'conflict', 'layout_data', v_layout);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.save_store_map_v1(text, jsonb, jsonb)
  TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.save_store_map_v1(text, jsonb, jsonb)
  FROM PUBLIC, authenticated;
