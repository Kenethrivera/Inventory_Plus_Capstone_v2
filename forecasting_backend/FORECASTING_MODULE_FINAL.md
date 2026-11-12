# Inventory Plus forecasting module handoff

Date: 2026-11-05 (Asia/Manila)

## Scope

This handoff covers only demand forecasting and deterministic replenishment
recommendations. It does not approve purchase orders, mutate inventory, alter
POS behavior, or claim real-store accuracy from synthetic evaluation.

## Completion checklist

| Component | Status | Evidence / boundary |
|---|---|---|
| Completed-sales extraction | Implemented; live behavioral verification pending | `forecast_daily_demand_v1`, completed and non-returned orders only, half-open timestamps, Asia/Manila dates |
| Stage 5A Python validation | Complete locally | Rejects malformed quantities, inconsistent units, duplicate conflicts, and relevant missing completion timestamps |
| Mean28 | Complete locally | Product/location-isolated, nonnegative finite output, explicit cold-start metadata |
| LightGBM candidate | Complete locally | Chronological features/training, stockout-censored targets, Mean28 fallback |
| Calibrated 50/50 blend | Complete locally | Earlier-period multiplicative calibration; chronological rolling origins |
| Cold-start/manual estimate | Complete locally | `no_history` zero is explicitly unknown demand; manual estimate is provisional and never sales history |
| Recommendation engine | Complete locally | Deterministic periodic-review order-up-to policy; missing essentials return `NEEDS_REVIEW` |
| Read-only FastAPI endpoint | Complete locally | Authenticated Admin, server-derived location, structured forecast/recommendation JSON |
| Product/inventory context | Prepared; database verification pending | Forecasting-only `forecast_product_context_v1`; no direct table REST access |
| Flutter Forecasting page | Complete locally | Model, period, cold-start, inventory/reorder fields, warnings, state, timestamps, and decision disclaimer |
| Synthetic simulation | Complete and preserved | Stage 6A seed 2606 plus Stage 6A.2 multi-seed/stress reports |
| Actual-store accuracy validation | Not complete | Requires real completed sales and operational outcomes |

## API and database setup

The production API requires these database interfaces:

1. Existing opaque application-session functions:
   `private.require_app_session_v1` and `profile_restore_session_v1`.
2. `database/stage_5a_daily_demand.sql`.
3. `database/stage_5d_forecast_product_context.sql`.

The backend intentionally does not use the Stage 6B.7
`forecast_product_snapshot_v1` RPC and does not query `/rest/v1/products`.
Both required forecasting RPCs validate the opaque session, require Admin, and
derive the location server-side.

Required API environment:

```text
FORECAST_API_MODE=supabase
FORECAST_DEPLOYMENT_ENV=production
SUPABASE_URL=<target project URL>
SUPABASE_PUBLISHABLE_KEY=<publishable/anon key; never service role>
FORECAST_REVIEW_PERIOD_DAYS=<explicit nonnegative integer>
FORECAST_POLICY_VERSION=stage5d-periodic-review-v1
FORECAST_UPSTREAM_TIMEOUT_SECONDS=15
```

Flutter requires `FORECAST_API_URL` and sends the opaque application session as
a Bearer token. Synthetic mode is restricted to explicit development/test
configuration and never writes fixtures to Supabase.

## Output behavior

- `mean28`, `lightgbm`, and `calibrated_blend` share the structured forecast
  contract: model/version, horizon, daily values, total, provenance,
  timestamps, cold-start state, calibration, and data-quality warnings.
- LightGBM and blend fall back to Mean28 when unavailable, under-trained, or
  invalid. Fallback is explicit metadata, not silent substitution.
- `no_history` is not confirmed zero demand. A confirmed manual daily estimate
  may support a provisional calculation without changing sales history.
- The recommendation response includes inventory position, reorder point,
  safety stock, protection period, order-up-to target, suggested quantity,
  warnings, explanations, and human-approval requirement.
- The API is read-only and never creates a purchase order.

## Remaining forecasting-specific dependencies

1. Execute behavioral tests for both RPCs in an explicitly isolated Supabase
   project. Mock/static tests do not prove live grants or authorization.
2. Resolve or formally exclude the five malformed completed-order snapshots;
   affected periods currently fail closed rather than understating demand.
3. Configure canonical supplier lead time, MOQ, pack size, availability,
   confirmed inbound orders, backorders, safety stock, and unit conversions.
   Until then, production recommendations correctly remain `NEEDS_REVIEW`.
4. Add canonical historical availability/stockout evidence. Recorded sales can
   understate underlying demand during stockouts without this source.
5. Collect genuine completed-sales history. With no history, demonstrate the
   cold-start/manual-estimate workflow rather than presenting ML accuracy.
6. Configure and deploy the Python API and set Flutter's `FORECAST_API_URL`.

Application-wide RLS, staff, password-recovery, notification, Realtime, and
GCash findings are external application risks and are not forecasting-module
development dependencies except that the existing opaque session functions
must continue to work.

## Verification executed

- Forecasting-focused Python selection: **102 passed, 0 failed**.
- Complete Python suite: **120 passed, 0 failed**.
- Flutter Forecasting API/page tests: **11 passed, 0 failed**.
- Targeted analysis of the Flutter forecasting service, page, and tests:
  **no issues found**.

The Python run reported only the existing FastAPI/Starlette TestClient
deprecation notice. No live Supabase behavior test was executed, and the
results above must not be represented as database verification.

## Demonstration readiness

The module is ready for an isolated capstone demonstration using the clearly
labeled synthetic adapter, including all three forecasting candidates,
cold-start behavior, manual estimates, `NEEDS_REVIEW`, and deterministic
recommendation explanations.

A database-backed demonstration is conditionally ready after the two
forecasting RPCs are applied and behavior-tested in an isolated Supabase
environment. It is not evidence of actual hardware-store accuracy or proven
stockout reduction.
