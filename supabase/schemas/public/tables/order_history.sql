CREATE TABLE "public"."order_history" (
  "order_id"             text                     NOT NULL,
  "location_id"          uuid                     NOT NULL,
  "status"               text                     NOT NULL,
  "items"                jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "created_at"           timestamp with time zone NOT NULL,
  "assigned_at"          timestamp with time zone,
  "prepared_at"          timestamp with time zone,
  "completed_at"         timestamp with time zone,
  "cancelled_at"         timestamp with time zone,
  "returned_at"          timestamp with time zone,
  "created_by_id"        text,
  "created_by_name"      text,
  "assigned_helper_id"   text,
  "assigned_helper_name" text,
  "prepared_by_id"       text,
  "prepared_by_name"     text,
  "completed_by_id"      text,
  "completed_by_name"    text,
  "cancelled_by_id"      text,
  "cancelled_by_name"    text,
  "returned_by_id"       text,
  "returned_by_name"     text,
  "total_amount"         numeric                  NOT NULL DEFAULT 0,
  "discount_amount"      numeric                  NOT NULL DEFAULT 0,
  "payment_mode"         text,
  "payment_reference"    text,
  "cash_given"           numeric,
  "change_amount"        numeric,
  "snapshot_updated_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "order_history_pkey" PRIMARY KEY (order_id)
);

ALTER TABLE "public"."order_history"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX order_history_assigned_helper_idx ON public.order_history USING btree (location_id, assigned_helper_id);

CREATE INDEX order_history_cancelled_actor_idx ON public.order_history USING btree (location_id, cancelled_by_id);

CREATE INDEX order_history_completed_actor_idx ON public.order_history USING btree (location_id, completed_by_id);

CREATE INDEX order_history_created_actor_idx ON public.order_history USING btree (location_id, created_by_id);

CREATE INDEX order_history_event_idx ON public.order_history USING btree (location_id, COALESCE(completed_at, prepared_at, created_at) DESC, order_id DESC);

CREATE INDEX order_history_prepared_helper_idx ON public.order_history USING btree (location_id, prepared_by_id);

CREATE INDEX order_history_returned_actor_idx ON public.order_history USING btree (location_id, returned_by_id);

CREATE TRIGGER order_history_signal_realtime_v1
  AFTER INSERT OR DELETE OR UPDATE ON public.order_history
  FOR EACH ROW
  EXECUTE FUNCTION public.signal_order_history_change_v1();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."order_history" TO "service_role";

REVOKE ALL ON TABLE "public"."order_history" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."order_history" TO "postgres";

REVOKE ALL ON TABLE "public"."order_history" FROM "anon", "authenticated";
