CREATE TABLE "public"."orders" (
  "id"                           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "status"                       text                     NOT NULL DEFAULT 'pending'::text,
  "items"                        jsonb                    NOT NULL,
  "location_id"                  uuid,
  "created_by"                   bigint,
  "prepared_by"                  bigint,
  "created_at"                   timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"                   timestamp with time zone NOT NULL DEFAULT now(),
  "total_amount"                 numeric                  NOT NULL DEFAULT 0,
  "discount_amount"              numeric                  NOT NULL DEFAULT 0,
  "payment_mode"                 text                     DEFAULT 'Cash'::text,
  "cash_given"                   double precision         DEFAULT '0'::double precision,
  "change_amount"                double precision         DEFAULT '0'::double precision,
  "completed_at"                 timestamp with time zone,
  "prepared_at"                  timestamp with time zone,
  "created_by_id"                text,
  "created_by_name"              text,
  "prepared_by_id"               text,
  "prepared_by_name"             text,
  "completed_by_id"              text,
  "completed_by_name"            text,
  "cancelled_by_id"              text,
  "cancelled_by_name"            text,
  "cancelled_at"                 timestamp with time zone,
  "returned_by_id"               text,
  "returned_by_name"             text,
  "returned_at"                  timestamp with time zone,
  "return_reason"                text,
  "assigned_helper_id"           text,
  "assigned_helper_name"         text,
  "assigned_at"                  timestamp with time zone,
  "assigned_by_admin_id"         text,
  "assigned_by_admin_name"       text,
  "payment_reference"            text,
  "discount_approval_request_id" uuid,
  "checkout_operation_id"        text,
  CONSTRAINT "orders_location_id_fkey" FOREIGN KEY (location_id) REFERENCES public.locations(id) ON DELETE CASCADE,
  CONSTRAINT "orders_pkey" PRIMARY KEY (id),
  CONSTRAINT "orders_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'prepared'::text, 'completed'::text, 'solo_picking'::text, 'cancelled'::text]))),
  CONSTRAINT "orders_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL,
  CONSTRAINT "orders_prepared_by_fkey" FOREIGN KEY (prepared_by) REFERENCES public.profiles(id) ON DELETE SET NULL
);

CREATE INDEX idx_orders_assigned_helper_id ON public.orders USING btree (assigned_helper_id);

CREATE INDEX idx_orders_completed_by_id ON public.orders USING btree (completed_by_id);

CREATE INDEX idx_orders_created_by_id ON public.orders USING btree (created_by_id);

CREATE INDEX idx_orders_prepared_by_id ON public.orders USING btree (prepared_by_id);

CREATE UNIQUE INDEX orders_checkout_operation_unique ON public.orders USING btree (checkout_operation_id)
  WHERE (checkout_operation_id IS NOT NULL);

CREATE UNIQUE INDEX orders_completed_gcash_reference_unique ON public.orders USING btree (location_id, lower(TRIM(BOTH FROM payment_reference)))
  WHERE ((status = 'completed'::text) AND (lower(TRIM(BOTH FROM payment_mode)) = 'gcash'::text) AND (payment_reference IS
    NOT NULL) AND (TRIM(BOTH FROM payment_reference) <> ''::text));

CREATE UNIQUE INDEX orders_discount_approval_request_unique ON public.orders USING btree (discount_approval_request_id)
  WHERE (discount_approval_request_id IS NOT NULL);

CREATE INDEX orders_helper_current_workload_v1_idx ON public.orders USING btree (location_id, assigned_helper_id)
  WHERE ((status = 'pending'::text) AND (assigned_helper_id IS NOT NULL));

CREATE INDEX orders_history_event_idx ON public.orders USING btree (location_id, COALESCE(completed_at, prepared_at, created_at) DESC, id DESC);

CREATE TRIGGER orders_sync_order_history_v1
  AFTER INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_order_history_v1();

CREATE POLICY "Enable all for authenticated POS users" ON "public"."orders"
  FOR ALL
  TO "authenticated"
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Public orders are viewable by everyone" ON "public"."orders"
  FOR SELECT
  TO "anon"
  USING (true);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."orders" TO "service_role";

REVOKE ALL ON TABLE "public"."orders" FROM "anon";

GRANT DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."orders" TO "anon";

REVOKE ALL ON TABLE "public"."orders" FROM "authenticated";

GRANT DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."orders" TO "authenticated";

REVOKE ALL ON TABLE "public"."orders" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."orders" TO "postgres";
