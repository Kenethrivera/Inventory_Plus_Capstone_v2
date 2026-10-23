CREATE TABLE "public"."store_map" (
  "id"          integer NOT NULL DEFAULT 1,
  "layout_data" jsonb   NOT NULL DEFAULT '[]'::jsonb,
  CONSTRAINT "store_map_pkey" PRIMARY KEY (id)
);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_map" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_map" TO "service_role";

REVOKE ALL ON TABLE "public"."store_map" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_map" TO "postgres";
