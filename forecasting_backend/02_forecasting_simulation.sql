-- Run manually for existing SPRJ Paint Center (BINAN-001) after reviewing 01.
-- Data only. Backend models, recommendations, approvals and accuracy are not
-- fabricated here; invoke the existing FastAPI/worker workflows afterward.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('inventory-plus-forecast-simulation', 0));

CREATE TEMP TABLE sim_context ON COMMIT DROP AS
SELECT '11111111-1111-1111-1111-111111111111'::uuid AS location_id,
       COALESCE((SELECT min((completed_at AT TIME ZONE 'Asia/Manila')::date)+180
                 FROM public.orders
                 WHERE location_id='11111111-1111-1111-1111-111111111111'
                   AND completed_by_name='Forecast Simulation'),
                (now() AT TIME ZONE 'Asia/Manila')::date) AS anchor_date;

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.locations
                 WHERE id='11111111-1111-1111-1111-111111111111'
                   AND store_key='BINAN-001' AND location_name='SPRJ Paint Center') THEN
    RAISE EXCEPTION 'BINAN-001 identity mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE sku LIKE 'SIM-FC-%'
             AND (location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
                  OR description IS DISTINCT FROM 'Synthetic forecast fixture')) THEN
    RAISE EXCEPTION 'SIM-FC SKU identity conflict';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles
                 WHERE id=1 AND username='admin' AND role='admin'
                   AND location_id='11111111-1111-1111-1111-111111111111') THEN
    RAISE EXCEPTION 'existing BINAN-001 admin profile is unavailable';
  END IF;
END
$guard$;

CREATE TEMP TABLE sim_catalog(idx integer PRIMARY KEY, pattern text, category text,
                              stock numeric, product_id uuid) ON COMMIT DROP;
INSERT INTO sim_catalog(idx,pattern,category,stock,product_id)
SELECT v.idx,v.pattern,v.category,v.stock,
       md5('inventory-plus-sim-product:'||v.idx)::uuid
FROM (VALUES
 (0,'steady','General',12),(1,'increasing','Hand Tools',2),
 (2,'decreasing','Plumbing',3),(3,'intermittent','Power Tools',1),
 (4,'high','Fasteners',5),(5,'low','Safety',30),
 (6,'weekend','Paint',4),(7,'seasonal','Electrical',6),
 (8,'lumpy','Hardware',2),(9,'stable_high_stock','Hardware',500),
 (10,'recent','Tools',4),(11,'no_history','Tools',2)
) v(idx,pattern,category,stock);

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM sim_catalog c JOIN public.products p
             ON p.id=c.product_id OR p.sku='SIM-FC-'||lpad(c.idx::text,2,'0')
             WHERE p.location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
                OR p.id<>c.product_id OR p.sku<>'SIM-FC-'||lpad(c.idx::text,2,'0')) THEN
    RAISE EXCEPTION 'deterministic simulation identity conflict';
  END IF;
END
$guard$;

INSERT INTO public.products(id,sku,product_name,category,product_price,
                            product_quantity,location_id,unit,max_quantity,is_active,description)
SELECT c.product_id,'SIM-FC-'||lpad(c.idx::text,2,'0'),
       'Simulation '||initcap(replace(c.pattern,'_',' ')),c.category,25+c.idx,
       c.stock,s.location_id,'pcs',1000,true,'Synthetic forecast fixture'
FROM sim_catalog c CROSS JOIN sim_context s WHERE true ON CONFLICT(id) DO NOTHING;

INSERT INTO public.forecast_replenishment_configs(
  product_id,location_id,supplier_lead_time_days,review_period_days,safety_stock,
  minimum_order_quantity,supplier_pack_size,supplier_order_unit,
  unit_conversion_factor,supplier_availability,data_source,source_captured_at,
  rationale,updated_by_profile_id)
SELECT c.product_id,s.location_id,5+c.idx%4,7,2+c.idx%3,1,1,'pcs',1,
       'available','admin_estimate',now(),'Synthetic simulation assumption',p.id
FROM sim_catalog c CROSS JOIN sim_context s
CROSS JOIN public.profiles p
WHERE p.id=1 AND p.username='admin' AND p.location_id=s.location_id
ON CONFLICT(product_id,location_id) DO NOTHING;

-- A deterministic calendar series with meaningful zero-sale days. The same
-- completed-order trigger used by the application creates order_history.
CREATE TEMP TABLE sim_sales ON COMMIT DROP AS
WITH calendar AS (
 SELECT c.*,s.anchor_date-180+g.n AS business_date,g.n AS day_index,
        get_byte(decode(md5('sale:'||c.idx||':'||g.n),'hex'),0) AS draw,
        get_byte(decode(md5('qty:'||c.idx||':'||g.n),'hex'),1) AS qty_draw,
        get_byte(decode(md5('lump:'||c.idx||':'||g.n),'hex'),2) AS lump_draw
 FROM sim_catalog c CROSS JOIN sim_context s CROSS JOIN generate_series(0,179) g(n)
), demand AS (
 SELECT *,CASE
   WHEN pattern='no_history' OR (pattern='recent' AND day_index<166) THEN 0
   WHEN draw >= CASE pattern WHEN 'steady' THEN 220 WHEN 'increasing' THEN 213
     WHEN 'decreasing' THEN 207 WHEN 'intermittent' THEN 77 WHEN 'high' THEN 246
     WHEN 'low' THEN 161 WHEN 'weekend' THEN 205 WHEN 'seasonal' THEN 210
     WHEN 'lumpy' THEN 123 WHEN 'stable_high_stock' THEN 220 ELSE 205 END THEN 0
   ELSE greatest(1,(CASE pattern
     WHEN 'steady' THEN 3 WHEN 'increasing' THEN 1+day_index/38
     WHEN 'decreasing' THEN greatest(1,6-day_index/38)
     WHEN 'intermittent' THEN 1 WHEN 'high' THEN 10 WHEN 'low' THEN 1
     WHEN 'weekend' THEN CASE WHEN extract(isodow FROM business_date)>=6 THEN 6 ELSE 2 END
     WHEN 'seasonal' THEN CASE WHEN extract(month FROM business_date) IN (11,12,3,4) THEN 5 ELSE 2 END
     WHEN 'lumpy' THEN CASE WHEN lump_draw<56 THEN 8 ELSE 1 END
     WHEN 'stable_high_stock' THEN 3 ELSE 2 END)+(qty_draw%3)-1)
 END::integer AS quantity
 FROM calendar
)
SELECT *,md5('inventory-plus-sim-order:'||business_date||':'||idx)::uuid AS order_id,
       (business_date+time '13:00') AT TIME ZONE 'Asia/Manila' AS completed_time
FROM demand WHERE quantity>0;

DO $guard$
DECLARE sale_count integer;
BEGIN
  SELECT count(*) INTO sale_count FROM sim_sales;
  IF sale_count NOT BETWEEN 1000 AND 2000 THEN
    RAISE EXCEPTION 'generated % sales, expected 1000-2000',sale_count;
  END IF;
  IF EXISTS (SELECT 1 FROM sim_sales s JOIN public.orders o ON o.id=s.order_id
             WHERE o.location_id IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
                OR o.completed_by_name IS DISTINCT FROM 'Forecast Simulation') THEN
    RAISE EXCEPTION 'deterministic order ID collides outside simulation scope';
  END IF;
  IF EXISTS (SELECT 1 FROM public.orders o
             WHERE o.location_id='11111111-1111-1111-1111-111111111111'
               AND o.completed_by_name='Forecast Simulation'
               AND NOT EXISTS (SELECT 1 FROM sim_sales s WHERE s.order_id=o.id)) THEN
    RAISE EXCEPTION 'simulation location contains an unrecognized order';
  END IF;
END
$guard$;

INSERT INTO public.orders(id,status,items,location_id,created_by,created_at,
                          completed_at,total_amount,discount_amount,payment_mode,
                          completed_by_id,completed_by_name)
SELECT s.order_id,'completed',jsonb_build_array(jsonb_build_object(
         'product_id',s.product_id,'product_name','Simulation '||initcap(replace(s.pattern,'_',' ')),
         'unit','pcs','quantity',s.quantity,'price',25+s.idx)),
       c.location_id,NULL::bigint,s.completed_time-interval '20 minutes',s.completed_time,
       s.quantity*(25+s.idx),0,'Cash',NULL::text,'Forecast Simulation'
FROM sim_sales s CROSS JOIN sim_context c WHERE true
ON CONFLICT(id) DO NOTHING;

-- Historical checkout ledger balances reconcile to current product stock.
WITH balances AS (
 SELECT s.*,sum(quantity) OVER (PARTITION BY idx) AS total_sold,
        sum(quantity) OVER (PARTITION BY idx ORDER BY business_date,order_id) AS sold_through_day
 FROM sim_sales s
)
INSERT INTO public.transaction_history(id,created_at,product_id,user_id,user_name,
  transaction_type,quantity_change,new_quantity,location_id,note,operation_id,operation_scope)
SELECT md5('inventory-plus-sim-movement:'||b.order_id)::uuid,b.completed_time,b.product_id,
       NULL::bigint,'Forecast Simulation','checkout',-b.quantity,
       b.stock+b.total_sold-b.sold_through_day,c.location_id,
       'Synthetic completed order',b.order_id::text,'simulation_checkout'
FROM balances b CROSS JOIN sim_context c WHERE true
ON CONFLICT(id) DO NOTHING;

DO $verify$
DECLARE expected_count integer; order_count integer; history_count integer; movement_count integer;
BEGIN
  SELECT count(*) INTO expected_count FROM sim_sales;
  SELECT count(*) INTO order_count FROM public.orders
    WHERE location_id='11111111-1111-1111-1111-111111111111'
      AND completed_by_name='Forecast Simulation';
  SELECT count(*) INTO history_count FROM public.order_history
    WHERE location_id='11111111-1111-1111-1111-111111111111' AND status='completed'
      AND order_id IN (SELECT order_id FROM sim_sales);
  SELECT count(*) INTO movement_count FROM public.transaction_history
    WHERE location_id='11111111-1111-1111-1111-111111111111'
      AND operation_scope='simulation_checkout';
  IF expected_count<>order_count OR expected_count<>history_count
     OR expected_count<>movement_count THEN
    RAISE EXCEPTION 'sales mismatch: expected %, orders %, history %, movements %',
      expected_count,order_count,history_count,movement_count;
  END IF;
END
$verify$;

COMMIT;
SELECT count(*) AS synthetic_completed_orders FROM public.orders
WHERE location_id='11111111-1111-1111-1111-111111111111'
  AND completed_by_name='Forecast Simulation';
