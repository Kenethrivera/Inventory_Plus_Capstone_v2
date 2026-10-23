CREATE TABLE "public"."store_settings" (
  "id"           integer NOT NULL,
  "gcash_qr_url" text    DEFAULT ''::text,
  CONSTRAINT "store_settings_pkey" PRIMARY KEY (id)
);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_settings" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_settings" TO "service_role";

REVOKE ALL ON TABLE "public"."store_settings" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_settings" TO "postgres";
