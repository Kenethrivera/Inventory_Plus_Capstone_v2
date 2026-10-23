CREATE TABLE "private"."app_sessions" (
  "token_hash" bytea                    NOT NULL,
  "profile_id" bigint                   NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "expires_at" timestamp with time zone NOT NULL,
  "revoked_at" timestamp with time zone,
  CONSTRAINT "app_sessions_pkey" PRIMARY KEY (token_hash),
  CONSTRAINT "app_sessions_profile_id_fkey" FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE
);

ALTER TABLE "private"."app_sessions"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX app_sessions_profile_active_idx ON private.app_sessions USING btree (profile_id, expires_at DESC)
  WHERE (revoked_at IS NULL);
