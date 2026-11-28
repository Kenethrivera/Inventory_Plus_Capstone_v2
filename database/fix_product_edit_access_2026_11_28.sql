-- Save all product detail fields through the existing app-session authorization.
-- Apply before deploying the Flutter client that calls product_details_update_v4.

create or replace function public.product_details_update_v4(
  p_session_token text, p_product_id uuid, p_product_name text,
  p_sku text, p_product_price numeric, p_description text,
  p_manufacturer text, p_model text, p_product_size text,
  p_shelf_level text, p_bin_number text, p_image_url text,
  p_unit text, p_max_quantity numeric, p_requires_loading boolean,
  p_color text, p_category text, p_map_element_id text
) returns boolean language plpgsql volatile security definer
set search_path = public, private, extensions, pg_temp as $$
declare
  v_saved boolean;
begin
  if length(coalesce(p_category, '')) > 200
     or length(coalesce(p_map_element_id, '')) > 200 then
    raise exception 'invalid_product_input' using errcode = '22023';
  end if;

  -- v3 checks the app session, Admin role, product location and detail input.
  v_saved := public.product_details_update_v3(
    p_session_token, p_product_id, p_product_name, p_sku,
    p_product_price, p_description, p_manufacturer, p_model,
    p_product_size, p_shelf_level, p_bin_number, p_image_url,
    p_unit, p_max_quantity, p_requires_loading, p_color
  );
  if v_saved is not true then return false; end if;

  update public.products
  set category = nullif(btrim(p_category), ''),
      map_element_id = nullif(btrim(p_map_element_id), '')
  where id = p_product_id;
  if not found then
    raise exception 'product_not_found' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

revoke all on function public.product_details_update_v4(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean, text, text, text
) from public, authenticated;
grant execute on function public.product_details_update_v4(
  text, uuid, text, text, numeric, text, text, text, text, text,
  text, text, text, numeric, boolean, text, text, text
) to anon, service_role;
