# Stage 6B isolated Supabase integration harness

This harness must never run against the production project. It writes temporary
fixtures and rolls the transaction back, but rollback is not a substitute for
environment isolation.

## Required isolated environment

Use one of:

- a disposable local Supabase stack;
- a dedicated test project; or
- a Supabase development branch whose cost has been explicitly approved.

Before running the fixture SQL, an operator must create this marker **only in
the isolated database**:

```sql
create table private.stage6b_isolated_environment (
  marker text primary key,
  project_ref text not null,
  purpose text not null,
  allow_fixture_writes boolean not null default false,
  authorized_at timestamptz not null default now()
);

insert into private.stage6b_isolated_environment (
  marker, project_ref, purpose, allow_fixture_writes
) values (
  'inventory-plus-stage6b',
  '<dedicated-test-project-ref>',
  'inventory-plus-stage6b-isolated-integration',
  true
);

create or replace function public.stage6b_test_environment_identity_v1()
returns jsonb
language sql
stable
security definer
set search_path to 'private', 'pg_temp'
as $$
  select jsonb_build_object(
    'marker', marker,
    'project_ref', project_ref,
    'purpose', purpose,
    'fixture_writes_authorized', allow_fixture_writes
  )
  from private.stage6b_isolated_environment
  where marker = 'inventory-plus-stage6b'
$$;

revoke all on function public.stage6b_test_environment_identity_v1()
  from public, authenticated;
grant execute on function public.stage6b_test_environment_identity_v1()
  to anon;
```

The fixture script aborts before inserts unless that marker exists and is
enabled. The marker creation is deliberately not included in the fixture
script, so an accidental production connection cannot self-authorize.

## Database fixture tests

Run with a direct connection to the isolated database:

```text
psql "$STAGE6B_TEST_DATABASE_URL" \
  --set ON_ERROR_STOP=1 \
  --set stage6b_expected_project_ref="$STAGE6B_TEST_PROJECT_REF" \
  --file forecasting_backend/integration/stage6b/stage6b_fixtures.sql
```

The SQL transaction verifies completed/pending/cancelled/returned handling,
multiple lines and orders, Philippine midnight, location isolation, role and
session denial, missing product snapshots, malformed snapshots, and the known
missing-completion-timestamp contract gap. It ends with `rollback`.

To retain the isolated fixtures temporarily for the Python end-to-end tests,
run the same file with `--set stage6b_persist_fixtures=true`. This skips only
the known intentionally failing timestamp-gap assertion and commits the named
Stage 6B records. Afterwards, run `stage6b_cleanup.sql`; it has the same marker
guard and deletes only the fixed Stage 6B identifiers.

## Python end-to-end tests

After loading fixtures in a test environment that preserves them for the test
process, configure:

- `STAGE6B_TEST_ENVIRONMENT_MARKER=inventory-plus-stage6b`
- `STAGE6B_TEST_SUPABASE_URL`
- `STAGE6B_TEST_SUPABASE_PUBLISHABLE_KEY`
- `STAGE6B_PRODUCTION_SUPABASE_URL`
- `STAGE6B_TEST_PROJECT_REF`
- `STAGE6B_PRODUCTION_PROJECT_REF`

The test URL and project identity must both differ from production. The Python
suite calls the test-only identity RPC and requires its stored project ref to
match `STAGE6B_TEST_PROJECT_REF` before any behavioral test runs. Then run:

```text
python -m unittest integration.stage6b.test_stage6b_isolated -v
```

No service-role key is used by the Python tests. Secrets must be supplied by
the test environment and must never be committed or printed.

The normal unit-test suite does not automatically discover this directory.
Missing configuration produces a skip, not a fabricated pass.
