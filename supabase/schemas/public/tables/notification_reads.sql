CREATE TABLE "public"."notification_reads" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "notification_id" uuid                     NOT NULL,
  "user_id"         text                     NOT NULL,
  "is_read"         boolean                  NOT NULL DEFAULT false,
  "read_at"         timestamp with time zone,
  "is_deleted"      boolean                  NOT NULL DEFAULT false,
  "deleted_at"      timestamp with time zone,
  CONSTRAINT "notification_reads_notification_id_user_id_key" UNIQUE (notification_id, user_id),
  CONSTRAINT "notification_reads_pkey" PRIMARY KEY (id),
  CONSTRAINT "notification_reads_notification_id_fkey" FOREIGN KEY (notification_id) REFERENCES public.notifications(id) ON DELETE CASCADE
);

CREATE TRIGGER notification_reads_signal_realtime_v1
  AFTER INSERT OR UPDATE OR DELETE ON public.notification_reads
  FOR EACH ROW
  EXECUTE FUNCTION public.signal_notification_change_v1();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notification_reads" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notification_reads" TO "service_role";

REVOKE ALL ON TABLE "public"."notification_reads" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."notification_reads" TO "postgres";
