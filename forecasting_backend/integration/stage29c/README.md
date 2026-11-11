# Stage 2.9C disposable-database integration harness

This harness compiles and exercises the recommendation-tracking proposal only
on an expressly approved disposable PostgreSQL/Supabase environment. It is
inert by default and refuses the protected Inventory Plus project ref
`pzotcznujkuzymndluwl`.

## Current environment assessment

Read-only Supabase MCP inspection on 2026-11-11 found **no existing development
branches**. No branch was created. This workstation also has no `supabase`,
`psql`, `docker`, or `podman` executable, so actual database compilation remains
unverified.

Supabase branches are appropriate for this test because they have separate
credentials and start with schema/migrations but no production data. Branching
requires an eligible paid plan and can incur usage charges. Creation therefore
requires a new, explicit user approval.

## Prepared test coverage

`test_stage29c_isolated_database.py` covers:

- proposal compilation and exact RPC signatures;
- `anon` denial and `service_role` execution grants;
- valid Admin, invalid session, and non-Admin authorization;
- rejection of experimental model metadata and stale inventory snapshots;
- immutable snapshots and idempotent retry after stock changes;
- pending, partial, multiple-receipt, and reconciled states;
- concurrent receipt allocation with no over-allocation;
- zero recommendations with undefined percentage variance;
- product deletion without losing recommendation snapshots;
- no inventory mutation by save, match, or reconciliation RPCs; and
- guarded cleanup/rollback with verification that proposal objects are gone.

The trusted FastAPI tests remain responsible for proving that predicted demand
is independently recalculated rather than trusted from the client. The database
RPC can validate approved model metadata, freshness, stock, units, and arithmetic,
but it cannot reproduce Python LightGBM itself.

## Explicitly approved setup only

1. Obtain user approval to create a disposable branch and accept its cost.
2. Create the branch. Do not merge it into the main project.
3. Wait for branch health/migrations to complete. Confirm the branch project ref
   is different from `pzotcznujkuzymndluwl`.
4. Run the existing read-only Stage 2.9C preflight against the branch. The base
   tables, `private.require_app_session_v1(text)`, `extensions.digest`, and
   `trim_scale(numeric)` must pass. Proposal objects must still be absent.
5. Install the isolated dependency:

   ```powershell
   python -m pip install -r forecasting_backend/integration/stage29c/requirements.txt
   ```

6. Using the branch database URL, manually authorize only that disposable
   environment:

   ```powershell
   psql $env:STAGE29C_TEST_DATABASE_URL `
     --set ON_ERROR_STOP=1 `
     --set stage29c_test_project_ref=$env:STAGE29C_TEST_PROJECT_REF `
     --set stage29c_write_confirmation=I_APPROVE_STAGE29C_WRITES_ON_THIS_DISPOSABLE_DATABASE `
     --file forecasting_backend/integration/stage29c/stage29c_authorize_disposable.sql
   ```

7. Configure the guarded runner. Never place the database URL in source control
   or command output:

   ```powershell
   $env:STAGE29C_TEST_ENVIRONMENT_MARKER='inventory-plus-stage29c'
   $env:STAGE29C_TEST_WRITE_CONFIRMATION='I_APPROVE_STAGE29C_WRITES_ON_THIS_DISPOSABLE_DATABASE'
   $env:STAGE29C_TEST_PROJECT_REF='<disposable-branch-ref>'
   $env:STAGE29C_TEST_DATABASE_URL='<direct branch PostgreSQL URL>'
   ```

8. Run the trusted-boundary tests first, then the database suite once:

   ```powershell
   python -m pytest forecasting_backend/tests/test_stage29c_trusted_persistence_api.py -q
   python -m unittest forecasting_backend.integration.stage29c.test_stage29c_isolated_database -v
   ```

The database suite applies the proposal, inserts fixed fixtures, tests the
lifecycle, then executes `stage29c_cleanup.sql`. If configuration is absent it
skips. A partial configuration, protected project ref, missing database marker,
or pre-existing proposal object causes a hard failure before migration execution.

## Activation checklist (after an isolated PASS and separate approval)

1. Back up/export any recommendation tables if this is a re-deployment.
2. Re-run `stage_2_9c_recommendation_tracking_PREFLIGHT_READ_ONLY.sql` on the
   target and resolve every genuine incompatibility.
3. Confirm the target has PostgreSQL 17-compatible functions, `pgcrypto` in the
   `extensions` schema, the verified base tables, session RPC, and service role.
4. Keep `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false`.
5. Manually apply `stage_2_9c_recommendation_tracking_PROPOSAL.sql` once.
6. Verify exact RPC signatures, grants, RLS, immutable triggers, empty tracking
   output, and unchanged product/transaction counts.
7. Configure `SUPABASE_SECRET_KEY` only in the FastAPI server environment. Do
   not expose it to Flutter, logs, responses, or `--dart-define` values.
8. Run backend health checks and one approved Admin smoke save in a non-production
   test location only.
9. Enable `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=true` only after review.

## Operational rollback

If authorization, idempotency, allocation, inventory-mutation, or secret-handling
checks fail, immediately set `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false`
and restart FastAPI. This disables writes while preserving immutable history.
Do not drop tables as the first production rollback action.

`stage29c_cleanup.sql` is for the approved disposable test environment. A
production schema removal would destroy recommendation history and requires a
separate reviewed migration, backup/export, and explicit approval.
