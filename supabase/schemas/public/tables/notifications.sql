CREATE TABLE "public"."notifications" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "location_id"  text                     NOT NULL,
  "target_roles" text[]                   NOT NULL DEFAULT '{}'::text[],
  "title"        text                     NOT NULL,
  "body"         text                     NOT NULL,
  "type"         text                     NOT NULL,
  "priority"     text                     NOT NULL,
  "payload"      jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "is_resolved"  boolean                  NOT NULL DEFAULT false,
  "resolved_at"  timestamp with time zone,
  CONSTRAINT "notifications_pkey" PRIMARY KEY (id)
);

CREATE INDEX idx_notifications_resolved ON public.notifications USING btree (is_resolved);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notifications" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notifications" TO "service_role";

REVOKE ALL ON TABLE "public"."notifications" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notifications" TO "postgres";
