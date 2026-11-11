# Stage 6B.6 secure access migration report

Date: 2026-11-05 (Asia/Manila)

## Outcome

The repository-wide Flutter access audit is complete and recorded in
`database/STAGE6B6_FLUTTER_DATABASE_ACCESS_AUDIT.md`.

An additive first migration slice is implemented locally for:

- location-scoped inventory snapshots;
- role/location-scoped operational order snapshots;
- the current user's safe profile snapshot and update;
- Admin-only safe staff snapshots and staff create/detail/role/delete
  operations.

No Stage 6B.6 SQL was applied to Supabase. No production data, grants, RLS
policies, orders, inventory, or storage objects were changed.

## Supabase environment check

The Supabase MCP connection initialized successfully. It identified the
currently connected project as project ref `pzotcznujkuzymndluwl`. Branch
listing returned zero development branches. Because this is the existing
connected project and no isolated marker/project was available, it was treated
as production for safety.

No branch was created because branch creation may incur charges and requires
explicit cost authorization. No migration or fixture tool was called.

## Local SQL interfaces

`database/stage_6b6_secure_access_rpcs.sql` contains nine additive functions:

1. `inventory_snapshot_v1`
2. `operational_orders_snapshot_v1`
3. `current_profile_snapshot_v1`
4. `staff_configuration_snapshot_v1`
5. `staff_create_v1`
6. `staff_update_role_v1`
7. `staff_profile_v1`
8. `staff_delete_v1`
9. `current_profile_update_v1`

Each function is `SECURITY DEFINER`, uses an explicit safe search path, and
calls `private.require_app_session_v1`. Location comes from the validated
session, not from Flutter. Staff functions require Admin. Staff responses
exclude password hashes. Staff creation hashes the supplied password inside
the function. The file only adds/replaces functions and execute grants; it does
not revoke table grants or enable RLS.

The helper order snapshot is deliberately narrower than Admin/Cashier output:
only pending orders that are unassigned or assigned to that Helper are
returned. This must be verified against the isolated behavior matrix before
deployment.

## Flutter migration

`InventoryController` contains the new RPC paths for the first migration slice
behind `INVENTORY_PLUS_SECURE_ACCESS_V1`. The compile-time gate defaults off so
the checked-out application continues to work before the additive functions
are deployed. An isolated build may enable it only after applying the SQL.
The controller still owns canonical business state and refetch behavior;
`RealtimeSyncService` remains transport-only. No page-specific subscriptions
were added.

The source audit retains the legacy `.from(...)` branches needed for the
default-off compatibility gate, plus 13 Realtime channel occurrences and four
storage access occurrences across `lib/`. The access matrix
classifies every remaining dependency and names its required replacement.
Therefore direct-table migration is incomplete and the Stage 6B.5 restrictive
target migration must remain guarded.

## Realtime target

Direct Supabase Postgres Changes cannot identify an Inventory Plus opaque
application session. Client channel names and filters are not authorization.
The recommended replacement is one backend-authenticated WebSocket/SSE stream
per application session:

1. validate the opaque token server-side;
2. bind user, role, and location from the session;
3. subscribe server-side;
4. emit domain invalidations only;
5. let domain controllers refetch through authorized RPCs.

This preserves the existing synchronization ownership model. A Supabase Auth
or custom-JWT conversion is an alternative larger identity migration.

## Password-recovery blocker

The logged-out forgot-password flow reads profile email/role and writes the
password directly as `anon`; its OTP is generated and verified in Flutter.
It cannot be made secure merely by wrapping the current client assertions in a
`SECURITY DEFINER` function. It requires a rate-limited, non-enumerating,
server-side challenge/delivery/verification workflow. Until that exists,
anonymous profile grants cannot be safely removed without intentionally
disabling password recovery.

## Tests actually executed

- Full Python suite:
  `python -m unittest discover -s tests -p "test_*.py" -v`
  - **110 passed, 0 failed**.
- Stage 6B static contract module:
  `python -m unittest tests.test_stage6b_contract -v`
  - **14 passed, 0 failed** (included in the full 110).
- Targeted Flutter staff tests:
  `flutter test --reporter expanded test/staff_management_test.dart`
  - **6 passed, 0 failed**.
- Targeted Flutter order/inventory/forecasting set:
  `flutter test --reporter expanded test/helper_assignment_test.dart test/inventory_approval_test.dart test/forecasting_api_service_test.dart test/forecasting_page_test.dart test/session_storage_test.dart`
  - The runner executed **48 tests, all passed**; the secure-session file was
    subsequently covered by the full suite.
- Full Flutter suite:
  `flutter test --reporter compact`
  - **109 passed, 1 failed**.
  - The only failure is the existing
    `gcash_reference_test.dart` durable-history `payment_reference` expectation.
    It is unrelated to Stage 6B.6 and was not changed.
- Targeted analysis:
  `flutter analyze lib/logic/inventory_controller.dart`
  - Completed with **5 info-level findings**, no errors or warnings. The infos
    are existing unnecessary/dependency import notices and two empty catches.
- Isolated integration guard:
  `python -m unittest integration.stage6b.test_stage6b_isolated -v`
  - **0 executed, 1 skipped**: isolated environment is not configured.

The first combined targeted Flutter run failed to compile after a crypto import
was removed while still used elsewhere in the controller. The import was
restored, and the targeted plus full reruns produced the results above. This
intermediate failure is not counted as a passing result.

## Remaining blockers and risks

- The new SQL has static tests only; PostgreSQL execution, grants, role denial,
  expired-session denial, and cross-location denial are unverified.
- Inventory/product mutations, notification state, presence, settings,
  storage, exports, legacy history paths, and map reads still contain direct
  anonymous access.
- Realtime transport cannot be secured with current opaque sessions without an
  authenticated relay or identity migration.
- Password recovery needs server infrastructure.
- Storage bucket policies and signed upload/delete behavior need isolated
  testing.
- Five legacy malformed completed orders remain untouched and unresolved.
- Canonical supplier, PO, backorder, safety-stock, and availability-history
  sources remain undefined.
- Stage 5A live behavioral verification remains pending.

## Readiness

Stage 6B.6 is **not complete** and the system is **not ready for Stage 6C
end-to-end validation**. The access matrix and first additive slice are ready
for isolated-project deployment and behavioral testing. Production privilege
revocation, RLS tightening, and Stage 7 deployment remain explicitly blocked.

