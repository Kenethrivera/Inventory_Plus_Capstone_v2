CREATE OR REPLACE FUNCTION public.password_recovery_begin_v1(p_username text, p_channel text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_profile public.profiles%rowtype;
  v_channel text := lower(trim(coalesce(p_channel, '')));
  v_id uuid := extensions.gen_random_uuid();
  v_bytes bytea := extensions.gen_random_bytes(4);
  v_code text;
begin
  if v_channel <> 'sms' then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:' || trim(coalesce(p_username, '')), 0));
  select * into v_profile from public.profiles
  where username = trim(coalesce(p_username, '')) and role = 'admin'
    and is_active and nullif(trim(coalesce(phone, '')), '') is not null;
  if not found then return null; end if;
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
  return jsonb_build_object('challenge_id', v_id, 'code', v_code, 'destination', v_profile.phone);
end;
$function$;

CREATE OR REPLACE FUNCTION public.password_recovery_verify_v1(
  p_challenge_id uuid, p_code text
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_challenge private.password_recovery_challenges%rowtype;
  v_token text;
begin
  select * into v_challenge from private.password_recovery_challenges
  where id = p_challenge_id for update;
  if not found or v_challenge.consumed_at is not null or
     v_challenge.verified_at is not null or v_challenge.expires_at <= now() or
     v_challenge.attempts >= 5 then return null; end if;
  update private.password_recovery_challenges
  set attempts = attempts + 1 where id = p_challenge_id;
  if length(coalesce(p_code, '')) <> 6 or
     extensions.digest(
       convert_to(p_challenge_id::text || ':' || p_code, 'UTF8'), 'sha256'
     ) <> v_challenge.code_hash then return null; end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  update private.password_recovery_challenges
  set verified_at = now(),
      reset_token_hash = extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'),
      reset_expires_at = now() + interval '5 minutes'
  where id = p_challenge_id;
  return v_token;
end;
$function$;

CREATE OR REPLACE FUNCTION public.password_recovery_complete_v1(
  p_reset_token text, p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_challenge private.password_recovery_challenges%rowtype;
  v_username text;
begin
  if length(coalesce(p_reset_token, '')) <> 64 or
     length(coalesce(p_new_password, '')) < 8 or
     p_new_password !~ '[A-Z]' or p_new_password !~ '[a-z]' or
     p_new_password !~ '[0-9]' or
     p_new_password !~ '[!@#$%^&*(),.?":{}|<>]' then return false; end if;
  select * into v_challenge from private.password_recovery_challenges
  where reset_token_hash = extensions.digest(
    convert_to(p_reset_token, 'UTF8'), 'sha256')
    and reset_expires_at > now() and consumed_at is null
  for update;
  if not found then return false; end if;
  update public.profiles
  set password = encode(extensions.digest(
    convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  where id = v_challenge.profile_id and role = 'admin' and is_active
  returning username into v_username;
  if not found then return false; end if;
  perform private.reset_auth_rate_limit_v1(
    'login', extensions.digest(
      convert_to('login:' || trim(v_username), 'UTF8'), 'sha256')
  );
  update private.password_recovery_challenges
  set consumed_at = now() where id = v_challenge.id;
  return true;
end;
$function$;

CREATE OR REPLACE FUNCTION public.password_recovery_cancel_v1(p_challenge_id uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
  update private.password_recovery_challenges
  set consumed_at = now() where id = p_challenge_id and consumed_at is null;
$function$;

REVOKE ALL ON FUNCTION public.password_recovery_begin_v1(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.password_recovery_verify_v1(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.password_recovery_complete_v1(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.password_recovery_cancel_v1(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.password_recovery_begin_v1(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.password_recovery_verify_v1(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.password_recovery_complete_v1(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.password_recovery_cancel_v1(uuid) TO service_role;
