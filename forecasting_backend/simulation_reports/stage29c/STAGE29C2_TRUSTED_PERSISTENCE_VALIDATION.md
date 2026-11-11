# Stage 2.9C-2 Trusted Persistence and Integration Validation

Date: 2026-11-11 (Asia/Manila)

Recommendation: **REVISE**

The trusted FastAPI boundary is implemented locally and disabled by default.
The connected Supabase project was inspected with `SELECT` queries only. No
migration, write RPC, insert, update, delete, fixture, grant, configuration
change, or Flutter activation was performed.

## Live preflight investigation

The reproducible preflight still reports **10 PASS, 1 FAIL, 4 NOT VERIFIED**.

### The one FAIL

| Check | Exact result | Interpretation |
|---|---|---|
| 14 — current operational-table RLS posture | `products`, `transaction_history`, `locations`, and `profiles` all have RLS disabled | Genuine existing production security risk. It is not caused by recommendation tracking and is intentionally not redesigned in this stage. Existing broad table grants make the disabled RLS material. |

Supabase recommends RLS on exposed tables and server-only handling for secret
keys. This requires a separate application-wide access migration because simply
enabling RLS without complete policies/RPC coverage would break current flows.

### The four NOT VERIFIED checks

| Check | Exact result | Classification |
|---|---|---|
| 7 — approved-restock unit coverage | Only 1 of 1,404 `stock_in` rows has a linked approved-request unit snapshot | Real historical-data limitation. The proposal conservatively requires that snapshot or the current product canonical unit and rejects unknown/mismatched units. |
| 12 — inactive-product deletion exercise | All 37 products are active | Expected read-only limitation. A destructive deletion test is forbidden on the connected project. Local behavioral mocks confirm snapshot independence, but PostgreSQL integration remains unverified. |
| 13 — secure product-deletion RPC deployment | `product_delete_inactive_v1` is absent | Verified deployment difference, not a recommendation-schema incompatibility. Flutter currently defaults to direct disable/delete operations. The proposal has no external product/receipt FK, so it does not add a deletion blocker. |
| 15 — trusted persistence caller deployed | Database metadata cannot prove a deployed trusted FastAPI caller | Expected. The caller is now implemented locally, gated off, and not deployed or activated. It remains NOT VERIFIED for the connected project. |

### Expected missing proposal objects

The connected project correctly has none of the proposal tables, triggers, or
RPCs. Live checks confirmed:

- zero proposal object-name conflicts;
- `forecast_recommendation_snapshot_by_request_v1` is absent;
- `save_forecast_recommendation_snapshot_v1` is absent;
- PostgreSQL is 17.6;
- `pg_catalog.trim_scale(numeric)`, `extensions.digest(bytea,text)`, and
  `private.require_app_session_v1(text)` exist.

Their absence is expected because the proposal has not been deployed. It is not
a failed schema compatibility check.

## SQL proposal review and update

The proposal remains aligned with the verified live types, constraints, and
deletion actions. One RPC was added:

`forecast_recommendation_snapshot_by_request_v1(text, uuid) -> jsonb`

It permits the trusted server to resolve an idempotency key before recalculating
against changed stock. It is Admin-session/location scoped and executable only
by `service_role` and `postgres`.

The SQL continues to enforce:

- immutable external identity snapshots with no product, location, profile, or
  transaction-history FK;
- only model `lightgbm`, version `1`, 365 history days, 28 forecast days, and
  `experimental_model = false`;
- first-save stock/unit/freshness validation;
- original-payload SHA-256 idempotency;
- recommendation and receipt advisory locks;
- explicit genuine later `stock_in` matching;
- receipt over-allocation prevention across recommendations;
- pending, partially received, and owner-confirmed reconciled states;
- `NULL` received quantity while receipts remain unknown;
- no inventory, movement, product, purchase-order, or forecast mutation.

## Trusted FastAPI boundary

### Configuration and secret handling

Persistence defaults to disabled:

```text
FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false
```

Future activation requires a backend-only environment value:

```text
FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=true
SUPABASE_SECRET_KEY=<server-only sb_secret key>
```

The setting fails closed when enabled without a distinct secret key. The secret
field is excluded from settings representations, is never placed in responses,
and is never logged. New `sb_secret_` keys are sent only as the Supabase API-key
header; legacy service-role JWTs remain supported for controlled migration.
Flutter receives neither credential.

### Authenticity boundary

The save endpoint never persists client demand or stock directly:

1. Authenticate the existing Inventory Plus session and require Admin/location
   scope.
2. Resolve the request ID through the server-only lookup RPC. An exact retry
   returns the saved immutable snapshot without consulting changed stock.
3. For a new request, reject stale/future/inconsistent timestamps and malformed
   28-day arithmetic.
4. Reload exactly 365 days through the existing canonical forecasting adapter.
5. Run the existing production `LightGBMForecaster` and existing preliminary
   demand-minus-stock calculator.
6. Reject Mean28/cold-start fallback, experimental models, and incomplete
   demand or stock.
7. Compare every displayed client candidate field against the independently
   calculated result.
8. Send only the trusted server result to the service-role-only database RPC.
9. Let SQL recheck live stock/unit, closing the race between calculation and
   insert.

No forecasting algorithm, model parameters, or replenishment formula changed.

### Prepared endpoints

| Method and path | Purpose |
|---|---|
| `POST /v1/forecasting/products/{product_id}/recommendation-snapshots` | Recompute, verify, and save the approved standard-LightGBM snapshot |
| `POST /v1/forecasting/recommendations/{id}/receipt-allocations` | Explicitly allocate a genuine receipt through the guarded database RPC |
| `POST /v1/forecasting/recommendations/{id}/reconcile` | Explicit owner completion confirmation |
| `GET /v1/forecasting/recommendations` | Read tracking states and comparisons |

When the feature flag is false, the routes return HTTP 503 and perform no
persistence call. No Flutter code invokes them in this stage.

## Isolated database validation

Status: **NOT VERIFIED**.

The workstation has no Docker, Podman, PostgreSQL/`psql`, Supabase CLI, running
PostgreSQL/Docker service, or usable WSL environment. The connected Supabase
project was not used as a substitute because writes are forbidden.

Consequently, the following remain unverified in a real PostgreSQL runtime:

- proposal compilation and exact created function signatures;
- runtime grants and PostgREST exposure;
- Admin/non-Admin database authorization behavior;
- real advisory-lock concurrency and over-allocation behavior;
- product deletion with actual cascade locks;
- receipt reconciliation under concurrent transactions;
- rollback and advisor output after creation.

The SQL must be run next in a disposable local Supabase stack or isolated
Supabase branch, never first in the connected staging project.

## Local automated validation

Relevant suite:

```text
python -m pytest tests/test_api.py tests/test_api_supabase_adapter.py \
  tests/test_startup_configuration.py \
  tests/test_preliminary_restocking_insight.py \
  tests/test_stage29c_persistence_proposal.py \
  tests/test_stage29c_tracking_design.py \
  tests/test_stage29c_trusted_persistence_api.py -q
```

Result: **99 passed, 6 subtests passed**, with one existing Starlette/httpx
deprecation warning.

Covered locally:

- secure setting fail-closed behavior and secret non-disclosure;
- standard 365-day LightGBM recomputation;
- experimental and fallback exclusion;
- forged, stale, mismatched, and conflicting candidate rejection;
- idempotent retry without stock reload;
- Admin-only API access;
- disabled boundary produces no write;
- receipt, reconciliation, and tracking endpoint contracts;
- privileged tracking RPC pagination beyond the 1,000-row PostgREST page;
- snapshot persistence mocks, product deletion compatibility, partial/multiple
  receipts, unknown units, concurrent allocation, and over-allocation;
- preliminary save does not mutate inventory fixtures;
- static SQL checks for append-only records, grants, formula, deletion-safe
  snapshots, and absence of inventory mutations.

The complete backend suite produced **326 passed, 37 subtests passed, 1 failed**.
The single failure is unrelated and pre-existing:
`test_stage21_import_proposal.py` expects the Stage 2.1 import safety switch to
be `false`, while the current user-owned SQL file contains `true`. That file was
not modified in this stage.

## Remaining risks

1. Real PostgreSQL compilation/integration is still missing and blocks
   deployment approval.
2. The existing operational-table RLS exposure requires a separate security
   project; it is not safe to enable RLS piecemeal here.
3. Most historical receipts lack immutable unit evidence, limiting later
   matching after product unit changes or deletion.
4. The proposed public-schema security-definer RPCs depend on exact EXECUTE
   revocations. Isolated testing and Supabase Security Advisor must confirm the
   final ACLs.
5. Service secrets bypass RLS and therefore make FastAPI authorization, secret
   storage, rotation, network exposure, and log redaction critical.
6. No Flutter save controls are active, so end-to-end UI behavior is outside
   this stage.

## Decision

**REVISE.** The trusted server boundary and local contracts are prepared and
tested, but deployment readiness cannot be claimed without compiling and
exercising the migration in an isolated PostgreSQL/Supabase environment. Keep
the feature flag false and do not apply the connected-project migration yet.

References:

- Supabase API keys: https://supabase.com/docs/guides/getting-started/api-keys
- Supabase RLS: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase changelog: https://supabase.com/changelog.md
