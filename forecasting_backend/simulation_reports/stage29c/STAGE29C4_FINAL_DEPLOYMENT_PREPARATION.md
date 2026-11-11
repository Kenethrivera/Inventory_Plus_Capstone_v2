# Stage 2.9C-4 — Final Deployment Preparation

Date: 2026-11-11 (Asia/Manila)

Recommendation: **READY FOR MANUAL DRY RUN**

This is not a deployment or live database integration PASS. Supabase MCP was
used only for read-only catalog/data checks. No migration, dry run, rollback,
fixture, or database write was executed. Backend persistence remains disabled.

## Final live compatibility verification

| Check | Result | Verified detail |
|---|---|---|
| PostgreSQL | PASS | 17.6 |
| Required base tables | PASS | products, transaction_history, locations, profiles, approval_requests, private.app_sessions |
| Required columns/types | PASS | 25/25 exact matches |
| Session validation | PASS | private.require_app_session_v1(text), STABLE SECURITY DEFINER |
| Hashing/numeric functions | PASS | extensions.digest(bytea,text), pg_catalog.trim_scale(numeric) |
| Supabase roles | PASS | anon, authenticated, service_role, postgres |
| Admin/location | PASS | one Admin with a location |
| Proposed-name conflicts | PASS | none |
| Product triggers | PASS | none requiring special handling |
| Receipt schema | PASS | transaction_history UUID product/location IDs, numeric quantity, timestamptz creation time |
| Genuine receipt observations | PASS | 1,404 stock_in; all positive and product/location scoped |
| Receipt unit evidence | PASS WITH LIMITATION | 1 approved restock snapshot; all 1,404 currently resolve through canonical product unit |
| Product deletion compatibility | PASS | transaction_history.product_id uses ON DELETE CASCADE; tracking proposal uses copied snapshots and no external product/receipt FK |
| Existing object counts | INFORMATIONAL | 37 products, 34,446 transaction rows, 1 location, 6 profiles |

The existing products, transaction history, locations, and profiles tables have
RLS disabled. That is a previously documented security risk outside this stage.
The new tracking tables enable RLS and revoke direct access from anon,
authenticated, and service_role. Only five reviewed SECURITY DEFINER RPCs are
granted to service_role/postgres, and every RPC also validates the Inventory Plus
Admin application session and active location.

## Final SQL files

1. `database/stage_2_9c_recommendation_tracking_DRY_RUN.sql`
   - one atomic transaction;
   - creates and verifies all proposed objects;
   - zero commit statements;
   - final statement is ROLLBACK;
   - captures and rechecks existing operational row counts.

2. `database/stage_2_9c_recommendation_tracking_MIGRATION.sql`
   - one atomic transaction;
   - checks exact base schema/function/role compatibility;
   - rejects any table, sequence, index, trigger, or function-name conflict;
   - creates only reviewed Stage 2.9C structures;
   - verifies grants, RLS, triggers, indexes, internal-only FKs, empty new tables,
     and unchanged base row counts before commit.

3. `database/stage_2_9c_recommendation_tracking_POST_DEPLOY_READ_ONLY.sql`
   - PostgreSQL-enforced read-only transaction;
   - reports table/RLS, signatures, owners, volatility, constraints, internal FKs,
     indexes, immutable triggers, table/sequence denial, and base-object checks;
   - expected result is 9 PASS rows and OVERALL PASS.

4. `database/stage_2_9c_recommendation_tracking_ROLLBACK.sql`
   - removes only exact Stage 2.9C functions/tables;
   - no CASCADE and no TRUNCATE;
   - validates table/function identity comments;
   - refuses when any tracking history exists unless the local authorization
     boolean is separately reviewed and manually changed to true;
   - never writes inventory, products, transactions, orders, sales, or auth data.

## Recovery-script assessment

The existing initialization and synthetic import scripts are reconstruction
tools, not an exact backup:

- `01_reset_transaction_test_data.sql` deletes location-scoped orders, history,
  transactions, forecast configurations, and forecasts while preserving its
  expected 13-product catalog. Its preflight expects exactly 13 active products;
  the live database now has 37, so it is not a current general recovery script.
- `02_populate_full_inventory_simulation.sql` reconstructs the older deterministic
  13-product/676-day simulation and backdates those product creation timestamps.
  It does not reconstruct the later 24-product seasonal import or arbitrary
  changes made since generation.
- `stage_2_1_expanded_seasonal_simulation_PROPOSAL.sql` deterministically adds the
  24 tagged seasonal products, 1,461 orders/history rows, and tagged movements.
  Its authorization switch has been restored to `false`. Existing duplicate and
  preflight guards should prevent an accidental repeat import.
- Its targeted rollback can remove tagged synthetic rows, but neither import nor
  rollback restores current authentication, sessions, settings, unrelated user
  edits, recommendation snapshots, or exact point-in-time database state.

These scripts are last-resort synthetic reconstruction aids only. They cannot
replace a database backup and must not be run as part of Stage 2.9C deployment.

## Exact manual execution order

1. Leave `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false` and stop any attempt
   to save tracking records.
2. In Supabase SQL Editor, open and run the entire
   `stage_2_9c_recommendation_tracking_DRY_RUN.sql` file once.
3. Continue only if it completes without an exception. Because it rolls back,
   the three tracking tables must still be absent afterward.
4. Run the complete `stage_2_9c_recommendation_tracking_MIGRATION.sql` once.
5. Immediately run the complete
   `stage_2_9c_recommendation_tracking_POST_DEPLOY_READ_ONLY.sql`.
6. Continue only when every numbered check and OVERALL report PASS. Before use,
   the informational tracking counts should all be zero.
7. Keep the feature flag false and restart `python run_api.py`; verify existing
   forecasting remains operational before enabling persistence.

## Backend activation after SQL verification

1. Configure `SUPABASE_SECRET_KEY` only in the FastAPI server environment. Never
   place it in Flutter, source control, logs, responses, or a Dart define.
2. Keep `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false`, restart FastAPI, and
   confirm normal forecasts still work.
3. Change only the server environment to
   `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=true` and restart FastAPI.
4. Use an existing Admin session to save one reviewed recommendation. Confirm the
   response identifies LightGBM version 1, 365 history days, 28-day horizon, and
   experimental=false.
5. Run the post-deployment read-only script again and confirm one immutable
   snapshot with no unintended product or transaction changes.

Flutter and normal launch commands remain unchanged.

## Rollback order

1. Set `FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false` and restart FastAPI.
2. If no history exists, run the rollback file unchanged.
3. If history exists, the rollback intentionally fails. Export/review the history
   and separately authorize destruction before changing its local boolean.
4. Run the post-deployment script only while objects exist; after rollback, use
   catalog checks or rerun the dry run to confirm the schema can still compile.

Stop immediately for any dry-run exception, migration exception, post-deployment
FAIL, unexpected tracking rows, incorrect grants, lost immutability trigger, or
change to existing product/transaction/location/profile counts.

## Automated tests

```text
python -m pytest forecasting_backend/tests -q
337 passed, 56 subtests passed, 1 warning
```

The warning is the existing Starlette TestClient/httpx deprecation warning.
