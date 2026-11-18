create or replace function public.update_secondary_gcash_qr_v1(
  p_session_token text,
  p_gcash_qr_url text
) returns text language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_qr_url text;
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Settings session is invalid or expired'; end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may update payment settings';
  end if;
  v_qr_url := trim(coalesce(p_gcash_qr_url, ''));
  insert into public.store_settings (location_id, gcash_alt_qr_url)
  values (v_profile.location_id, v_qr_url)
  on conflict (location_id) do update set gcash_alt_qr_url = excluded.gcash_alt_qr_url;
  return v_qr_url;
end;
$function$;

grant execute on function public.update_secondary_gcash_qr_v1(text, text)
  to anon, service_role, postgres;
revoke all on function public.update_secondary_gcash_qr_v1(text, text)
  from public, authenticated;
