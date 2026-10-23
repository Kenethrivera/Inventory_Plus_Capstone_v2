CREATE TABLE "public"."locations" (
  "id"            uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "location_name" text                     NOT NULL,
  "store_key"     text                     NOT NULL,
  "address"       text,
  "created_at"    timestamp with time zone DEFAULT now(),
  "layout_data"   jsonb,
  CONSTRAINT "locations_pkey" PRIMARY KEY (id),
  CONSTRAINT "locations_store_key_key" UNIQUE (store_key)
);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."locations" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."locations" TO "service_role";

REVOKE ALL ON TABLE "public"."locations" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."locations" TO "postgres";
