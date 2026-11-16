# Daily forecasting policy (Stage 6B)

The UI, models, bundle identity canonicalization, stock calculators, and WAPE/Bias
are unchanged. This release requires approval of
`database/stage_6b_daily_forecast_policy.sql` before daily-policy service activation.
No service or SQL was activated during implementation.

## Policy and cutoffs

* The existing maintenance process now supports `--daily-policy`. It checks the
  Manila clock, begins an existing-product sweep at/after 03:00, and resumes a
  missed run at the next cycle. It advances bounded pages until the date's sweep
  completes. Failed preparation gets a five-minute rescan backoff. Failed or
  cancelled jobs still require the existing recovery/explicit authorization rules.
* Each job retains Manila midnight as `as_of_at`. Historical demand is the existing
  half-open interval `[business_date - 365 days, business_date midnight)`.
  This includes all previous-day fractional seconds and excludes today's sales.
* Ordinary current-day sales/returns/corrections update `sales_event_revision`
  (events since this migration), not the revision of the frozen historical inputs.
  Existing `sales_revision` values are preserved. Changes affecting dates before
  today's midnight still increment that revision and invalidate obsolete inputs.
  Backdated corrections therefore remain honestly stale; automatic refresh occurs
  at the next daily sweep, or the existing authorized one-product action can be used.
* Product-input changes retain the existing product revision behavior. Inventory
  receipts/quantity adjustments do not trigger demand model preparation. At midnight,
  yesterday's result retains its dates and may be shown stale until the 03:00 refresh;
  no calendar shifting or false current label is introduced.
* New/activated eligible products set a durable indexed pending flag in the same
  product transaction. A separate bounded pending read runs every 30 seconds,
  including before 03:00, independently of the daily inventory cursor. A real job
  insert acknowledges the flag in the same transaction. No forecast computation
  occurs in a trigger. No-history products retain real cold-start/unknown-demand
  metadata and existing manual-estimate restrictions.
* The 30-second idle interval targets under-60-second discovery in normal operation;
  network delays, a slow preparation batch, downtime, or a burst of many new products
  can exceed it. This is a queue-preparation target, not a model-completion guarantee.
* Initial-lane counts describe only pending products. Daily-lane coverage describes
  the whole authorized active inventory through the existing Stage 5C RPC.

## Validation now (no credentials or database required)

From `forecasting_backend`:

```powershell
python verify_daily_forecast_policy.py
```

Prints PASS/FAIL and returns a matching exit code. It simulates 02:59, 03:00,
03:05, a 10:00 sale, a 14:00 receipt, the following date, downtime/restart,
and initial discovery. It runs the real executor's limited-history fallback,
serializer, materializer, worker dispatch, and recommendation calculators against
an in-memory repository. It does not validate PostgreSQL triggers/locks/grants.

## Approval and SQL verification gate

Supabase MCP failed OAuth refresh during this implementation. The forward migration
uses repository Stage 5C and previously inspected Stage 3/6/6A contracts. A fresh
read-only check and isolated SQL execution remain required before deployment:

```sql
SELECT p.oid::regprocedure,pg_get_functiondef(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='private' AND p.proname IN
 ('forecast_order_demand_contributions_v1','track_order_history_demand_revision_v1',
  'track_product_forecast_revision_v1','forecast_maintenance_scope_v1'))
 OR (n.nspname='public' AND p.proname IN
 ('recover_forecast_job_v1','forecast_enqueue_jobs_v1','forecast_initialize_revisions_v1'));
SELECT column_name,data_type FROM information_schema.columns
WHERE table_schema='private' AND table_name='forecast_input_revisions';
SELECT tgname,pg_get_triggerdef(oid) FROM pg_trigger
WHERE tgrelid IN ('public.products'::regclass,'public.order_history'::regclass,
 'private.forecast_jobs'::regclass) AND NOT tgisinternal;
```

In an isolated clone, install Stage 6B and verify a completed current-day sale
increments event revision only, a prior-date correction increments both revisions,
an incomplete checkout changes neither, and stock-only updates change neither.
Test old/new product and location contributions, duplicate product lines, pending
signal rollback, job-insert acknowledgment rollback, service-role-only page access,
and cross-location rejection. No such SQL tests were run against the live project.

The migration uses one transaction with a 10-second lock timeout. It does not
backfill old events, change any existing revision value, create jobs, modify stock,
or touch results/recommendations. On error roll back the transaction. After installation,
disable automatic work by stopping maintenance/worker services; do not reset jobs.
Reversing the new trigger policy needs a separately reviewed forward migration.

## One-time actual-date smoke preview after approved SQL installation

Configure the existing server-only environment and allowlist. Run:

```powershell
python run_forecast_maintenance.py --daily-policy --location-id 11111111-1111-1111-1111-111111111111 --max-products 5 --max-pages 1 --state-file .runtime/daily-policy-preview.json --report-json-stdout
```

No `--enqueue`: no revisions/jobs are written. No fake date parameter exists.
At 02:59 only initial discovery is reported; after 03:00 daily coverage is also
reported. To authorize a bounded real smoke preparation separately, append
`--enqueue` and use `.runtime/daily-policy-smoke.json`. A cycle visits at most
five initial plus five daily candidates; do not run this when only a five-total-product
trial was approved. Preview first and obtain the correct bounded approval.
Use the existing `--product-id` path without `--daily-policy` for a one-product trial.

## Linux activation (separate approval required)

Use the existing worker service (concurrency 1, lease/retry recovery, restart on
failure) and the updated maintenance service. Install both units in
`/etc/systemd/system/`, using the existing inventoryplus account and protected
`/etc/inventory-plus/forecast.env`. The maintenance service uses a NEW checkpoint:
`/var/lib/inventory-plus/forecast-daily-policy.json`; previous trials are untouched.
Set `FORECAST_MAINTENANCE_LOCATIONS` to the approved location, materialization and
snapshot-read flags true, API mode supabase, review period 7, and the existing
server-only Supabase credentials. Use identical code/dependencies for both processes.

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now inventory-forecast-maintenance inventory-forecast-worker
journalctl -u inventory-forecast-maintenance -u inventory-forecast-worker -f
```

These are activation instructions, not commands executed during implementation.
The worker and maintenance caps are 2 GiB + 1 GiB; provision VM headroom. A stopped
VM cannot meet the discovery target. No extra scheduling service is introduced.
Restart reuses cursors; losing a checkpoint replays pages safely through DB dedup.
Stop with `systemctl stop` for a supervised shutdown and lease-safe worker exit.

## Current-stock acceptance check using the unchanged UI

1. Select a product with a current result and note result ID, dates, daily quantities,
   current saleable stock, and preliminary/recommendation quantities.
2. Through the normal application workflow, complete a legitimate sale during the
   same Manila date. Do not insert artificial sales for this test.
3. Use the existing refresh/reload in Product Forecast. Confirm the same result ID
   and demand values; stock and stock-dependent guidance must reflect the sale.
4. Repeat after a legitimate stock receipt. Expected quantities must agree with the
   existing calculator; pack sizes, capacity and supplier rules can affect the delta.
5. Check history/Tracking separately: refreshing guidance must not save/overwrite a
   historical recommendation. Tomorrow's daily result includes yesterday's sales.

The API already loads operational inventory on each snapshot product read and calls
`current_stock_analysis`; neither it nor the overview read executes models. Current
recommendations, last saved recommendations, and WAPE/Bias history remain distinct.
