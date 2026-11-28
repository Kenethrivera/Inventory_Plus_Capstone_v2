CREATE OR REPLACE FUNCTION public.notification_user_action_v1 (
  p_session_token text,
  p_notification_ids text[],
  p_action text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
  v_count integer;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Notification session is invalid or expired'
      using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('read', 'archive')
      or coalesce(array_length(p_notification_ids, 1), 0) > 1000 then
    raise exception 'Invalid notification action' using errcode = '22023';
  end if;

  with eligible as (
    select notification.id
    from public.notifications notification
    where notification.id::text = any(coalesce(p_notification_ids, '{}'::text[]))
      and notification.location_id = v_actor.location_id::text
      and v_actor.role = any(notification.target_roles)
      and (v_actor.role <> 'helper'
        or notification.type <> 'orderAssigned'
        or notification.payload ->> 'helperId' is null
        or notification.payload ->> 'helperId' = v_actor.profile_id::text)
      and (v_actor.role <> 'bodegero'
        or notification.type <> 'orderAssigned'
        or notification.payload ->> 'bodegeroId' is null
        or notification.payload ->> 'bodegeroId' = v_actor.profile_id::text)
      and (notification.payload ->> 'category' is distinct from 'inventoryApproval'
        or nullif(notification.payload ->> 'recipientId', '') is null
        or notification.payload ->> 'recipientId' = v_actor.profile_id::text)
  )
  insert into public.notification_reads as read_state (
    notification_id, user_id, is_read, read_at, is_deleted, deleted_at
  )
  select eligible.id, v_actor.profile_id::text, true, now(),
    p_action = 'archive',
    case when p_action = 'archive' then now() else null end
  from eligible
  on conflict (notification_id, user_id) do update set
    is_read = true,
    read_at = coalesce(read_state.read_at, now()),
    is_deleted = read_state.is_deleted or p_action = 'archive',
    deleted_at = case when p_action = 'archive'
      then coalesce(read_state.deleted_at, now())
      else read_state.deleted_at end;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

REVOKE ALL ON FUNCTION public.notification_user_action_v1(text, text[], text)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.notification_user_action_v1(text, text[], text)
  TO anon, service_role, postgres;
