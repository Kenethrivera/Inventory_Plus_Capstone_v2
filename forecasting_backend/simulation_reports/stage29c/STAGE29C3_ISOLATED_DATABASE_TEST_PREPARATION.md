# Stage 2.9C-3 — Isolated Database Test Preparation

Date: 2026-11-11 (Asia/Manila)

Decision: **REVISE**

No connected Supabase data or schema was changed. No development branch was
created. Recommendation persistence remains disabled.

## 1. Isolated environment assessment

The connected Supabase MCP exposes branch-management capability. A read-only
`list_branches` call returned an empty list, so there is no existing branch that
can be treated as an approved disposable target.

Supabase's current branching documentation describes branches as separate,
data-less environments with branch-specific credentials. Branching requires an
eligible paid plan and branch creation can incur charges. The MCP `create_branch`
operation is a write and was deliberately not called.

Local alternatives are also unavailable on this workstation:

| Capability | Result |
|---|---|
| Supabase development branch | Available as a platform capability; none exists |
| Supabase CLI | NOT FOUND |
| `psql` | NOT FOUND |
| Docker | NOT FOUND |
| Podman | NOT FOUND |
| Configured Stage 2.9C DB target | ABSENT |
| Psycopg integration dependency | NOT INSTALLED (pinned separately) |

Therefore actual migration compilation/integration is **NOT VERIFIED**.

## 2. SQL compatibility findings

The proposal still matches the verified Inventory Plus schema contracts:

- PostgreSQL 17-compatible numeric/date/identity syntax;
- `products.id`, `locations.id`, and `transaction_history.id` are UUID;
- `profiles.id` is bigint;
- `products.product_quantity`, `products.unit`, and active/location fields exist;
- genuine receipts are `transaction_history.transaction_type = 'stock_in'` with
  positive `quantity_change`;
- `transaction_history` has no unit column, so the proposal's approved-request
  unit evidence/current canonical-unit fallback remains necessary;
- `private.require_app_session_v1(text)`, `extensions.digest`, and
  `trim_scale(numeric)` were previously verified live;
- product deletion can cascade receipt rows, while proposal snapshots have no
  external product/receipt FK and retain copied identity/receipt fields.

Compatibility remains provisional because PostgreSQL has not parsed or executed
the proposal in an isolated database. New public tables are not intended for
direct Data API access: RLS is enabled and direct privileges are revoked. Only
the service-role-only RPC boundary is exposed to FastAPI.

## 3. Prepared integration suite

Prepared files:

- `forecasting_backend/integration/stage29c/README.md`
- `forecasting_backend/integration/stage29c/requirements.txt`
- `forecasting_backend/integration/stage29c/stage29c_authorize_disposable.sql`
- `forecasting_backend/integration/stage29c/stage29c_cleanup.sql`
- `forecasting_backend/integration/stage29c/test_stage29c_isolated_database.py`
- `forecasting_backend/tests/test_stage29c_isolated_preparation.py`

The runner requires all of the following before any migration or fixture write:

1. a project ref different from `pzotcznujkuzymndluwl`;
2. a database URL that does not contain the protected ref;
3. an exact environment confirmation phrase; and
4. an independently operator-created database marker containing the same ref,
   purpose, and `allow_schema_writes = true`.

It also aborts when proposal objects pre-exist so it cannot assume ownership of
another test run. Its cleanup script has no `CASCADE` or `TRUNCATE` and is guarded
by the database marker/project ref.

Coverage includes compilation/signatures, Admin/session authorization, model and
stale-stock rejection, immutable snapshots, idempotency after stock changes,
partial/multiple receipts, concurrency/over-allocation, reconciliation states,
zero recommendations, product deletion, inventory non-mutation, and cleanup.

Forged predicted demand is rejected at the trusted FastAPI boundary, which
recalculates the approved 365-day LightGBM forecast. The SQL function deliberately
does not attempt to reproduce Python LightGBM; it validates approved metadata,
freshness, canonical stock/unit, and demand-minus-stock arithmetic.

## 4. Trusted FastAPI boundary verification

Code inspection and existing tests confirm:

- `recommendation_persistence_enabled` defaults to `False`;
- enabling requires server-only `SUPABASE_SECRET_KEY` (legacy service key only as
  a compatibility fallback); secrets use non-repr settings and are not returned;
- existing Inventory Plus Admin session and active location are revalidated;
- the backend reloads canonical 365-day history and independently calculates the
  existing LightGBM result;
- fallback/incomplete/experimental results are rejected;
- Flutter does not receive or call with the privileged credential; and
- idempotent lookup occurs before recalculation/fresh-stock comparison, preserving
  a valid retry after stock changes.

No production write endpoint was activated.

## 5. Tests actually executed

```text
python -m pytest \
  forecasting_backend/tests/test_stage29c_isolated_preparation.py \
  forecasting_backend/tests/test_stage29c_persistence_proposal.py \
  forecasting_backend/tests/test_stage29c_tracking_design.py \
  forecasting_backend/tests/test_stage29c_trusted_persistence_api.py -q

38 passed, 8 subtests passed, 1 deprecation warning
```

The warning is the existing Starlette `TestClient`/`httpx` deprecation warning.

```text
python -m unittest \
  forecasting_backend.integration.stage29c.test_stage29c_isolated_database -v

Ran 0 tests; skipped=1 (disposable database not configured)
```

That skip is the expected safety result and is not a database PASS.

## 6. Activation and rollback summary

The exact operator procedure is in the integration README. In short:

1. obtain explicit approval for branch creation and cost;
2. create a data-less disposable branch and verify its distinct ref;
3. run the read-only preflight on the branch;
4. install pinned Psycopg only in the test environment;
5. manually create the branch marker;
6. run trusted FastAPI tests, then the guarded database suite once;
7. confirm cleanup and branch deletion/reset separately;
8. only after an isolated PASS, seek separate production migration approval.

Production operational rollback is feature-flag-first:
`FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false`, restart FastAPI, preserve
history, investigate. Dropping production tables is destructive and is not part
of the prepared automatic cleanup.

Immediate rollback conditions include any authorization bypass, secret exposure,
idempotency conflict on an identical request, over-allocation, unexpected stock
or transaction mutation, loss of snapshot history on product deletion, incorrect
pending/reconciled semantics, or unexplained SQL/advisor failure.

## 7. Remaining blockers

- No approved disposable branch or local Supabase/Postgres exists.
- Branch plan eligibility and cost are not verified.
- The proposal has not been compiled by PostgreSQL.
- RPCs have not been exercised through branch PostgREST with a branch secret.
- Concurrency and rollback behavior have not run against a real database.
- The live project's previously documented RLS-disabled base-table risk remains
  separate and unchanged.

## Recommendation

**REVISE** until the user explicitly approves a disposable branch (and any cost),
the guarded suite runs successfully there, cleanup is confirmed, and the result
is reviewed. This stage is prepared for that run but is not a database
integration PASS.
