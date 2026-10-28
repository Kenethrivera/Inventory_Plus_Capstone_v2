CREATE OR REPLACE FUNCTION public.upsert_notification_lifecycle_v1 (
  p_session_token  text,
  p_lifecycle_key  text,
  p_target_roles   text[],
  p_title          text,
  p_body           text,
  p_type           text,
  p_priority       text,
  p_payload        jsonb,
  p_created_at     timestamp with time zone DEFAULT now()
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_notification_id uuid;
  v_notification public.notifications;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Notification session is invalid or expired'; end if;

  v_notification_id := private.upsert_notification_lifecycle_v1(
    v_profile.location_id::text,
    nullif(trim(coalesce(p_lifecycle_key, '')), ''),
    p_target_roles,
    p_title,
    p_body,
    p_type,
    p_priority,
    p_payload,
    p_created_at
  );
  select notification.* into v_notification
  from public.notifications notification
  where notification.id = v_notification_id;
  return to_jsonb(v_notification);
end;
$function$;

GRANT EXECUTE ON FUNCTION public.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.upsert_notification_lifecycle_v1(
  text, text, text[], text, text, text, text, jsonb,
  timestamp with time zone
) FROM PUBLIC, authenticated;
