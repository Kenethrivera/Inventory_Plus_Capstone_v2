CREATE OR REPLACE FUNCTION private.order_complexity_v1 (
  p_items                 jsonb,
  p_location_id           uuid,
  p_include_location      boolean,
  p_payment_mode          text    DEFAULT NULL::text,
  p_discount_amount       numeric DEFAULT 0,
  p_has_discount_approval boolean DEFAULT false
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'private', 'pg_temp'
  AS $function$
  -- V1 constants live together here for straightforward formula tuning.
  with constants as (
    select 1.0::numeric as base_points,
           1.0::numeric as line_points,
           0.50::numeric as location_step,
           0.50::numeric as gcash_points,
           0.50::numeric as discount_points,
           1.00::numeric as approval_points
  ), raw_lines as (
    select
      coalesce(
        nullif(trim(item.value ->> 'product_id'), ''),
        nullif(trim(item.value ->> 'productId'), ''),
        'name:' || coalesce(
          nullif(trim(item.value ->> 'product_name'), ''),
          nullif(trim(item.value ->> 'productName'), ''),
          item.ordinality::text
        )
      ) as line_key,
      coalesce(
        nullif(trim(item.value ->> 'product_id'), ''),
        nullif(trim(item.value ->> 'productId'), '')
      ) as product_id,
      case
        when trim(coalesce(item.value ->> 'quantity', '')) ~
             '^[+]?[0-9]+([.][0-9]+)?$'
          then greatest((item.value ->> 'quantity')::numeric, 0)
        else 0
      end as quantity
    from jsonb_array_elements(
      case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end
    ) with ordinality as item(value, ordinality)
  ), lines as (
    select line_key, max(product_id) as product_id, sum(quantity) as quantity
    from raw_lines
    group by line_key
  ), item_factors as (
    select
      count(*)::numeric as line_count,
      coalesce(sum(case
        when quantity <= 1 then 0
        when quantity <= 5 then 0.25
        when quantity <= 10 then 0.50
        when quantity <= 20 then 0.75
        else 1.00
      end), 0)::numeric as quantity_burden
    from lines
  ), location_factor as (
    select case when p_include_location then
      greatest(count(distinct nullif(trim(product.map_element_id), '')) - 1, 0)
        * (select location_step from constants)
    else 0 end::numeric as burden
    from lines
    left join public.products product
      on product.id::text = lines.product_id
     and product.location_id = p_location_id
  )
  select round(
    constants.base_points
    + item_factors.line_count * constants.line_points
    + item_factors.quantity_burden
    + location_factor.burden
    + case when lower(trim(coalesce(p_payment_mode, ''))) = 'gcash'
           then constants.gcash_points else 0 end
    + case when coalesce(p_discount_amount, 0) > 0
           then constants.discount_points else 0 end
    + case when p_has_discount_approval
           then constants.approval_points else 0 end,
    2
  )
  from constants cross join item_factors cross join location_factor
$function$;

REVOKE ALL ON FUNCTION "private"."order_complexity_v1"(jsonb, uuid, boolean, text, numeric, boolean) FROM PUBLIC;
