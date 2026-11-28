CREATE TABLE "public"."staff_presence_realtime_signals" (
  "id" boolean NOT NULL DEFAULT true,
  "revision" bigint NOT NULL DEFAULT 0,
  "changed_at" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "staff_presence_realtime_signals_pkey" PRIMARY KEY (id),
  CONSTRAINT "staff_presence_realtime_signals_one_row" CHECK (id)
);

ALTER TABLE "public"."staff_presence_realtime_signals"
  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "staff_presence_realtime_signals_anon_read"
  ON "public"."staff_presence_realtime_signals"
  FOR SELECT TO "anon" USING (true);

GRANT SELECT ON TABLE "public"."staff_presence_realtime_signals" TO "anon";
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE "public"."staff_presence_realtime_signals" TO "service_role", "postgres";
