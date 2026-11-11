# Stage 2.9C — Demand-based restocking insight checkpoint

## Decision

**PASS for the calculation/read-only UI checkpoint. Persistent recommendation
tracking remains deliberately inactive pending schema review.**

This result does not change a forecast model, the active model selection,
inventory, purchase orders, or replenishment-policy calculations.

## Implemented behavior

Every product analysis now contains a separate 28-day preliminary restocking
insight:

`max(0, ceiling(existing LightGBM demand - current saleable inventory))`

- The forecast is obtained through the existing product-specific LightGBM path
  using at most the standard 365-day history window.
- The planning horizon is always 28 days, even when the displayed forecast uses
  another horizon or model.
- Seasonal Experimental remains display-only and is never the basis of this
  quantity.
- Supplier lead time, review period, incoming orders, backorders, safety stock,
  MOQ, pack size, capacity, and supplier availability are not inputs to this
  preliminary calculation.
- Missing incoming/backorder values are explicitly not treated as verified
  zero.
- The existing detailed periodic-review policy remains unchanged and can still
  return `NEEDS_REVIEW` when its verified inputs are missing.

If current stock is missing or invalid, predicted demand is still displayed but
no quantity is calculated. If there is no sales history, the model's zero
cold-start placeholder is shown as unknown demand and no preliminary quantity
is calculated. Insufficient but non-empty history can produce a provisional
quantity with a limitation warning.

## Persistence assessment

Existing `product_forecasts` is not appropriate: it is name-based, mutable, and
does not retain a product/location decision snapshot. `transaction_history` is
the authoritative inventory movement ledger. A genuine received restock is a
positive `stock_in` quantity; it is not a supplier order or backorder.

The review-only proposal in
`database/stage_2_9c_recommendation_tracking_PROPOSAL.sql` adds:

1. An immutable recommendation snapshot containing the authenticated location,
   product, saver, forecast basis/version/timestamps, period, forecast demand,
   stock observed at save time, formula result, unit, and assumptions.
2. An immutable explicit allocation between a saved recommendation and a later
   positive `transaction_history.stock_in` receipt.
3. Admin/session-scoped security-definer functions for idempotent save, explicit
   receipt matching, and read-only comparison.
4. RLS, revoked direct client access, check constraints, foreign-key indexes,
   idempotency keys, and append-only triggers.

The matching function requires the same location and product, a receipt later
than the recommendation, a positive quantity, and an explicit allocated
quantity. One recommendation can have multiple receipts; one receipt can be
partially allocated without allocating more than the amount received. Repeated
matching of the same pair is idempotent; a changed retry is rejected.

Comparisons report attributed actual receipts, absolute difference, and a
percentage difference only when the saved suggestion is greater than zero.
These are **restock variances**, not forecast errors. Forecast accuracy must
continue to compare a frozen demand forecast with completed sales over the same
completed period. Receipts are never treated as customer demand.

### Review point before migration approval

The proposed foreign keys use `ON DELETE RESTRICT` to preserve the audit trail.
Once a snapshot exists, deleting its product/location/profile or matched
movement would be blocked. Inventory Plus normally deactivates products, but
this retention behavior must be explicitly approved before execution.

The current movement schema stores `quantity_change` in the canonical inventory
unit and does not preserve the original supplier order unit. Therefore the
proposal compares only inventory-unit receipts. It does not invent an original
supplier order quantity or conversion.

## Validation

Automated backend/API coverage verifies:

- missing supplier and balance-policy inputs do not block the preliminary
  result;
- demand-minus-stock arithmetic, ceiling, zero floor, missing stock, invalid
  stock, and no-history handling;
- Seasonal Experimental and Existing LightGBM return the same preliminary
  basis/result for the same history;
- the response states that incoming/backorders were not treated as zero;
- the proposal is review-only, append-only, session/Admin scoped, explicitly
  matches only eligible `stock_in` receipts, prevents over-allocation, keeps
  zero-suggestion percentages null, and contains no inventory mutation SQL.

Directly affected backend/API tests: **45 passed** before adding the six static
proposal checks. The broader Python discovery run executed 293 tests and had
one unrelated pre-existing failure: the Stage 2.4 import proposal safety switch
is currently `true`, while its guard test expects `false`. Stage 2.9C did not
change that import file.

Dart analysis of the changed client/page/tests reported **no issues**. The
Flutter test runner could not start because the local Flutter SDK lock was held
before compilation; no widget-test result is claimed.

## Remaining work after approval

Do not execute the proposal yet. After design approval:

1. Re-inspect the live schema and run the migration manually in staging.
2. Add authenticated API save/list/match endpoints and explicit Admin UI
   actions.
3. Add database integration tests for immutable snapshots, concurrent retry
   idempotency, partial/multiple receipt allocation, unmatched receipts, and
   RLS/role denial.
4. Keep recommendation tracking observational; do not mutate inventory or
   create purchase orders.
