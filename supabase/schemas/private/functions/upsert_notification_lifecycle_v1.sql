CREATE OR REPLACE FUNCTION private.upsert_notification_lifecycle_v1 (
  p_location_id  text,
  p_lifecycle_key text,
  p_target_roles text[],
  p_title        text,
  p_body         text,
  p_type         text,
  p_priority     text,
  p_payload      jsonb,
  p_created_at   timestamp with time zone DEFAULT now()
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
declare
  v_notification public.notifications;
  v_old_stage text;
  v_new_stage text;
begin
  if nullif(trim(coalesce(p_location_id, '')), '') is null
      or nullif(trim(coalesce(p_lifecycle_key, '')), '') is null then
    raise exception 'notification_lifecycle_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'notification:' || p_location_id || ':' || p_lifecycle_key,
    0
  ));

  select notification.* into v_notification
  from public.notifications notification
  where notification.location_id = p_location_id
    and notification.lifecycle_key = p_lifecycle_key
    and notification.is_resolved = false
  for update;

  if found then
    v_old_stage := v_notification.type || ':' || coalesce(
      v_notification.payload ->> 'stage',
      v_notification.payload ->> 'status',
      ''
    );
    v_new_stage := p_type || ':' || coalesce(
      p_payload ->> 'stage',
      p_payload ->> 'status',
      ''
    );
    update public.notifications notification
    set target_roles = p_target_roles,
        title = p_title,
        body = p_body,
        type = p_type,
        priority = p_priority,
        payload = coalesce(p_payload, '{}'::jsonb),
        is_resolved = false,
        resolved_at = null
    where notification.id = v_notification.id;

    if v_old_stage is distinct from v_new_stage then
      update public.notification_reads
      set is_read = false,
          read_at = null,
          is_deleted = false,
          deleted_at = null
      where notification_id = v_notification.id;
    end if;
    return v_notification.id;
  end if;

  insert into public.notifications (
    location_id, target_roles, title, body, type, priority, payload,
    created_at, is_resolved, resolved_at, lifecycle_key
  ) values (
    p_location_id, p_target_roles, p_title, p_body, p_type, p_priority,
    coalesce(p_payload, '{}'::jsonb), coalesce(p_created_at, now()),
    false, null, p_lifecycle_key
  ) returning * into v_notification;
  return v_notification.id;
end;
$function$;

REVOKE ALL ON FUNCTION private.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) FROM PUBLIC;
