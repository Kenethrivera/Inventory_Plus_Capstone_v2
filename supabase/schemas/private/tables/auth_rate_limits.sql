CREATE TABLE "private"."auth_rate_limits" (
  "action_type"      text                     NOT NULL,
  "subject_key_hash" bytea                    NOT NULL,
  "window_started_at" timestamp with time zone NOT NULL,
  "attempt_count"    integer                  NOT NULL DEFAULT 0,
  "blocked_until"    timestamp with time zone,
  "last_attempt_at"  timestamp with time zone NOT NULL,
  CONSTRAINT "auth_rate_limits_pkey"
    PRIMARY KEY (action_type, subject_key_hash),
  CONSTRAINT "auth_rate_limits_action_type_check"
    CHECK (action_type IN ('login', 'current_password')),
  CONSTRAINT "auth_rate_limits_subject_hash_check"
    CHECK (octet_length(subject_key_hash) = 32),
  CONSTRAINT "auth_rate_limits_attempt_count_check"
    CHECK (attempt_count >= 0)
);

ALTER TABLE "private"."auth_rate_limits"
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "private"."auth_rate_limits"
  FROM PUBLIC, "anon", "authenticated";

CREATE INDEX auth_rate_limits_last_attempt_idx
  ON private.auth_rate_limits USING btree (last_attempt_at);
