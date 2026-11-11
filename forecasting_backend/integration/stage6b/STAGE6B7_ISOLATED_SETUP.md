# Stage 6B.7 isolated Supabase setup

No isolated project currently exists. The connected MCP project has no
development branches and must be treated as production.

## Required operator inputs

Create a dedicated Supabase project or an explicitly approved paid branch, then
record both project references without committing credentials:

```text
STAGE6B_TEST_PROJECT_REF=<dedicated-test-ref>
STAGE6B_PRODUCTION_PROJECT_REF=pzotcznujkuzymndluwl
STAGE6B_TEST_SUPABASE_URL=https://<dedicated-test-ref>.supabase.co
STAGE6B_PRODUCTION_SUPABASE_URL=https://pzotcznujkuzymndluwl.supabase.co
STAGE6B_TEST_SUPABASE_PUBLISHABLE_KEY=<test-publishable-key>
STAGE6B_TEST_ENVIRONMENT_MARKER=inventory-plus-stage6b
```

The test and production project references and URLs must differ. Do not supply
a service-role key to the Python test harness.

## Ordered schema preparation

1. Provision the isolated database from the checked-in declarative schema or a
   schema-only production backup. Do not copy customer rows.
2. Confirm `extensions.pgcrypto`, the `private` schema, base public tables, and
   table constraints exist.
3. Apply `database/phase_5b_app_sessions.sql` before any session-validating RPC.
4. Apply the existing order, approval, history, notification, and transactional
   RPC migrations required by the current Flutter application.
5. Apply `database/stage_6b5_data_integrity_remediation.sql`.
6. Apply `database/stage_5a_daily_demand.sql`.
7. Apply `database/stage_6b6_secure_access_rpcs.sql`.
8. Apply `database/stage_6b7_product_access_rpcs.sql`.
9. Create the isolated marker and identity function exactly as documented in
   `forecasting_backend/integration/stage6b/README.md`.
10. Verify the identity function returns the expected test project reference
    before enabling fixture writes.

Do not apply `stage_6b5_security_target_state_isolated.sql` yet. The readiness
flags must remain false while notifications, presence, settings, storage, and
direct Realtime dependencies still exist.

## First behavioral matrix

Before enabling either Flutter migration gate, exercise the RPCs directly with
synthetic identities:

- valid, expired, revoked, and random tokens;
- Admin, Cashier/staff, and Helper roles;
- same-location and cross-location product/profile IDs;
- Helper order output with no payment or cash fields;
- Admin staff create, same-location detail, role update, and delete;
- denial of all staff mutations to Cashier and Helper;
- server-side password hashing and forced-change flag for new non-Admin staff;
- role change taking effect for an already-issued session;
- deleted staff session becoming unusable;
- product detail update, disable/restore journaling, open-order denial, inactive
  delete, shelf/bin update, and map assignment;
- forecasting product lookup restricted to the Admin's session location.

Then build Flutter with only the relevant gates:

```text
--dart-define=INVENTORY_PLUS_SECURE_ACCESS_V1=true
--dart-define=INVENTORY_PLUS_SECURE_PRODUCT_ACCESS_V1=true
```

Run the full Admin/Cashier/Helper workflow suite. A gate must remain off in
production until the matching isolated RPC matrix passes.

## Fixtures and cleanup

Use fixed Stage 6B UUIDs and usernames reserved for this harness. Fixture SQL
must verify the marker, expected project reference, and explicit write flag
before inserting. Cleanup may delete only those fixed identifiers and must run
the same guards. The five malformed production orders must never be copied,
modified, or used as writable fixtures.

## Restrictive migration readiness

Set `direct_table_calls_migrated=true` only after repository search and runtime
tests confirm every required client path uses an authorized interface. Set
`realtime_transport_migrated=true` only after the authenticated invalidation
transport is wired into Flutter and the direct Postgres Changes channels are
disabled in the isolated build. Only then test the restrictive migration and
its reviewed rollback privilege snapshot.

