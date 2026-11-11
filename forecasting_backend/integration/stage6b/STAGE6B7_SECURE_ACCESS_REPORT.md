# Stage 6B.7 secure-access completion report

Date: 2026-11-05 (Asia/Manila)

## Status definitions

- **Locally implemented:** source and migrations exist in the working tree.
- **Locally tested:** static, mock, unit, or Flutter regression tests executed.
- **Database-tested:** executed against an explicitly isolated Supabase project.
- **Production-deployed:** applied to the production project.

Nothing in Stage 6B.7 is database-tested or production-deployed.

## Review of the original nine Stage 6B.6 RPCs

| RPC | Authorization and location | Output / validation review | Result |
|---|---|---|---|
| `inventory_snapshot_v1` | Any valid application role; location derived from `require_app_session_v1` | Changed from whole-row serialization to an explicit product allowlist | Locally hardened |
| `operational_orders_snapshot_v1` | Valid session; location derived server-side; Helper limited to pending unassigned/self-assigned work | Added boundary ordering validation. Helper output now excludes totals, discount, payment mode/reference, cash and change | Locally hardened |
| `current_profile_snapshot_v1` | Current session profile only | Explicit safe fields; password excluded | Review passed locally |
| `staff_configuration_snapshot_v1` | Admin only; session location only | Explicit fields; password excluded | Review passed locally |
| `staff_create_v1` | Admin only; location cannot be supplied by client | Bounded strings; password hashed server-side with the existing SHA-256 credential format; new staff/helper accounts require password change | Locally hardened |
| `staff_update_role_v1` | Admin only; target must share session location | Role allowlist. Existing sessions observe the new role because every protected RPC rejoins `profiles` | Review passed locally |
| `staff_profile_v1` | Admin only; same-location target | Explicit fields; password excluded | Review passed locally |
| `staff_delete_v1` | Admin only; same-location target; self-delete denied | Deleting the profile causes existing opaque sessions to fail their profile join | Review passed locally; FK behavior still needs database tests |
| `current_profile_update_v1` | Updates only the profile identified by the session | Added size bounds and explicit not-found failure | Locally hardened |

All nine are `SECURITY DEFINER`, have explicit search paths, qualify application
tables and private session validation, revoke default/public execution, and
grant execution only to `anon` and `service_role`. `anon` is only the transport
role: each function separately validates the opaque application token,
expiration, revocation, role, and location.

Admin delegation to create or promote another Admin matches the current Staff
Management UI. Cashier/staff and Helper sessions cannot call those operations.
Changing this delegation rule would be a business-policy change and was not
silently introduced.

Staff-management residual risks are explicit: there is no last-Admin guard,
an Admin can demote their own profile, and delete behavior still depends on the
live foreign-key graph. These are availability/audit policy questions rather
than cross-role authorization bypasses, and they require isolated database
tests before deployment. Role changes do not blindly trust a token-carried
role: subsequent protected calls rejoin the current `profiles` row. Deletion
similarly invalidates an otherwise unexpired session when that join no longer
finds the profile.

The established password format is unsalted SHA-256. Stage 6B.7 preserves it
for compatibility, but this is a remaining credential-hardening risk. A later
versioned migration should introduce a slow password hash and upgrade hashes on
successful login rather than changing all existing credentials at once.

## Additional secure product slice

`database/stage_6b7_product_access_rpcs.sql` adds six session-authorized RPCs:

1. `forecast_product_snapshot_v1`
2. `product_details_update_v1`
3. `product_set_active_v1`
4. `product_delete_inactive_v1`
5. `product_shelf_bin_update_v1`
6. `product_map_assignment_v1`

They are Admin-only, derive location from the session, and validate target
products against that location. Disable/delete checks for open orders under the
same transaction. Status changes and deletion write their audit rows inside the
database operation, avoiding the former split product/journal mutation.

Flutter product paths are gated by
`INVENTORY_PLUS_SECURE_PRODUCT_ACCESS_V1=false`. The existing Stage 6B.6 gate
also remains default-off. The forecasting backend no longer performs a direct
REST `products` query; it uses `forecast_product_snapshot_v1`.

## Password recovery

The insecure client path was removed:

- no anonymous profile email/role lookup;
- no Flutter-generated OTP;
- no client-side OTP comparison;
- no direct anonymous password update;
- no EmailJS public-client recovery request.

Self-service recovery now fails closed and directs the user to the existing
Admin reset workflow. A functioning replacement is **blocked**, because no
trusted server-side delivery provider is configured. No recovery challenge
table or endpoint was enabled without that provider.

A future implementation must generate a random challenge server-side, store
only a digest, expire it, enforce attempt/rate limits, deliver through a
verified channel, consume it once, change the password through a protected
function, and revoke existing sessions. Replay/expiration/success tests remain
pending until this infrastructure exists.

## Realtime replacement

A backend authenticated polling/SSE fallback is locally implemented at
`GET /v1/sync/events`:

- disabled by default through `SYNC_EVENTS_ENABLED=false`;
- validates the opaque session before opening the stream;
- revalidates on every interval, so revocation/expiration closes the stream;
- emits domain names and sequence numbers only, never row payloads, names, or
  location IDs;
- applies role-specific domain allowlists;
- enforces a minimum five-second interval.

This is a safe invalidation fallback, not a live database event subscription.
It has not yet been wired into Flutter `RealtimeSyncService`; the old Supabase
channels therefore remain active. Direct Realtime grants cannot be revoked yet.

## Isolated environment

The Supabase connector is available, but branch listing still returns zero
branches. The connected project is treated as production. No branch, marker,
migration, fixture, or write was created.

Exact setup and initial behavior matrix are documented in
`STAGE6B7_ISOLATED_SETUP.md`. Isolated tests remain blocked.

## Remaining direct dependencies

The following groups still prevent anonymous table privilege revocation:

- notification reads, read-state writes, resolution, and stock-alert state;
- staff presence heartbeat/list and staff-session logs;
- threshold, measurement, payment, and store-access settings;
- legacy transaction/product history and reporting helpers;
- map snapshot read;
- export reminder logs;
- product and GCash storage upload/delete policies;
- compatibility branches retained behind default-off migration gates;
- direct Postgres Changes channels in `RealtimeSyncService`.

The obsolete direct `forecasting_controller.dart` query also remains pending
removal after final call-site confirmation.

## Verification executed

| Check | Actual result | Scope |
|---|---:|---|
| `cd forecasting_backend; python -m unittest discover -s tests -v` | 119 passed | Local Python regression, static SQL contracts, API mocks |
| Targeted Flutter authentication/staff/inventory/navigation tests | 34 passed | Local Flutter unit/widget tests |
| `flutter test --reporter compact` | 109 passed, 1 failed | Full Flutter regression |
| `flutter test test/gcash_reference_test.dart --reporter expanded` | 3 passed, 1 failed | Confirms the known unrelated missing `payment_reference` history field |
| Targeted Dart analysis of authentication, login, and inventory controller | 0 errors, 0 warnings, 14 info diagnostics; exit 1 under current analyzer settings | Existing style/deprecation/package diagnostics remain |
| `python -m unittest integration.stage6b.test_stage6b_isolated -v` | 0 executed, 1 skipped | Correctly blocked because no verified isolated environment is configured |

The Flutter failure is not caused by Stage 6B.7: the history RPC does not
include `payment_reference`, while the existing regression test requires it.
That separately tracked issue was intentionally not changed in this stage.
Mock/static tests are not evidence of live Supabase authorization behavior.

## Deployment sequence

1. Provision and mark a dedicated isolated project.
2. Apply existing base/session migrations.
3. Apply Stage 6B.5 integrity and Stage 5A forecasting SQL.
4. Apply Stage 6B.6 RPCs, then Stage 6B.7 product RPCs.
5. Execute role, session, cross-location, sensitive-output, and workflow tests.
6. Enable each Flutter gate separately in the isolated build.
7. Complete notifications, presence, settings, history, map, exports, and
   storage migrations.
8. Wire the authenticated invalidation stream into `RealtimeSyncService` and
   test reconnect/session renewal before disabling old channels.
9. Configure and test server-side password-recovery delivery.
10. Capture the exact privilege/policy rollback manifest.
11. Only when both readiness flags are true, test restrictive grants/RLS in the
    isolated project.
12. Production requires a separate explicit approval and the same additive-
    first sequence.

Rollback restores the previous application build and the exact reviewed grant
manifest. New additive RPCs may remain installed; a faulty function can have
its execute grant revoked. Never restore blanket anonymous profile/password
access as a generic rollback.

## Readiness

Stage 6B.7 is **not ready for Stage 6C**. The original RPC review, product
slice, fail-closed password recovery, and backend invalidation fallback are
locally implemented and locally testable. Database behavior, the remaining
direct access groups, Flutter realtime transport, and working secure recovery
remain blockers.

