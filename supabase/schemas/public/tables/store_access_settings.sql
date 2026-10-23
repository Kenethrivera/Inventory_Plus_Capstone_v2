CREATE TABLE "public"."store_access_settings" (
  "id"                          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "location_id"                 text                     NOT NULL,
  "opening_time"                time without time zone   NOT NULL DEFAULT '08:00:00'::time WITHOUT time zone,
  "closing_time"                time without time zone   NOT NULL DEFAULT '21:00:00'::time WITHOUT time zone,
  "staff_access_before_minutes" integer                  NOT NULL DEFAULT 30,
  "staff_access_after_minutes"  integer                  NOT NULL DEFAULT 30,
  "restrict_staff_login"        boolean                  NOT NULL DEFAULT true,
  "allow_admin_anytime"         boolean                  NOT NULL DEFAULT true,
  "updated_at"                  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "store_access_settings_location_id_key" UNIQUE (location_id),
  CONSTRAINT "store_access_settings_pkey" PRIMARY KEY (id)
);

CREATE INDEX idx_store_access_settings_location ON public.store_access_settings USING btree (location_id);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_access_settings" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_access_settings" TO "service_role";

REVOKE ALL ON TABLE "public"."store_access_settings" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."store_access_settings" TO "postgres";
