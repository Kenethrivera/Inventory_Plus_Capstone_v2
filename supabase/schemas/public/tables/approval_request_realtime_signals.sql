CREATE TABLE "public"."approval_request_realtime_signals" (
  "location_id" uuid                     NOT NULL,
  "revision"    bigint                   NOT NULL DEFAULT 1,
  "changed_at"  timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "approval_request_realtime_signals_pkey" PRIMARY KEY (location_id)
);

ALTER TABLE "public"."approval_request_realtime_signals"
  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "approval_request_realtime_signals_anon_read" ON "public"."approval_request_realtime_signals"
  FOR SELECT
  TO "anon"
  USING (true);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."approval_request_realtime_signals" TO "service_role";

REVOKE ALL ON TABLE "public"."approval_request_realtime_signals" FROM "anon";

GRANT SELECT ON TABLE "public"."approval_request_realtime_signals" TO "anon";

REVOKE ALL ON TABLE "public"."approval_request_realtime_signals" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."approval_request_realtime_signals" TO "postgres";

REVOKE ALL ON TABLE "public"."approval_request_realtime_signals" FROM "authenticated";
