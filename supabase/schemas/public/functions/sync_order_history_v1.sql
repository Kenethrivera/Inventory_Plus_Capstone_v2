CREATE OR REPLACE FUNCTION public.sync_order_history_v1()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
  AS $function$
declare
  v_returned_by_name text;
begin
  if new.returned_by_id is not null then
    select profile.name
      into v_returned_by_name
      from public.profiles profile
     where profile.id::text = new.returned_by_id::text;
  end if;

  insert into public.order_history (
    order_id, location_id, status, items, created_at,
    assigned_at, prepared_at, completed_at, cancelled_at, returned_at,
    created_by_id, created_by_name,
    assigned_helper_id, assigned_helper_name,
    prepared_by_id, prepared_by_name,
    completed_by_id, completed_by_name,
    cancelled_by_id, cancelled_by_name,
    returned_by_id, returned_by_name,
    total_amount, discount_amount, payment_mode, payment_reference,
    cash_given, change_amount, snapshot_updated_at
  ) values (
    new.id::text, new.location_id, new.status,
    coalesce(new.items::jsonb, '[]'::jsonb), new.created_at,
    new.assigned_at, new.prepared_at, new.completed_at,
    new.cancelled_at, new.returned_at,
    new.created_by_id::text, new.created_by_name,
    new.assigned_helper_id::text, new.assigned_helper_name,
    new.prepared_by_id::text, new.prepared_by_name,
    new.completed_by_id::text, new.completed_by_name,
    new.cancelled_by_id::text, new.cancelled_by_name,
    new.returned_by_id::text, v_returned_by_name,
    coalesce(new.total_amount, 0), coalesce(new.discount_amount, 0),
    new.payment_mode, new.payment_reference, new.cash_given,
    new.change_amount, now()
  )
  on conflict (order_id) do update set
    location_id = excluded.location_id,
    status = excluded.status,
    items = excluded.items,
    created_at = excluded.created_at,
    assigned_at = excluded.assigned_at,
    prepared_at = excluded.prepared_at,
    completed_at = excluded.completed_at,
    cancelled_at = excluded.cancelled_at,
    returned_at = excluded.returned_at,
    created_by_id = excluded.created_by_id,
    created_by_name = excluded.created_by_name,
    assigned_helper_id = excluded.assigned_helper_id,
    assigned_helper_name = excluded.assigned_helper_name,
    prepared_by_id = excluded.prepared_by_id,
    prepared_by_name = excluded.prepared_by_name,
    completed_by_id = excluded.completed_by_id,
    completed_by_name = excluded.completed_by_name,
    cancelled_by_id = excluded.cancelled_by_id,
    cancelled_by_name = excluded.cancelled_by_name,
    returned_by_id = excluded.returned_by_id,
    returned_by_name = coalesce(
      excluded.returned_by_name, public.order_history.returned_by_name),
    total_amount = excluded.total_amount,
    discount_amount = excluded.discount_amount,
    payment_mode = excluded.payment_mode,
    payment_reference = excluded.payment_reference,
    cash_given = excluded.cash_given,
    change_amount = excluded.change_amount,
    snapshot_updated_at = excluded.snapshot_updated_at;

  return new;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."sync_order_history_v1"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."sync_order_history_v1"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."sync_order_history_v1"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."sync_order_history_v1"() FROM PUBLIC, "anon", "authenticated";
