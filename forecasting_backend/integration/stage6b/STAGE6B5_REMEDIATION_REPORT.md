# Inventory Plus Stage 6B.5 remediation report

Date: 2026-11-05

Inspected source revision: `d9970456a7a65a846be318b139300c685ffdbd6d` with
pre-existing uncommitted Stage 5/6 work preserved.

No production DDL, DML, fixture, repair, grant, policy, or RPC replacement was
executed. Live database work was limited to catalog queries and aggregate
read-only evidence checks.

## Authentication model and RLS consequence

Inventory Plus authenticates users with an opaque token stored as a SHA-256
hash in `private.app_sessions`. Flutter connects to Supabase as the `anon`
Postgres role; it does not receive a Supabase Auth JWT for the Inventory Plus
profile. Consequently `auth.uid()` is null/unrelated and cannot identify the
application profile, role, or location.

An `auth.uid()` location policy would therefore deny legitimate application
traffic or, if weakened to `anon`, expose every location. The safe target is:

1. no direct anonymous access to operational tables;
2. narrowly granted `SECURITY DEFINER` RPCs;
3. every application RPC validates `private.require_app_session_v1` (except
   login/restore/logout, which implement their own credential/token checks);
4. role and location are derived from the validated session, never caller
   identity fields; and
5. realtime uses a transport that can enforce this same identity boundary or
   emits non-sensitive invalidations followed by authorized RPC refetches.

## Live table audit and remediation plan

| Table | Live anonymous access / exposure | Current Flutter need | Target remediation |
|---|---|---|---|
| `private.app_sessions` | No direct access; RLS enabled | Session RPCs only | Retain. Never grant Flutter access. |
| `private.approval_evidence_uploads` | No direct access; RLS enabled | Approval RPCs | Retain RPC-only access. |
| `private.auth_rate_limits` | No direct access; RLS enabled | Login RPC only | Retain private access. |
| `public.products` | Anonymous CRUD; RLS disabled; cross-location inventory exposure | Location inventory read/realtime; Admin mutations | Replace remaining direct reads/writes with session-scoped RPCs, then revoke direct grants and enable deny-by-default RLS. |
| `public.orders` | Anonymous SELECT/UPDATE/DELETE; RLS disabled; cross-location order exposure and mutation | Shared order snapshot/realtime and legacy updates | Move all reads/transitions/claims to session RPCs and secure invalidation transport before revocation. Existing transactional RPCs remain the write boundary. |
| `public.order_history` | No anonymous access; RLS enabled | History RPCs; one legacy direct read exists | Remove/replace legacy direct read. Retain RPC-only history access. |
| `public.transaction_history` | Anonymous CRUD; RLS disabled | Dashboard/history/forecast reads; internal operation writes | Use history/report RPCs for reads and business RPCs/triggers for writes. Revoke all direct client DML. |
| `public.profiles` | Anonymous CRUD; RLS disabled; password hashes and cross-location staff data exposed | Login/reset, current profile, Admin staff management, realtime | Highest-priority migration: session-scoped self/Admin RPCs and server-side recovery flow, then revoke all direct access. Never expose `password`. |
| `public.locations` | Anonymous CRUD; RLS disabled | Current location/map read and save | Add current-location read RPC; retain `save_store_map_v1`; revoke direct writes and cross-location reads. |
| `public.notifications` | Anonymous CRUD; RLS disabled | Canonical notification state/realtime | Move list/read/transition operations behind session RPCs and secure invalidation before revocation. |
| `public.notification_reads` | Anonymous CRUD; RLS disabled | Per-user read state/realtime | RPCs must derive profile ID from session; revoke caller-supplied direct writes. |
| `public.stock_notification_states` | Anonymous CRUD; RLS disabled | Notification lifecycle | Keep transitions in vetted lifecycle RPC; add scoped read RPC and revoke direct access. |
| `public.staff_presence` | Anonymous CRUD; RLS disabled | Heartbeat and location presence/realtime | Add heartbeat/list RPCs deriving identity/location; preserve expiry logic; secure realtime before revocation. |
| `public.staff_session_logs` | Anonymous CRUD; RLS disabled | Presence/audit logging | Insert through session-aware presence RPC; Admin scoped read RPC only. |
| `public.store_access_settings` | Anonymous CRUD; RLS disabled | Login checks, Admin settings, realtime | Provide public minimal login-eligibility RPC plus authenticated Admin configuration RPCs; revoke table access. |
| `public.store_map` | Anonymous CRUD; RLS disabled | Layout persistence | Confirm whether still canonical; use `save_store_map_v1` and location-scoped read RPC, then revoke direct access. |
| `public.store_settings` | Anonymous SELECT; RLS disabled | Payment/discount settings | Location-scoped read RPC and existing Admin update RPCs; revoke cross-location select. |
| `public.measurements` | Anonymous CRUD through permissive RLS | Unit configuration | Admin session RPCs for mutations and scoped/reference read RPC; remove permissive policy. |
| `public.threshold` | Anonymous CRUD through permissive RLS | Stock threshold settings | Admin RPC mutations and location-scoped read; remove permissive policy. |
| `public.export_log` | Anonymous CRUD through public policies | Export reminders | Session-scoped reminder RPCs; remove public policies and direct DML. |
| `public.product_forecasts` | Anonymous CRUD; RLS disabled | No production Stage 5 forecast write path | Revoke client access; forecasting API remains read-only. |
| `public.approval_requests` | No anonymous access; RLS enabled | Approval RPCs | Retain RPC-only access. |
| `public.approval_request_realtime_signals` | Anonymous SELECT; RLS enabled with allow-all policy | Realtime invalidation | Replace with non-sensitive secure broadcast or authenticated transport; then revoke. |
| `public.order_history_realtime_signals` | Anonymous SELECT; RLS enabled with allow-all policy | History invalidation | Same as approval signals. Signal rows must not become a cross-location metadata leak. |

The isolated target-state SQL intentionally creates no `auth.uid()` allow
policies. It is guarded by both the isolated-environment marker and a separate
readiness marker proving that direct client calls and realtime transport have
already migrated. Applying it today would break working Flutter workflows.

### Required application privileges by role

These are business capabilities to enforce inside RPCs, not Postgres table
grants to `anon`:

| Role | Required capabilities |
|---|---|
| Admin | Location-scoped inventory read/mutation; order monitoring, assignment and authorized transitions; complete history/reporting; staff configuration; approvals; store settings/map; notifications; forecasting. |
| Cashier/staff | Location inventory read; create and complete permitted orders; permitted cancellation/return paths; own cashier history; own profile/password; notifications; presence. |
| Helper | Location inventory read; eligible pending/mine order views; atomic prepare/claim behavior; own helper history; permitted inventory approval requests; own profile/password; notifications; presence. |
| Unauthenticated caller | Login and explicitly designed recovery bootstrap only. It receives no operational row access. |

Because all application users reach Postgres as `anon`, granting a table to
`anon` grants it to every one of these roles before the application token is
examined. Role separation must therefore occur after server-side token
validation inside the RPC boundary.

## Operational function audit

Every live public operational function is `SECURITY DEFINER` with an explicit
runtime search path. Anonymous execute is granted to the client-facing RPCs and
denied to internal trigger functions.

All anonymous client-facing operational functions call
`private.require_app_session_v1` except:

- `profile_login_v1`, which validates credentials and rate limiting before
  issuing a session;
- `profile_restore_session_v1`, which hashes and validates the supplied token,
  expiry, revocation, and profile location directly; and
- `profile_logout_v1`, which hashes the supplied token and revokes its matching
  session directly.

No audited operational function uses `auth.uid()`.

## Malformed completed-order evidence

Aggregate read-only findings for the five empty completed snapshots:

- all five affect one location and one completion actor;
- all have positive totals, payment modes, and completion timestamps;
- two payment modes are represented;
- all use legacy, non-UUID-shaped order identifiers;
- none has a matching live `orders` row;
- none has an authoritatively linked transaction-history row;
- all have `snapshot_updated_at` earlier than `completed_at`, so the snapshot
  timestamps cannot establish a trustworthy event sequence; and
- current checkout validation rejects empty carts, but the completion RPC did
  not independently validate the stored item snapshot before this remediation.

This is consistent with legacy import/backfill or an older workflow, but the
available evidence does not prove the exact cause or prove that each row is a
genuine completed sale. It also cannot establish which products or quantities
were fulfilled. Inventory movements alone are insufficient because checkout
deduction and cancellation reversal must be reconciled with final payment.

### Recovery policy

Acceptable evidence, in descending order, is an immutable payment/receipt
record containing line items, an original POS/order export, a durable checkout
operation linked to exact product quantities, or another independently audited
source that can also reconcile cancellation and return state.

If sufficient evidence is found:

1. capture the untouched row in `private.order_history_data_issues`;
2. attach evidence identifiers/hashes, reviewer, reason, and timestamps;
3. prepare a one-order correction transaction with before/after assertions;
4. obtain explicit production approval;
5. update only the necessary historical fields; and
6. rerun exact RPC/Python reconciliation tests.

If evidence is insufficient, mark the issue `unrecoverable`, retain the
original row, and keep affected historical forecasts unavailable. The API must
return an explicit data-unavailable/review state; it must not convert these
records into zero demand or silently exclude them.

## Unified completion-time rule

Known timestamps use the half-open interval `start <= completed_at < end`.

For a completed record with no timestamp, the possible completion interval is
bounded by `created_at` and `snapshot_updated_at`. If that interval intersects
the requested period, SQL and Python reject extraction. A record proven
entirely outside the period does not block it. Missing or chronologically
invalid interval evidence is treated conservatively as relevant and therefore
fails closed.

The checked-in SQL is updated, but the deployed RPC is unchanged pending
isolated testing and production approval.

A final live catalog check confirmed that the missing-timestamp guard, private
issue ledger, and completed-snapshot validation triggers are not deployed.

## Future-record prevention

The remediation candidate adds a trigger to both `orders` and `order_history`
that rejects completed rows with:

- missing `completed_at`;
- missing or empty item arrays;
- invalid product UUIDs; or
- nonnumeric, nonfinite, zero, or negative quantities.

The completion RPC also validates its locked item snapshot before changing
status. Existing malformed records are deliberately not modified.

## Session storage

Opaque session tokens are now written through `flutter_secure_storage`.
SharedPreferences retains only nonsensitive login metadata. On first restore,
a legacy token is copied to secure storage and its plaintext copy is removed
only after the secure write succeeds. Login, password-token replacement,
logout, forced logout, profile invalidation, and store-hours logout all use the
same storage boundary. Server-side expiry, restoration, revocation, and
password-change rotation remain unchanged.

Web secure storage still depends on HTTPS/browser cryptography and is not an
OS keychain. Desktop/mobile deployments use their platform secure-storage
implementation.

## Isolation status

No Supabase development branch, dedicated test project, local CLI, or Docker
runtime is available. The existing harness now requires:

- different test and production URLs;
- different test and production project references;
- a database identity RPC whose stored project reference matches the expected
  test project;
- the explicit isolated-purpose marker;
- fixture-write authorization; and
- fixed test-owned identifiers for cleanup.

The allowed/denied behavioral suite remains blocked and is not reported as
passed.

## Automated verification

- Python regression and Stage 6B.5 contracts: **106 passed**.
- Secure session-storage tests: **7 passed**.
- Targeted Flutter forecasting tests: **11 passed**.
- Full Flutter regression: **109 passed, 1 failed**. The sole failure is the
  previously known GCash history `payment_reference` SQL assertion and was not
  modified in this stage.
- Full Flutter analysis: completed with **249 repository-wide info/warning
  findings** and no compilation error. Targeted analysis of the two new secure-session
  files reported **no issues**.
- Isolated Supabase suite: **0 executed, 1 skipped** because an authorized
  isolated project is not configured.

## Implementation status

- Secure local session storage: **implemented; automated tests added**.
- Python completion-time semantics: **implemented and unit tested**.
- SQL completion-time semantics and future-record triggers: **implemented in
  checked-in migration candidates; not deployed**.
- Security target-state revokes/RLS: **proposed and isolated-guarded; not
  deployable until remaining direct Flutter calls and realtime are migrated**.
- Five malformed-order repairs: **not performed; evidence currently
  insufficient**.
- Isolated Supabase behavioral verification: **blocked**.
