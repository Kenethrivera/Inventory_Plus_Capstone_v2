CREATE TABLE "public"."transaction_history" (
  "id"               uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "created_at"       timestamp with time zone NOT NULL DEFAULT now(),
  "product_id"       uuid,
  "user_id"          bigint,
  "user_name"        text,
  "transaction_type" text,
  "quantity_change"  numeric,
  "new_quantity"     numeric,
  "location_id"      uuid,
  "note"             text,
  CONSTRAINT "transaction_history_location_id_fkey" FOREIGN KEY (location_id) REFERENCES public.locations(id),
  CONSTRAINT "transaction_history_pkey" PRIMARY KEY (id),
  CONSTRAINT "transaction_history_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE,
  CONSTRAINT "transaction_history_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id)
);

CREATE INDEX transaction_history_location_created_idx ON public.transaction_history USING btree (location_id, created_at DESC, id DESC);

CREATE INDEX transaction_history_restock_actor_idx ON public.transaction_history USING btree (location_id, ((user_id)::text), transaction_type, created_at DESC, id DESC);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."transaction_history" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."transaction_history" TO "service_role";

REVOKE ALL ON TABLE "public"."transaction_history" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."transaction_history" TO "postgres";
