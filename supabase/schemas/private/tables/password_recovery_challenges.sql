create table if not exists private.password_recovery_challenges (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id bigint not null references public.profiles(id) on delete cascade,
  channel text not null check (channel in ('sms', 'email')),
  code_hash bytea not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  attempts integer not null default 0,
  verified_at timestamptz,
  reset_token_hash bytea,
  reset_expires_at timestamptz,
  consumed_at timestamptz
);
create index if not exists password_recovery_profile_created_idx
  on private.password_recovery_challenges (profile_id, created_at desc);
revoke all on private.password_recovery_challenges from public, anon, authenticated;
grant select, insert, update, delete on private.password_recovery_challenges
  to service_role, postgres;
