CREATE TABLE "public"."staff_presence" (
  "user_id"        text                     NOT NULL,
  "user_name"      text                     NOT NULL,
  "user_role"      text                     NOT NULL,
  "location_id"    text                     NOT NULL,
  "is_online"      boolean                  NOT NULL DEFAULT false,
  "current_module" text,
  "logged_in_at"   timestamp with time zone,
  "last_seen_at"   timestamp with time zone,
  "logged_out_at"  timestamp with time zone,
  CONSTRAINT "staff_presence_pkey" PRIMARY KEY (user_id)
);

CREATE INDEX idx_staff_presence_last_seen ON public.staff_presence USING btree (last_seen_at);

CREATE INDEX idx_staff_presence_location ON public.staff_presence USING btree (location_id);

CREATE INDEX idx_staff_presence_role ON public.staff_presence USING btree (user_role);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_presence" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_presence" TO "service_role";

REVOKE ALL ON TABLE "public"."staff_presence" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_presence" TO "postgres";
