# Stage 2.4 Controlled Seasonal Forecast Integration

## Status

Prepared for manual staging review. No Supabase write was executed.

The Stage 2.3 product-specific seasonal candidate remains experimental. The
existing calibrated blend remains the Flutter default, and the existing
LightGBM remains the sole forecast basis for replenishment whenever the
experimental option is selected.

## Stage 2.3 decision reused

- Frozen population: 24 expanded simulation products only; the original 13
  operational products were not part of candidate validation.
- Selected using validation data: 1,095-day maximum history and conservative
  LightGBM settings (120 estimators, 0.03 learning rate, 10 leaves).
- Final-test WAPE: 31.63%, versus 31.92% for the existing product-specific
  LightGBM and 31.75% for the matched nonseasonal ablation.
- Seasonal gain over ablation: 0.11 percentage points. Five of 23 products
  regressed versus the existing model; the no-sales control remained zero.
- This is evidence for controlled simulation testing, not proof of real
  Philippine hardware retail seasonality.

## API contract

Request `model: "seasonal_experimental"` to opt in. All existing model names
remain available, and `calibrated_blend` remains the Flutter default.

The experimental request:

1. reads at most 1,095 completed calendar days through the existing
   `forecast_daily_demand_v1` RPC;
2. uses the frozen 24-product context registry and PAGASA Type-I calendar;
3. returns date-level season/transition context and the next transition;
4. applies no fixed seasonal multiplier;
5. falls back to the existing LightGBM on its normal 365-day window when the
   product context is unavailable or candidate history is insufficient; and
6. always calculates replenishment from the existing LightGBM on 365 days.

The response identifies the requested model, actual model, fallback reason,
history window, seasonal evidence status, and replenishment forecast basis.

## Import SQL audit

Manual script:
`database/stage_2_1_expanded_seasonal_simulation_PROPOSAL.sql`

Mandatory read-only preflight:
`database/stage_2_4_expanded_seasonal_simulation_PREFLIGHT_READ_ONLY.sql`

The script is disabled by default and runs in one transaction. It checks the
required tables, columns, forecasting RPC signature, Admin/location,
completed-order validation trigger, order-history sync trigger, and all import
tags before inserting anything. It then validates:

- exactly 24 tagged products and 1,461 tagged daily orders;
- complete order-history trigger synchronization;
- checkout quantities equal completed sales;
- movement ledgers end at each product's catalog stock;
- no negative simulated stock balance; and
- pre-existing table row counts are preserved.

Products use deterministic UUID/SKU tags. Orders and movements use deterministic
IDs and `sim-season-v1:` operation tags. Any prior matching ID, SKU, order tag,
or movement tag aborts the transaction. A repeat run is therefore safe only
after the targeted rollback succeeds; duplicate data is never silently merged.

The product `created_at` is 2022-11-10 so its history is chronological.
`updated_at` is the manual import time because the catalog stock snapshot is
created by the import. Existing products and their history are not updated.

## Manual import procedure

1. Create a Supabase staging backup or branch snapshot.
2. Run `stage_2_4_expanded_seasonal_simulation_PREFLIGHT_READ_ONLY.sql` as a
   complete file in SQL Editor. It opens a PostgreSQL `READ ONLY` transaction
   and cannot insert, update, or delete rows.
3. Confirm every result row, including `OVERALL`, is `PASS`. Stop if any row is
   `FAIL`; do not enable or partially execute the import.
4. Confirm live profile `id = 1` is the intended Admin at location
   `11111111-1111-1111-1111-111111111111`. If it is not, stop and review the
   script; do not substitute an unverified profile.
5. Confirm the preflight reports exactly one enabled order synchronization
   trigger and exactly one enabled completed-snapshot validation trigger, each
   bound to its expected function.
6. Change the single `_stage21_authorization` inserted value from `false` to
   `true` in a local/manual SQL Editor copy.
7. Execute the complete import transaction once. Do not run the commented
   rollback block at the same time.
8. Verify the post-import queries report 24 products and 1,461 orders spanning
   2022-11-10 through 2026-11-09.
9. Start the backend with `python run_api.py` and Flutter with the existing
   command. Choose **Seasonal experimental** explicitly.
10. Compare expanded products with LightGBM and calibrated blend. Confirm the
   UI shows classification, evidence, next transition, and any fallback.
11. Confirm replenishment shows that it is still based on existing LightGBM.

## Targeted rollback

The commented rollback block at the end of the SQL file deletes only rows with
the deterministic `sim-season-v1:` tags and the 24 fixed product UUIDs. Review
and execute it separately as one transaction. It deletes movements, operational
orders, their durable history snapshots, and finally tagged products, then
fails closed if any tagged row remains. Restore the staging backup if its
validation fails.

## Schema verification boundary

This review used the repository's current declarative SQL and migration files.
The Supabase MCP server was not exposed in this Codex session, so live metadata
was not re-read and the import was not represented as live-verified. The SQL's
preflight intentionally stops on schema or trigger drift. No SQL in this stage
was executed against Supabase.
