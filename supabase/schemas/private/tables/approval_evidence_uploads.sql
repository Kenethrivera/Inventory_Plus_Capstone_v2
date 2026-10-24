CREATE TABLE "private"."approval_evidence_uploads" (
  "id"              uuid                     NOT NULL DEFAULT extensions.gen_random_uuid(),
  "location_id"     uuid                     NOT NULL,
  "requested_by_id" bigint                   NOT NULL,
  "storage_path"    text                     NOT NULL,
  "file_name"       text                     NOT NULL,
  "mime_type"       text                     NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "expires_at"      timestamp with time zone NOT NULL DEFAULT (now() + '00:15:00'::interval),
  CONSTRAINT "approval_evidence_uploads_mime_type_check" CHECK ((mime_type = ANY (ARRAY['image/jpeg'::text, 'image/png'::text, 'image/webp'::text, 'image/gif'::text]))),
  CONSTRAINT "approval_evidence_uploads_pkey" PRIMARY KEY (id),
  CONSTRAINT "approval_evidence_uploads_storage_path_key" UNIQUE (storage_path),
  CONSTRAINT "approval_evidence_uploads_location_id_fkey" FOREIGN KEY (location_id) REFERENCES public.locations(id),
  CONSTRAINT "approval_evidence_uploads_requested_by_id_fkey" FOREIGN KEY (requested_by_id) REFERENCES public.profiles(id)
);

ALTER TABLE "private"."approval_evidence_uploads"
  ENABLE ROW LEVEL SECURITY;
