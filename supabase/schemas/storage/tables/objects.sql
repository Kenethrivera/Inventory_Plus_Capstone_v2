CREATE POLICY "Allow public updates" ON "storage"."objects"
  FOR UPDATE
  TO PUBLIC
  USING ((bucket_id = 'product_images'::text));

CREATE POLICY "Allow public uploads" ON "storage"."objects"
  FOR ALL
  TO PUBLIC
  USING ((bucket_id = 'store_assets'::text))
  WITH CHECK ((bucket_id = 'store_assets'::text));

CREATE POLICY "Allow public viewing" ON "storage"."objects"
  FOR SELECT
  TO PUBLIC
  USING ((bucket_id = 'product_images'::text));
