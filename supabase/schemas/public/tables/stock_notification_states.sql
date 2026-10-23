CREATE TABLE "public"."stock_notification_states" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "location_id" text                     NOT NULL,
  "item_id"     text                     NOT NULL,
  "last_status" text                     NOT NULL DEFAULT 'ok'::text,
  "updated_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "stock_notification_states_location_id_item_id_key" UNIQUE (location_id, item_id),
  CONSTRAINT "stock_notification_states_pkey" PRIMARY KEY (id)
);

CREATE INDEX idx_stock_notification_states_item ON public.stock_notification_states USING btree (item_id);

CREATE INDEX idx_stock_notification_states_location ON public.stock_notification_states USING btree (location_id);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."stock_notification_states" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."stock_notification_states" TO "service_role";

REVOKE ALL ON TABLE "public"."stock_notification_states" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."stock_notification_states" TO "postgres";
