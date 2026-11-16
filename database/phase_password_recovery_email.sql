-- Apply after phase_password_recovery.sql to enable email OTP recovery.
begin;

alter table private.password_recovery_challenges
  drop constraint if exists password_recovery_challenges_channel_check;
alter table private.password_recovery_challenges
  add constraint password_recovery_challenges_channel_check
  check (channel in ('sms', 'email'));

create or replace function public.password_recovery_begin_v1(p_username text, p_channel text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile public.profiles%rowtype;
  v_channel text := lower(trim(coalesce(p_channel, '')));
  v_destination text;
  v_id uuid := extensions.gen_random_uuid();
  v_bytes bytea := extensions.gen_random_bytes(4);
  v_code text;
begin
  if v_channel not in ('sms', 'email') then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:' || trim(coalesce(p_username, '')), 0));
  select * into v_profile from public.profiles
  where username = trim(coalesce(p_username, '')) and role = 'admin' and is_active;
  if not found then return null; end if;
  v_destination := case when v_channel = 'email' then v_profile.email else v_profile.phone end;
  if nullif(trim(coalesce(v_destination, '')), '') is null then return null; end if;
  if exists (
    select 1 from private.password_recovery_challenges
    where profile_id = v_profile.id and created_at > now() - interval '60 seconds'
  ) or (
    select count(*) from private.password_recovery_challenges
    where profile_id = v_profile.id and created_at > now() - interval '1 hour'
  ) >= 5 then return null; end if;

  v_code := lpad((mod(
    (get_byte(v_bytes, 0)::bigint << 24) +
    (get_byte(v_bytes, 1)::bigint << 16) +
    (get_byte(v_bytes, 2)::bigint << 8) +
    get_byte(v_bytes, 3)::bigint, 1000000
  ))::text, 6, '0');
  insert into private.password_recovery_challenges
    (id, profile_id, channel, code_hash, expires_at)
  values
    (v_id, v_profile.id, v_channel,
     extensions.digest(convert_to(v_id::text || ':' || v_code, 'UTF8'), 'sha256'),
     now() + interval '10 minutes');
  return jsonb_build_object('challenge_id', v_id, 'code', v_code, 'destination', v_destination);
end;
$function$;

commit;
notify pgrst, 'reload schema';
