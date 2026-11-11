# Stage 2.9B Replenishment Validation

**Decision: PASS**

All calculations use isolated deterministic fixtures. No Supabase data, forecast model, inventory quantity, or purchase-order state was changed.

## Scenario results

| Scenario | Result | Status | Inventory position | Reorder point | Target | Suggested |
|---|---|---|---:|---:|---:|---:|
| concrete_blocks_missing_verified_inputs | PASS | needs_review | None | None | None | None |
| concrete_blocks_complete_verified_inputs | PASS | recommend_order | 115 | 70 | 140 | 30 |
| confirmed_zero_incoming_and_backorders | PASS | recommend_order | 100 | 70 | 140 | 40 |
| stale_supplier_information | PASS | needs_review | 100 | 70 | 140 | 40 |
| high_inventory | PASS | sufficient_inventory | 150 | 70 | 140 | 0 |
| low_inventory | PASS | recommend_order | 0 | 70 | 140 | 140 |
| large_forecast_overprediction_fixture | PASS | recommend_order | 100 | 120 | 260 | 160 |
| large_forecast_underprediction_fixture | PASS | sufficient_inventory | 100 | 30 | 44 | 0 |
| known_zero_sales_history | PASS | recommend_order | 0 | 20 | 20 | 20 |
| no_sales_history_cold_start | PASS | needs_review | 100 | None | None | None |
| insufficient_sales_history | PASS | needs_review | 100 | 70 | 140 | 40 |
| invalid_negative_inventory | PASS | needs_review | None | None | None | None |
| capacity_supplier_constraint_conflict | PASS | needs_review | 100 | 70 | 140 | None |
| supplier_unavailable | PASS | needs_review | 100 | 70 | 140 | 40 |

## Concrete Hollow Blocks calculation

The complete fixture uses 10 pcs/day forecast demand, 100 pcs on hand, 20 pcs confirmed incoming, 5 pcs backorders, five lead-time days, seven review days, 20 pcs safety stock, and 10 pcs per pallet.

- Inventory position: `115 pcs`.
- Lead-time demand: `50 pcs`.
- Reorder point: `70 pcs`.
- Protection period: `12 days`.
- Order-up-to target: `140 pcs`.
- Preliminary quantity: `25 pcs`.
- Rounded suggestion: `3 pallets` / `30 pcs`.

The missing-input fixture returns `NEEDS_REVIEW` with no quantity. Its blocking warnings are:

- `review_period_missing`
- `confirmed_on_order_missing`
- `backorders_missing`
- `supplier_lead_time_missing`

## Safety boundaries

- Confirmed numeric zero remains distinct from unknown/null.
- Seasonal Experimental remains display-only for replenishment; the API test compares its recommendation with existing LightGBM field-for-field.
- Every positive suggestion requires human approval.
- Every scenario reports `purchase_order_created=false`.
- API capabilities remain read-only with no inventory mutation or purchase-order creation.

## Limitations

- Fixtures validate policy math and contracts, not live supplier records.
- Forecast error scenarios validate sensitivity; they do not repair forecast error.
- No live Supabase row was modified or used as a configured-input fixture.
