# Stage 2.9C Supabase-Aware Persistence Review

Date: 2026-11-11 (Asia/Manila)

Decision: **REVISE — proposal corrected, persistence remains inactive**

No Supabase writes, migrations, write RPCs, test fixtures, or configuration
changes were executed. All live inspection used catalog/data `SELECT` queries.

## Live schema findings

| Area | Verified live result |
|---|---|
| Locations | 1 row; `locations.id uuid` primary key |
| Profiles | 6 rows; `profiles.id bigint`; role check permits `staff`, `admin`, and `helper`; `is_active boolean` exists |
| Products | 37 rows, all active; `id uuid`, unique `sku`, `product_name text`, `product_quantity numeric`, `location_id uuid`, `unit text`, `is_active boolean` |
| Transaction history | 34,446 rows; `id uuid`, `created_at timestamptz`, nullable product/user/location links, `transaction_type text`, `quantity_change numeric`, `new_quantity numeric`, operation fields; **no unit column** |
| Inventory movements | `public.inventory_movements` does not exist |
| Restock receipts | 1,404 `stock_in` rows; all have positive quantity and non-null product/location; range 2022-11-10 through 2026-11-09 |
| Replenishment config | 12 rows; composite PK `(product_id, location_id)`; supplier unit/conversion and verified incoming/backorder fields; **no stored `inventory_unit` column** |
| Existing recommendation objects | No live table/function/trigger names conflict with the revised proposal |

`forecast_replenishment_config_v1` derives its returned inventory unit from the
product context; the underlying configuration table does not store that field.

### Foreign keys and deletion

- `transaction_history.product_id -> products.id ON DELETE CASCADE`.
- `forecast_replenishment_configs.product_id -> products.id ON DELETE CASCADE`.
- `approval_requests.product_id -> products.id` uses `NO ACTION`.
- Product, transaction-history, and replenishment-config location/profile links
  otherwise use the verified live actions reported by the preflight.

The current Flutter default has `INVENTORY_PLUS_SECURE_PRODUCT_ACCESS_V1`
disabled. It disables products with a direct `is_active` update and permanently
deletes an already-inactive product with a direct product-table delete. The
optional `product_delete_inactive_v1` and `product_set_active_v1` RPCs are not
deployed. Consequently:

- adding a recommendation FK with `RESTRICT` to products or transaction history
  would introduce a new deletion blocker;
- the revised tables keep immutable product/receipt/actor/location snapshots and
  intentionally have no external FK to those operational tables;
- the allocation and reconciliation tables reference only the immutable
  recommendation snapshot;
- the pre-existing `approval_requests` `NO ACTION` relationship can already
  prevent some product deletions and is not changed here;
- no inactive product existed during inspection, so deletion was not exercised
  against staging.

### Restock recording and units

Both verified write paths record genuine receipts as `transaction_type =
'stock_in'` with a positive `quantity_change` equal to the product inventory
delta:

- `adjust_inventory_quantity_v1` performs the inventory update and history
  insert atomically;
- `approve_inventory_approval_request_v1` performs the approved restock and
  links the transaction when using the current approval path.

Only 1 of the 1,404 historical `stock_in` rows has a linked approved-restock
request with an immutable unit. The remaining rows can be matched only while
the current product unit still verifies the canonical unit. The revised design
therefore does not guess units and does not apply supplier pack conversion to
`quantity_change`: supplier conversion belongs upstream, before the canonical
inventory receipt is recorded.

### Authorization boundary

The live session validator is:

`private.require_app_session_v1(p_session_token text)`

It is `STABLE SECURITY DEFINER` and returns profile ID, role, location, and
profile name. The forecasting/product/replenishment RPCs and inventory write
RPCs also use the app-session pattern.

The current FastAPI adapter deliberately uses only
`SUPABASE_PUBLISHABLE_KEY`. That is adequate for the existing app-session RPCs,
but it cannot attest that a submitted numeric prediction was genuinely produced
by the approved LightGBM calculation. An anonymous/client-callable save RPC
would therefore permit forged forecast snapshots.

The revised proposal:

- grants tracking RPC execution only to `service_role` and `postgres`;
- still requires a valid Admin Inventory Plus session and active location;
- hard-constrains model `lightgbm`, version `1`, 365 history days, a 28-day
  horizon, and `experimental_model = false`;
- validates current product, unit, stock, and forecast freshness on first save;
- returns an existing immutable snapshot on a byte-equivalent retry before
  consulting current stock;
- rejects reuse of a request ID with a different original payload.

No FastAPI persistence endpoint or service-role secret setting was added. Those
must be separately designed and reviewed before this SQL can be activated.

## Differences from the original proposal

| Original assumption/problem | Revised design |
|---|---|
| Product/location/profile/transaction FKs used `RESTRICT` | External FKs removed; immutable UUID/ID/name/SKU/unit/actor/location snapshots preserve history without blocking deletion |
| Retry compared the old snapshot to current product stock | SHA-256 of the original request payload is checked first; later stock changes do not break a genuine retry |
| Model name and predicted demand were trusted request fields | Only a server-only RPC boundary is allowed; SQL additionally enforces the approved standard LightGBM contract and live first-save stock |
| Receipt allocation copied the recommendation unit without verifying receipt evidence | Approved request unit is preferred; otherwise current product canonical unit is required; unknown/mismatched units are rejected |
| Receipt FK would block the live product-delete cascade | Receipt ID and receipt facts are immutable snapshots, not an external FK |
| Any matched amount looked final | `pending`, `partially_received`, and owner-confirmed `reconciled` are separate states |
| Missing receipt aggregation could appear as zero | Pending receipt quantity and differences are `NULL`; zero is recorded only after explicit no-receipt reconciliation |
| Variance had only absolute/percentage output | Signed difference, absolute difference, and signed percentage variance (when suggested quantity is positive) are distinct |
| Write RPCs were executable by `anon` | All proposal RPCs are service-role-only plus Admin app-session validation |

## Read-only preflight result

The checked-in preflight was executed against staging using its first
read-only result set. Results were 10 PASS, 1 FAIL, and 4 NOT VERIFIED.

| # | Check | Result | Evidence |
|---:|---|---|---|
| 1 | Required tables | PASS | 6/6 found |
| 2 | Required columns/types | PASS | 31/31 matched |
| 3 | Required function signatures | PASS | 6/6 matched |
| 4 | Session validator contract | PASS | Stable security-definer signature matched |
| 5 | Stock receipt representation | PASS | 1,404 valid positive/scoped `stock_in` rows |
| 6 | Receipt unit contract | PASS | No history unit; product unit is canonical evidence source |
| 7 | Approved-request unit coverage | NOT VERIFIED | Only 1/1,404 receipts has immutable approval-unit evidence |
| 8 | Transaction-history deletion action | PASS | Product FK is `ON DELETE CASCADE` |
| 9 | Proposal name conflicts | PASS | 0 live conflicts |
| 10 | SHA-256 prerequisite | PASS | `extensions.digest(bytea,text)` exists |
| 11 | Inventory-movements dependency | PASS | Table absent; proposal uses transaction history |
| 12 | Deletion exercise | NOT VERIFIED | 0 inactive products; no destructive test permitted |
| 13 | Secure product-deletion RPC | NOT VERIFIED | Optional RPC is not deployed; repository default path was reviewed instead |
| 14 | Existing operational-table RLS posture | FAIL | Products, transaction history, locations, and profiles have RLS disabled |
| 15 | Trusted persistence caller | NOT VERIFIED | Current FastAPI has no server-only persistence credential/path |

The RLS failure is an existing broader security condition, not introduced or
modified by this proposal. Live grants show broad table privileges on several
RLS-disabled operational tables. Enabling RLS without first supplying complete
replacement policies/RPC coverage could break the application, so no unrelated
security migration is included here. The new proposal tables themselves enable
RLS, expose no direct policies, revoke direct access, and are reachable only via
the reviewed service-role functions.

## Local behavioral tests

Command:

```text
python -m pytest forecasting_backend/tests/test_stage29c_persistence_proposal.py forecasting_backend/tests/test_stage29c_tracking_design.py forecasting_backend/tests/test_preliminary_restocking_insight.py -q
```

Result: **26 passed**.

Covered behavior:

- immutable snapshot formula and SQL security contract;
- same-payload idempotent retry after inventory changes;
- conflicting request-ID retry rejection;
- stale stock, stale forecast, experimental model, and untrusted caller rejection;
- product deletion preserving saved snapshot/allocation fixtures;
- genuine later `stock_in` matching;
- partial and multiple receipt allocation;
- concurrent over-allocation prevention;
- unknown and mismatched/supplier-pack unit rejection;
- pending receipt quantity remaining unknown instead of zero;
- explicit reconciliation and zero-recommendation percentage behavior;
- no inventory/history/purchase-order mutation in the proposal.

These are isolated contract tests. The migration was not compiled or applied in
the connected Supabase project, as required.

## Remaining risks and next review gate

1. **Trusted calculation boundary:** FastAPI needs a separately reviewed,
   server-only service credential and must persist the exact preliminary result
   generated by the approved 365-day LightGBM path. Never expose that credential
   to Flutter or logs.
2. **Historical unit evidence:** most imported receipts lack an immutable unit
   snapshot. New matching is conservative and may be unavailable after a unit
   change or product deletion; saved allocations remain intact.
3. **Existing deletion blockers:** approval history can already block product
   deletion. This proposal does not add a blocker or fix that unrelated policy.
4. **Existing table exposure:** RLS/grant hardening needs its own migration and
   full application access audit.
5. **Database compile/integration test:** run the proposal only in an isolated
   Supabase branch/local stack after approval, then test RPC grants, concurrency,
   product deletion, and rollback before considering staging.

Final recommendation: **REVISE**. The local SQL proposal is aligned to the live
schema and suitable for manual review, but persistent tracking must remain
inactive until the trusted FastAPI boundary and isolated database integration
test are completed.
