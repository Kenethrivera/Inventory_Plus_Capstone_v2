# Inventory Plus Stage 6B verification report

Date: 2026-11-05

No production rows were created, updated, or deleted. No customer fields,
session tokens, profile identifiers, order identifiers, or location identifiers
were included in this report.

## Environment and scope

- Supabase MCP connection: initialized successfully.
- Connected environment: existing remote project, used only for catalog and
  aggregate read-only inspection.
- Supabase development branches: none.
- Local Supabase CLI: unavailable.
- Docker runtime: unavailable.
- Isolated behavioral fixture execution: blocked.

No branch was created because branching may incur cost and no billing approval
was requested or supplied.

## Deployed RPC contract

The deployed `forecast_daily_demand_v1` matches the checked-in adapter contract:

- Arguments: session token text, start/end `timestamptz`, business timezone
  text with `Asia/Manila` default.
- Return columns: business date, location UUID, product UUID, nullable SKU,
  product name, unit, numeric quantity, and bigint completed-order count.
- Volatility: stable.
- Security: `SECURITY DEFINER`, owned by `postgres`.
- Runtime search path: `public, private, extensions, pg_temp`.
- Table references are schema-qualified; session validation calls the qualified
  `private.require_app_session_v1` function.
- EXECUTE: `anon`, `service_role`, and `postgres` only. `PUBLIC` and
  `authenticated` are denied.
- Untrusted roles cannot create objects in `public` or `private`.

`sku` is nullable because the product lookup is a left join. The other output
values are effectively non-null for returned rows: product identifiers and
quantities are validated, name/unit have explicit fallbacks, and order count is
positive.

The function uses `completed_at >= start AND completed_at < end`. A live
constant-only check confirmed that 15:59:59 UTC remains on the prior Manila
business date, while 16:00:00 UTC becomes the next date.

## Authentication and authorization

`profile_restore_session_v1` and `private.require_app_session_v1` validate a
SHA-256 token hash against `private.app_sessions`, require the session to be
unrevoked and unexpired, and require a profile location.

The forecasting API then:

1. restores the session server-side;
2. requires normalized role `admin`;
3. rejects a client location differing from the restored location;
4. derives product and demand queries from the restored location; and
5. verifies adapter output product/location consistency again.

Live read-only denied-path checks confirmed that a deliberately invalid session
is rejected by both session restoration and the demand RPC. Positive Admin,
Cashier/Helper, and cross-location behavioral paths were not executed because
no genuine isolated identities were available.

Authentication error text is now normalized by the Python adapter so upstream
messages cannot reflect bearer tokens or internal details into HTTP responses.

## Live aggregate data-quality audit

Only aggregate counts were inspected:

- Completed-status snapshots: 22.
- Completed snapshots missing completion timestamp: 0.
- Completed returned snapshots: 0.
- Completed snapshots with invalid item JSON type: 0.
- Completed snapshots with empty item arrays: 5.
- Nonempty completed item lines: 24.
- Missing/invalid product UUIDs: 0.
- Invalid/nonpositive quantities: 0.
- Product-day unit conflicts: 0.
- Lines without a matching product at the same location: 0.

All five empty completed snapshots are inside the current 365-day API window
and belong to one location. Because the RPC correctly fails closed on empty
completed snapshots, an authorized request for that affected location/window is
expected to fail. No positive live RPC or production end-to-end forecast is
therefore claimed.

## Contract discrepancy

Python preprocessing rejects a record whose status is completed but whose
completion timestamp is absent. The SQL function filters `completed_at IS NOT
NULL` before its malformed-record validation loop, so such a row would be
silently omitted instead of rejected. No such live row currently exists, but
the isolated harness contains an intentionally failing assertion until the SQL
and Python contracts are aligned.

## Security findings

1. `products` has RLS disabled and is selectable by `anon`; its existing public
   read policy is ineffective while RLS is disabled. The backend still filters
   by restored session location, but database-level product isolation is not
   enforced.
2. Supabase security advisors report multiple public tables with RLS disabled,
   including `products`, `profiles`, `locations`, and operational tables. This
   is a wider deployment remediation task, not changed in Stage 6B.
3. The advisor flags anonymous execution of `SECURITY DEFINER` functions. For
   the forecast RPC, anonymous invocation is intentional because authorization
   uses the opaque application session token inside the function; every such
   function still requires individual privilege-boundary auditing.
4. Flutter contains only the Supabase anonymous/publishable configuration and
   the forecasting API URL. No service-role credential is present.
5. The opaque application session token is stored in Flutter
   `SharedPreferences`, not an OS-backed secure credential store.

Supabase remediation guidance:
https://supabase.com/docs/guides/database/database-linter

## Isolated integration harness

Prepared files:

- `stage6b_fixtures.sql`: marker-gated fixture and exact SQL assertions.
- `stage6b_cleanup.sql`: marker-gated cleanup for persistent test fixtures.
- `test_stage6b_isolated.py`: opt-in Python RPC and end-to-end API tests.
- `README.md`: environment guard and execution instructions.

The SQL covers completed, pending, cancelled, returned, malformed, duplicate
line, inconsistent unit, Philippine-midnight, Admin/non-Admin, invalid/expired
session, cross-location, missing product snapshot, empty history, and grouping
behavior. The Python suite reuses the production adapter, forecasting models,
recommendation engine, and serializer.

Fixture writes require a marker table that must be created separately and only
in an isolated database. The integration tests also require explicit test and
production URLs and abort if they match.

## Completion status

Automated checks executed for this stage:

- Full Python regression and Stage 6B contract suite: 99 tests passed.
- Python bytecode compilation for `app` and `integration`: passed.
- Isolated Stage 6B module: 1 test class skipped by the environment guard;
  zero behavioral integration tests executed.

- Stage 6B.1 read-only inspection: **PARTIALLY COMPLETE**. Definition, types,
  grants, session flow, boundaries, malformed-data aggregates, invalid-session
  denial, and client credential boundaries were checked. Positive authorized
  live behavior remains blocked.
- Stage 6B.2 isolated behavioral tests: **BLOCKED / HARNESS READY**. No isolated
  database exists in the available environment.
- Stage 6B.3 live end-to-end API verification: **BLOCKED**. Production positive
  execution is not claimed, and the affected location has fail-closed legacy
  snapshots.
- Stage 6B.4 environment/security inspection: **COMPLETE FOR FORECASTING SCOPE**,
  with the RLS and local token-storage findings requiring remediation.

Production deployment is not ready until the malformed completed snapshots are
resolved under an approved data-governance process, the SQL/Python timestamp
contract is aligned, location-scoped product access is enforced at the database
boundary, and the isolated allowed/denied behavioral suite passes.
