CREATE TABLE "public"."export_log" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "location_id" text                     NOT NULL,
  "report_type" text                     NOT NULL,
  "period_type" text                     NOT NULL,
  "period_key"  text                     NOT NULL,
  "exported_at" timestamp with time zone NOT NULL DEFAULT now(),
  "exported_by" bigint,
  CONSTRAINT "export_log_location_id_report_type_period_type_period_key_key" UNIQUE (location_id, report_type, period_type, period_key),
  CONSTRAINT "export_log_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."export_log"
  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "export_log_insert" ON "public"."export_log"
  FOR INSERT
  TO PUBLIC
  WITH CHECK (true);

CREATE POLICY "export_log_select" ON "public"."export_log"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "export_log_update" ON "public"."export_log"
  FOR UPDATE
  TO PUBLIC
  USING (true)
  WITH CHECK (true);

REVOKE ALL ON SEQUENCE "public"."export_log_id_seq" FROM "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."export_log_id_seq" TO "anon";

REVOKE ALL ON SEQUENCE "public"."export_log_id_seq" FROM "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."export_log_id_seq" TO "authenticated";

REVOKE ALL ON SEQUENCE "public"."export_log_id_seq" FROM "postgres";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."export_log_id_seq" TO "postgres";

REVOKE ALL ON SEQUENCE "public"."export_log_id_seq" FROM "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."export_log_id_seq" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."export_log" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."export_log" TO "service_role";

REVOKE ALL ON TABLE "public"."export_log" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."export_log" TO "postgres";
