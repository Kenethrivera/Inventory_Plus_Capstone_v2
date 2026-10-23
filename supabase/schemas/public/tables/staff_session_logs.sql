CREATE TABLE "public"."staff_session_logs" (
  "id"                     uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"                text                     NOT NULL,
  "user_name"              text                     NOT NULL,
  "user_role"              text                     NOT NULL,
  "location_id"            text                     NOT NULL,
  "login_at"               timestamp with time zone NOT NULL DEFAULT now(),
  "logout_at"              timestamp with time zone,
  "logout_reason"          text,
  "blocked_by_store_hours" boolean                  NOT NULL DEFAULT false,
  "block_reason"           text,
  CONSTRAINT "staff_session_logs_pkey" PRIMARY KEY (id)
);

CREATE INDEX idx_staff_session_logs_location ON public.staff_session_logs USING btree (location_id);

CREATE INDEX idx_staff_session_logs_login ON public.staff_session_logs USING btree (login_at);

CREATE INDEX idx_staff_session_logs_user ON public.staff_session_logs USING btree (user_id);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_session_logs" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_session_logs" TO "service_role";

REVOKE ALL ON TABLE "public"."staff_session_logs" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."staff_session_logs" TO "postgres";
