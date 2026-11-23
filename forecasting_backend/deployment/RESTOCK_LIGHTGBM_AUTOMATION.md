# Daily LightGBM preparation for store Restock Priorities

This change is **inactive until approved and installed**. The existing 03:00
Asia/Manila Blend sweep remains enabled. `--restock-lightgbm` adds one separate
bounded daily LightGBM sweep; it does not schedule Mean28 or Seasonal.

## Activation order (operator approval required)

1. Review and install `database/stage_8_restock_lightgbm_maintenance.sql` in
   the existing Supabase project. This adds only the service-role maintenance
   coverage RPC. Verify that its installed definition and EXECUTE grant match
   the file before enabling the flag. Do not change saved jobs or snapshots.
2. Deploy the **same source and pinned Python runtime/dependencies** to the
   existing local FastAPI host and Azure maintenance/worker host. Run
   `python run_forecast_maintenance.py --identity-only` on the maintenance VM
   and compare `implementation_digest` with the worker and FastAPI identity
   diagnostics. Do not enable the flag if the digests differ. The edited
   scheduler, reader, route, and UI files are outside the 14 hashed model
   source files, but the installed runtime must still be checked.
3. On the Azure VM, update the existing maintenance service command to include
   `--restock-lightgbm`, retaining the authorized BINAN-001 location UUID
   `11111111-1111-1111-1111-111111111111`,
   `--max-products 5 --max-pages 1 --interval-seconds 30`, the existing
   `FORECAST_MAINTENANCE_LOCATIONS`, state file, and `--enqueue`. Confirm that
   the installed service and database scope still identify BINAN-001 before
   activation. Retain the existing worker concurrency and retry configuration.
   After approval, use `sudo systemctl daemon-reload` and
   `sudo systemctl restart inventory-forecast-maintenance.service` on that VM.
4. Deploy the FastAPI coverage route and Flutter client together. The route is
   Admin-only and reads the authorized store from the session. Overview reads
   and refreshes never enqueue jobs.

The service's existing durable state file now stores `lightgbm_cursor`,
`lightgbm_sweep_date`, `lightgbm_completed_date`, and retry fields under the
same location key. Do not delete or reset that file to activate this change.
The LightGBM lane scans current logical identities, skips exact terminal jobs,
and uses the existing idempotent enqueue RPC and worker recovery limits.
`lightgbm_completed_date` means scanning finished; it does **not** assert that
the worker has published all forecasts. Products created after a completed
daily LightGBM sweep enter that lane the next business day.

## Verification after activation

- Read maintenance logs for the `lightgbm` lane, its `active_products`,
  `coverage`, `queued`, `duplicate`, `preparation_errors`, `terminal_failures`,
  and `cycle_duration_ms`. Failed exact identities require authorized recovery;
  maintenance does not silently retry them.
- For the 12 retained products, confirm **12 current Blend and 12 current
  LightGBM saved snapshots** for the same Manila business date. Queue counts
  alone are insufficient. Check Forecast Jobs for saved-result state and safe
  failures. Compare the Overview priority list under each of the four chart
  models without changing inventory.
- Change stock through the existing authorized inventory workflow. Confirm the
  Overview invalidation causes a fresh priority read and guidance uses current
  stock while the LightGBM snapshot remains the same. Do not simulate a stock
  change by editing forecast records.
- Verify that switching tabs cancels Overview polling and that Refresh issues
  read requests only. The coverage poll runs at most 20 times at 45-second
  intervals per Overview activation or explicit refresh, and stops when all
  scoped products are current and no jobs are active.

## Capacity estimate and limits

With 5 products per 30-second cycle, each model lane needs at least
`ceil(product_count / 5) * 30 seconds` of scheduled cycles to enqueue a full catalog: about
90 seconds for 12 products, 10 minutes
for 100, and 100 minutes for 1,000. Both lanes share each cycle; the worker's
single-job throughput adds time before all saved results become current.
These are schedule estimates, **not measured runtimes**. Record actual
`cycle_duration_ms`, worker completions, RPC latency, and resource use in the
approved environment before asserting 1,000-product capacity. The Overview
coverage poll reads paginated snapshot status (50 per page) and runs only for
active or incomplete scopes; full recommendations are calculated on activation,
meaningful status change, inventory invalidation, or explicit Refresh.

No SQL, service restart, or live forecast job has been executed as part of
this code change. The installed Supabase function and end-to-end counts remain
unverified until the approved activation and validation steps occur.
