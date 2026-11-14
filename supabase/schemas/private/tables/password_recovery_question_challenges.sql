create table if not exists private.password_recovery_question_challenges (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id bigint not null references public.profiles(id) on delete cascade,
  first_question_id text not null,
  second_question_id text not null,
  third_question_id text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  attempts integer not null default 0,
  reset_token_hash bytea,
  reset_expires_at timestamptz,
  consumed_at timestamptz
);
create index if not exists password_recovery_question_challenges_profile_idx
  on private.password_recovery_question_challenges (profile_id, created_at desc);
alter table private.password_recovery_question_challenges enable row level security;
revoke all on private.password_recovery_question_challenges from public, anon, authenticated;
