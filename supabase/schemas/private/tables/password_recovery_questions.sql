create table if not exists private.password_recovery_questions (
  profile_id bigint not null references public.profiles(id) on delete cascade,
  question_id text not null,
  answer_hash text not null,
  primary key (profile_id, question_id)
);
alter table private.password_recovery_questions enable row level security;
revoke all on private.password_recovery_questions from public, anon, authenticated;
