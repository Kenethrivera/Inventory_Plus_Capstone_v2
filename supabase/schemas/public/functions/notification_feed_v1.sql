CREATE OR REPLACE FUNCTION public.notification_feed_v1 (
  p_session_token text,
  p_archived boolean DEFAULT false
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
  v_feed jsonb;
begin
  select * into v_actor from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Notification session is invalid or expired'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(
    to_jsonb(notification) || jsonb_build_object(
      'read_state', case when read_state.id is null then null
        else to_jsonb(read_state) end
    ) order by notification.created_at desc, notification.id desc
  ), '[]'::jsonb)
  into v_feed
  from public.notifications notification
  left join public.notification_reads read_state
    on read_state.notification_id = notification.id
    and read_state.user_id = v_actor.profile_id::text
  where notification.location_id = v_actor.location_id::text
    and v_actor.role = any(notification.target_roles)
    and (
      (coalesce(p_archived, false) and read_state.is_deleted = true)
      or (not coalesce(p_archived, false)
        and notification.is_resolved = false
        and coalesce(read_state.is_deleted, false) = false)
    )
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
      or notification.payload ->> 'recipientId' = v_actor.profile_id::text);

  return v_feed;
end;
$function$;

REVOKE ALL ON FUNCTION public.notification_feed_v1(text, boolean)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.notification_feed_v1(text, boolean)
  TO anon, service_role, postgres;
