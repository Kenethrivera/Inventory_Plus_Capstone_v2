-- Foreign keys in a cross-table reference cycle are split out of their
-- table's file: each file loads atomically, so keeping them inline would
-- deadlock the loader (every file would need a table another pending file
-- creates). These statements apply once all referenced tables exist.

ALTER TABLE "public"."approval_requests"
  ADD CONSTRAINT "approval_requests_used_order_id_fkey" FOREIGN KEY (used_order_id) REFERENCES public.orders(id) ON DELETE SET NULL;
