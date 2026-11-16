  -- Apply after phase_password_recovery_questions.sql.
  begin;

  create or replace function public.password_recovery_questions_status_v1(p_session_token text)
  returns text[]
  language plpgsql stable security definer
  set search_path to 'public', 'private', 'extensions', 'pg_temp'
  as $function$
  declare
    v_profile record;
    v_ids text[];
  begin
    select * into v_profile from private.require_app_session_v1(p_session_token);
    if not found or v_profile.role <> 'admin' then return array[]::text[]; end if;
    select coalesce(array_agg(question_id order by question_id), array[]::text[])
    into v_ids
    from private.password_recovery_questions
    where profile_id = v_profile.profile_id;
    return v_ids;
  end;
  $function$;

  revoke all on function public.password_recovery_questions_status_v1(text)
    from public, authenticated;
  grant execute on function public.password_recovery_questions_status_v1(text)
    to anon, service_role;

  commit;
  notify pgrst, 'reload schema';
