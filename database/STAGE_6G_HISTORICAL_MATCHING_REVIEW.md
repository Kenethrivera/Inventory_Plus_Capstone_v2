# Phase 6G final historical restock feature

## ONE migration, no alternate sequence

Only `stage_6g_applied_restock_records.sql` is deployed. After isolated validation and approval, deploy **`database/stage_6g_historical_restock_matching.sql`** ONCE. It creates the private evidence table/validators and capture RPC, and replaces ONLY the existing `forecast_applied_restocks_v1` operational function. Stage 5C's scope validator is reused, not overwritten. `stage_6g_background_restock_capture.sql` is retired and contains no executable SQL. Do not run it.

The migration runs within one transaction. It performs no backfill, inventory update, approval update, forecast job execution, or historical recommendation update. DDL takes normal locks. A repeat installation intentionally fails on existing objects rather than silently replacing evidence. After commit, disable the capture process to halt writes; retain all immutable evidence. Do not delete tables to disable the feature.

## Correct response and read boundary

The STABLE read RPC explicitly assigns each forecast field at the TOP LEVEL through CASE: original approval-linked snapshot if present; otherwise the corresponding immutable evidence payload field. An existing snapshot's NULL stays NULL; evidence never fills holes in that original snapshot. recommendation_id stays NULL for reconstructed evidence. Assumptions are constructed separately as strings only, with no JSON concatenation. Missing model/version/period/demand/suggestion/history/reliability remain JSON null. Transaction UUID is the identity.

FastAPI validates this shape, nullable finite numbers, duplicate transaction identity and string-only assumptions. Invalid upstream data returns a controlled error, not fake empty success. Flutter's existing tracking parser accepts empty SKU and nullable historical fields, retains explicit evidenceSource/reliability, and rejects JSON objects in assumptions. The existing details label reconstructed estimates and stock-before evidence; missing values display Not recorded. Forecast Accuracy models, endpoints and WAPE/Bias calculations are unchanged.

Restock Records reads never call capture. Its session helper is STABLE/read-only. anon EXECUTE on the read RPC is intentional for the existing publishable-key + opaque app-session client: the function itself requires Admin and derives location from the validated session. No direct private-table access is granted. Approval remains independent of all matching work.

## Capture semantics

The service-role-only RPC checks the deployed explicit location allowlist, visits bounded transaction-ID pages, and accepts only approved positive stock_in requests linked to applied transactions. Result scope, unit, default blend request, 28-day horizon, same Manila business date, valid preliminary series, and finite stock-before are required. Both result.created_at and the linked succeeded job.completed_at must precede the transaction timestamp. The latest eligible result wins. Failed, later, other-location, other-product and wrong-date results are excluded. No-history outputs are unknown, not zero. Limited-history valid estimates remain provisional.

Stock before = authoritative new_quantity - quantity_change. Suggestion = max(0,ceil(saved preliminary demand - stock before)); difference = actual - suggested. Copies include the supporting series, result UUID and publication completion timestamp. A transaction UUID primary key plus ON CONFLICT DO NOTHING makes replay/concurrent capture safe. UPDATE/DELETE/TRUNCATE are rejected; no cascading source foreign keys erase evidence.

These are the existing recorded publication timestamps, not PostgreSQL commit timestamps or proof an Admin viewed the estimate. Missing cleaned-up publication jobs are conservatively excluded. Older/different-day forecasts are not shifted. The historical UI-selected model cannot be inferred; default blend is explicit. No assertion is made about the real +10 transaction without its own timestamp match.

## Background operation (not activated)

The standalone runner uses existing server-only credentials, explicit FORECAST_MAINTENANCE_LOCATIONS, modern/legacy credential headers, exclusive file locking, and atomic checkpoints. It never fits models. Each committed page advances the cursor. Network/transient HTTP failures retry at most three times per cycle with 1s/2s waits; permanent failures are not immediately retried. Interrupted/lost responses replay safely. A completed sweep resets the cursor so late approved/backdated records below the last cursor are reconsidered. No-match records advance too, preventing starvation. Continuous mode waits at least 60 seconds between bounded cycles. SIGINT/SIGTERM stops between RPCs/pages/retries; each RPC uses the configured timeout.

### Safe one-time backfill AFTER migration approval and deployment

Use the backend's existing server-only .env; never put keys in commands. From PowerShell:

```powershell
Set-Location 'C:\inventory_plus_capstone_v2\Inventory_Plus_Capstone_v2-integration\forecasting_backend'
$env:FORECAST_MAINTENANCE_LOCATIONS = '11111111-1111-1111-1111-111111111111'
python run_restock_evidence_capture.py --capture --location-id 11111111-1111-1111-1111-111111111111 --batch-size 25 --max-pages 100 --state-file .runtime/restock-historical-backfill.json
```

This writes ONLY evidence, at most 2,500 visited stock-in rows in this invocation; no stock or forecast jobs change. Check exit code and JSON visited/captured/sweep_complete. If sweep_complete=false, repeat the SAME command/checkpoint to continue; do not reset cursors. A completed sweep can be repeated without duplicate evidence. Capture=0 is not a fabricated match.

### Scheduled operation AFTER separate activation approval

`forecasting_backend/deployment/inventory-restock-evidence-capture.service` is a separate systemd service template using the existing /etc/inventory-plus/forecast.env, location scope and protected state directory. Review installation paths/user, copy the unit into /etc/systemd/system, then explicitly enable/start it. It runs one 25-row page per minute and uses Restart=on-failure. Nothing starts from FastAPI or Flutter. Inspect journalctl for this service and the JSON cycle reports. Stop/disable the service to suspend capture; reads remain available.

## Validation and blockers

Local focused tests cover capture runner invocation/closing, scope, payload, cursor persistence/restart, transient/permanent failures, retry budget, HTTP authentication/location scope, serialization, and the ACTUAL extracted Dart tracking parser (direct SDK; no Flutter tests/analyzer). Four API fixtures cover no-match, evidence-only, snapshot-only and both; missing values and empty SKU parse correctly. Existing preliminary and WAPE/Bias tests are also run. This does not prove PostgreSQL execution or browser rendering.

`tests/test_historical_restock_postgres.py` runs the original deployed RPC migration followed by the ONE final migration in an empty disposable local PostgreSQL transaction, seeds only isolated fixtures, executes `stage_6g_historical_restock_matching_validation.sql`, feeds actual returned JSON to Python validation and the actual Dart parser, then ROLLBACK. It rejects remote DSNs and existing application tables. Dependencies mirror repository column contracts; this is not a full deployed Supabase clone. The test checks service-role access, rejected client/session/scope calls, repeated bounded capture, immutable/unique evidence, four actual read cases, no object in assumptions, and selection of a successful earlier result instead of a newer failed result. The +10 fixture intentionally predates any eligible publication and must remain unmatched. Fixtures are NOT written to live data.

Run when a local empty PostgreSQL database is available (no production connection):

```powershell
$env:RESTOCK_ISOLATED_CONFIRM = 'disposable'
$env:RESTOCK_ISOLATED_DSN = 'postgresql://postgres@127.0.0.1:5432/inventory_restock_disposable'
# Use local pgpass for authentication; do not print a password.
python -m pytest tests/test_historical_restock_postgres.py -q
```

Current environment: psql/PostgreSQL, Docker and a usable WSL distribution are unavailable. SQL integration is skipped, not passed. Do not call this READY for deployment until that test and deployed metadata compatibility pass.

## Flutter verification after approved deployment/backfill

1. Restart FastAPI and reload the Flutter build containing the parser changes.
2. Sign in as an authorized Admin; open Tracking & Accuracy -> Restock Records -> Claw Hammer.
3. Inspect /v1/forecasting/restock-records: HTTP 200, read_only=true; +5 transaction appears once with top-level 72.71923863537 demand, 44 stock, 29 suggestion, 5 actual, -24 difference, null recommendation_id if no original snapshot, and string-only assumptions.
4. Expand its details: reconstructed-estimate label and Stock before restock must be shown. Existing display rounding may round demand while preserving the underlying value.
5. Refresh/navigate away/back: same transaction UUID and quantities; merely reading must not create evidence.
6. Check a missing-evidence record: Not recorded, not zero. Check an original snapshot record: original values win.
7. Treat the real +10 transaction independently; do not copy +5 values.
8. Open Forecast Accuracy and confirm its existing history/metrics still load. Live browser acceptance remains pending.
