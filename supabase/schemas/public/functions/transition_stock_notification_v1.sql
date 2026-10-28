CREATE OR REPLACE FUNCTION public.transition_stock_notification_v1 (
  p_session_token text,
  p_item_id       text,
  p_status        text,
  p_title         text,
  p_body          text,
  p_type          text,
  p_priority      text,
  p_payload       jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_profile record;
  v_state public.stock_notification_states;
  v_item_id text := nullif(trim(coalesce(p_item_id, '')), '');
  v_status text := lower(trim(coalesce(p_status, '')));
  v_lifecycle_key text;
  v_changed boolean;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then raise exception 'Notification session is invalid or expired'; end if;
  if v_item_id is null or v_status not in ('ok', 'low', 'critical', 'dead') then
    raise exception 'stock_notification_transition_invalid';
  end if;
  v_lifecycle_key := 'stock-alert:admin:' || v_item_id;

  perform pg_advisory_xact_lock(hashtextextended(
    'stock-notification:' || v_profile.location_id::text || ':' || v_item_id,
    0
  ));
  select state.* into v_state
  from public.stock_notification_states state
  where state.location_id = v_profile.location_id::text
    and state.item_id = v_item_id
  for update;

  if not found then
    insert into public.stock_notification_states (
      location_id, item_id, last_status, updated_at
    ) values (
      v_profile.location_id::text, v_item_id, v_status, now()
    );
    return jsonb_build_object(
      'initialized', true,
      'changed', false,
      'status', v_status
    );
  end if;

  v_changed := v_state.last_status is distinct from v_status;
  if v_status = 'ok' then
    update public.notifications notification
    set is_resolved = true,
        resolved_at = now()
    where notification.location_id = v_profile.location_id::text
      and notification.lifecycle_key = v_lifecycle_key
      and notification.is_resolved = false;
  else
    if p_title is null or p_body is null or p_type is null
        or p_priority is null or p_payload is null then
      raise exception 'stock_notification_payload_invalid';
    end if;
    if v_changed then
      perform private.upsert_notification_lifecycle_v1(
        v_profile.location_id::text,
        v_lifecycle_key,
        array['admin']::text[],
        p_title,
        p_body,
        p_type,
        p_priority,
        p_payload,
        now()
      );
    else
      update public.notifications notification
      set target_roles = array['admin']::text[],
          title = p_title,
          body = p_body,
          type = p_type,
          priority = p_priority,
          payload = p_payload
      where notification.location_id = v_profile.location_id::text
        and notification.lifecycle_key = v_lifecycle_key
        and notification.is_resolved = false;
    end if;
  end if;

  update public.stock_notification_states state
  set last_status = v_status,
      updated_at = now()
  where state.id = v_state.id;
  return jsonb_build_object(
    'initialized', false,
    'changed', v_changed,
    'status', v_status
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.transition_stock_notification_v1(
  text, text, text, text, text, text, text, jsonb
) TO anon, service_role, postgres;
REVOKE ALL ON FUNCTION public.transition_stock_notification_v1(
  text, text, text, text, text, text, text, jsonb
) FROM PUBLIC, authenticated;
