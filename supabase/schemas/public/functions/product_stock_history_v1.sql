CREATE OR REPLACE FUNCTION public.product_stock_history_v1 (
  p_session_token text,
  p_product_id uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
  AS $function$
declare
  v_actor record;
  v_history jsonb;
begin
  select * into v_actor
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Stock history session is invalid or expired'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', movement.id,
    'created_at', movement.created_at,
    'product_id', movement.product_id,
    'transaction_type', movement.transaction_type,
    'quantity_change', movement.quantity_change,
    'new_quantity', movement.new_quantity,
    'user_name', movement.user_name,
    'note', movement.note,
    'profiles', case when actor.id is null then null else
      jsonb_build_object('name', actor.name, 'role', actor.role) end
  ) order by movement.created_at desc, movement.id desc), '[]'::jsonb)
  into v_history
  from public.transaction_history movement
  join public.products product on product.id = movement.product_id
    and product.location_id = v_actor.location_id
  left join public.profiles actor on actor.id = movement.user_id
  where movement.product_id = p_product_id
    and movement.location_id = v_actor.location_id;

  return v_history;
end;
$function$;

REVOKE ALL ON FUNCTION public.product_stock_history_v1(text, uuid)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.product_stock_history_v1(text, uuid)
  TO anon, service_role, postgres;
