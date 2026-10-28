CREATE TABLE "public"."products" (
  "id"               uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "sku"              text                     NOT NULL,
  "product_name"     text                     NOT NULL,
  "category"         text,
  "manufacturer"     text,
  "model"            text,
  "product_size"     text,
  "product_price"    numeric(12,2)            DEFAULT 0.00,
  "product_quantity" numeric                  DEFAULT 0,
  "created_at"       timestamp with time zone DEFAULT now(),
  "updated_at"       timestamp with time zone DEFAULT now(),
  "image_url"        text,
  "location_id"      uuid,
  "shelf_level"      text,
  "bin_number"       text,
  "description"      text,
  "unit"             text                     DEFAULT 'pcs'::text,
  "max_quantity"     numeric                  DEFAULT 100.0,
  "is_active"        boolean                  NOT NULL DEFAULT true,
  "map_element_id"   text,
  "create_operation_id" text,
  CONSTRAINT "products_location_id_fkey" FOREIGN KEY (location_id) REFERENCES public.locations(id),
  CONSTRAINT "products_pkey" PRIMARY KEY (id),
  CONSTRAINT "products_product_price_check" CHECK ((product_price >= (0)::numeric)),
  CONSTRAINT "products_product_quantity_check" CHECK ((product_quantity >= (0)::numeric)),
  CONSTRAINT "products_sku_key" UNIQUE (sku)
);

CREATE POLICY "Allow public read products" ON "public"."products"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE UNIQUE INDEX products_create_operation_unique
  ON public.products USING btree (create_operation_id)
  WHERE (create_operation_id IS NOT NULL);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "service_role";

REVOKE ALL ON TABLE "public"."products" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "postgres";
