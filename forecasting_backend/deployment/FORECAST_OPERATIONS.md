# Controlled activation (not activated by this change)

For the final 03:00 Asia/Manila daily policy and prompt new-product lane, follow
[DAILY_FORECAST_POLICY.md](DAILY_FORECAST_POLICY.md). The updated Linux maintenance
unit requires the separate Stage 6B SQL approval; do not activate it beforehand.
The older bounded trial instructions below remain available for explicit trials.

For explicit same-identity terminal-failure recovery, see
[PHASE_6_RECOVERY.md](PHASE_6_RECOVERY.md). Stage 6/6A are owner-confirmed installed.
Automatic maintenance never
authorizes terminal recovery itself.

For the current Windows five-product gate, disabled Task Scheduler registration,
and rollout commands, follow [WINDOWS_AUTOMATIC_FORECASTING.md](WINDOWS_AUTOMATIC_FORECASTING.md).
Stage 5C is already deployed; those older trial scripts need no new SQL.

UI layouts and forecasting mathematics are unchanged. The scheduler is a separate process,
never a FastAPI startup hook. Default automatic preparation remains Blend v1, horizon 28,
history 365. Alternate model reads remain supported, but automatic/explicit preparation
of those models is not enabled by the existing enqueue contract.

## Installed SQL boundary

`database/stage_5c_forecast_maintenance.sql` is installed in testing project
`pzotcznujkuzymndluwl`. Its service-role-only maintenance reads/enqueue and one-product
request prioritization permit ONLY location
`11111111-1111-1111-1111-111111111111` (the verified fixture location). Do not broaden this
literal without review. Existing queue claim order gains minute-based aging so old
ordinary jobs eventually outrank new priority-10 requests. No additional SQL is
required for the Windows automation described in the linked guide.

Deploy the same source/dependency build to FastAPI, maintenance and worker. The existing
implementation digest fingerprints source files; old queued identities may be superseded
or fail validation after deployment. Never reset them manually. Maintenance prepares new
identities; immutable results and historical records remain intact.

## Server-only configuration

Configure the existing backend `.env` locally (restrict its OS ACL to the service account),
or `/etc/inventory-plus/forecast.env` on Linux (root-owned, readable only by service account).
Do not put values in Flutter, command arguments, source control, or logs:

```
FORECAST_API_MODE=supabase
FORECAST_REVIEW_PERIOD_DAYS=7
FORECAST_JOB_MATERIALIZATION_ENABLED=true
FORECAST_SNAPSHOT_READS_ENABLED=true
FORECAST_WORKER_ENABLED=true
FORECAST_MAINTENANCE_LOCATIONS=11111111-1111-1111-1111-111111111111
```

Also supply existing `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and server-only
`SUPABASE_SECRET_KEY` (or supported legacy service role key). No personal Admin session
is needed by maintenance. The service secret remains highly privileged: the SQL allowlist
constrains these RPCs, not a stolen service key's access through other existing endpoints.
Rotate it via the provider, update protected environment files, restart all services.

## Small activation gate (PowerShell, from forecasting_backend)

After SQL approval/install, preview only:

```powershell
python run_forecast_maintenance.py --location-id 11111111-1111-1111-1111-111111111111 --max-products 10
```

After separate approval for one product:

```powershell
python run_forecast_maintenance.py --location-id 11111111-1111-1111-1111-111111111111 --product-id ab0af441-e26b-4d9c-95b3-7b5fd0e42be1 --enqueue
```

Use read-only SQL to obtain the newly queued job ID; then process ONLY that ID:

```powershell
python run_forecast_worker.py --job-id <NEW-JOB-UUID> --max-jobs 1 --concurrency 1
```

Verify the job succeeded and has one result using the existing Stage 4 validation queries.
Verify all three saved roles have 28 points, and Product Forecast reads the result with no
model execution in the HTTP request. Do not use an old superseded job ID.

## Initial population â€” ONLY after explicit batch approval

```powershell
python run_forecast_maintenance.py --location-id 11111111-1111-1111-1111-111111111111 --max-products 10 --max-pages 4 --enqueue
```

For 38 products this visits four ordered pages. A durable cursor is written atomically
after each page; re-execution continues, wraps at the end and safely deduplicates. A
preparation error is logged and counted, and does not prevent later products being visited.
Interrupted pages are replayable. The OS lock rejects overlapping runs using the same
state file; database uniqueness still prevents duplicate jobs across hosts. Operate one
maintenance instance per location to avoid redundant history preparation.

Run the existing worker under supervision after approval. Default concurrency is 1; do
not increase it before measuring memory/CPU. `--once` now exits if no work exists.
`--max-jobs N` without `--once` waits for work until N claims; it is not a drain-and-exit flag.

## Unattended operation

Linux: provided `.service` files assume `/opt/inventory-plus/forecasting_backend`, its
existing virtualenv, and an unprivileged `inventoryplus` OS account. Review paths/resource
limits. After activation approval, install units and run:

```
sudo systemctl daemon-reload
sudo systemctl enable --now inventory-forecast-worker inventory-forecast-maintenance
```

Windows: use Task Scheduler with a dedicated service account, **Run whether user is logged
on or not**, trigger **At startup**, **Do not start a new instance**, restart on failure
every minute. Set â€œStart inâ€ to the backend directory and program to the installed Python
executable. Use two tasks, with these arguments:

```
run_forecast_worker.py --concurrency 1 --poll-seconds 5
run_forecast_maintenance.py --location-id 11111111-1111-1111-1111-111111111111 --max-products 10 --max-pages 4 --interval-seconds 300 --enqueue
```

Capture stdout/stderr to a protected rotating operational log using the host supervisor.
Do not put credentials in task arguments. No terminal or personal application session
must remain open. No task registration or service activation was performed here.

## Coverage, failures and alerts

Each cycle logs exact active-product counts grouped by current, missing, stale, queued,
retry_pending, running, failed, cancelled, superseded, excluded for the deployed default identity.
Counts are a database point-in-time view before that page's writes, not an invented
completion percentage. Re-run preview for updated coverage. Page entries carry safe
failure codes; no histories or credentials are logged. A same-identity terminal failed
job stays failed; automatic retries remain bounded. New business dates/revisions can
prepare new work. Investigate repeated skipped/preparation_errors; never reset history.

Host monitoring must alert on process down, missing maintenance log for >2 intervals,
preparation_errors/skipped >0, increasing failed counts, or no queue progress across
multiple lease periods. Alert delivery requires the owner's monitoring destination;
none is configured by this repository. Journald: `journalctl -u inventory-forecast-worker
-u inventory-forecast-maintenance`. Keep protected log retention and checkpoint disk space.

Manila dates are evaluated each cycle. Current/queued/running/retry/terminal-failed exact
identities are not repeatedly prepared. Missing/stale entries are revisited;
stock-only changes do not enter the demand identity. History reads reuse the worker's
dataset construction and normalize timestamps identically; one bounded location cache
is invalidated by the full source-revision fingerprint.

## Disable/recovery

Stop/disable the two services or scheduled tasks. Set `FORECAST_WORKER_ENABLED=false` and
`FORECAST_JOB_MATERIALIZATION_ENABLED=false` to fail closed on restart. Snapshot reads
can stay enabled. Do not delete/reset jobs or results. An interrupted worker's lease
expires and a later worker recovers it within the existing retry cap. Restore the previous
claim function only if reverting the aging policy; extra service-only RPCs can remain
unused. No database rollback is needed to stop operation.

## Outstanding live acceptance

No mass bootstrap or live worker execution was performed. Measure one-product preparation,
queue wait, model execution and publication separately; under 30 seconds is a target, not
a guarantee. Verify current stock changes affect guidance without model fitting, compare
representative saved roles to the executor, and check 38-product coverage before scaling.
Linux unit activation and Windows task credentials/monitoring are external deployment gates.


## Phase 6H unattended recovery check

Three independent processes are required: daily maintenance, bounded worker, and
historical restock evidence capture. The installed Linux templates live beside
this document. Install/enable them only after operational approval and after
the Stage 6G capture RPC is present. They use the same protected server-only
environment, service account, scoped location allowlist and `/var/lib/inventory-plus`
state directory. Neither FastAPI nor Flutter starts them.

To inspect a deployed Linux host without starting work:

```sh
systemctl status inventory-forecast-maintenance.service inventory-forecast-worker.service inventory-restock-evidence-capture.service
journalctl -u inventory-forecast-maintenance.service -u inventory-forecast-worker.service -u inventory-restock-evidence-capture.service --since today --no-pager
```

After approval, copy the three reviewed unit files into `/etc/systemd/system/`,
check `/etc/inventory-plus/forecast.env` contains the existing Supabase server
credentials, `FORECAST_API_MODE=supabase`,
`FORECAST_JOB_MATERIALIZATION_ENABLED=true`, `FORECAST_WORKER_ENABLED=true`,
and an explicit `FORECAST_MAINTENANCE_LOCATIONS` allowlist. Limit that file to
the service account/root; never put secrets in a unit file. Then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now inventory-forecast-maintenance.service inventory-forecast-worker.service inventory-restock-evidence-capture.service
systemctl status inventory-forecast-maintenance.service inventory-forecast-worker.service inventory-restock-evidence-capture.service
```

The worker is supervised with `Restart=on-failure`, concurrency 1 and a 300s
lease. An unexpectedly killed worker may leave a running job until its lease
expires; the claim RPC then reclaims it if attempts remain, or marks it failed
at the attempt limit. Maintenance and evidence capture checkpoint each committed
page. Replaying an uncheckpointed page is safe through SQL job identity and
transaction-UUID evidence uniqueness. Service restart never resets those files.

For a temporary local Windows run (not registered to start after reboot), from
PowerShell with the existing backend `.env` already configured:

```powershell
$forecastBackend = 'C:\inventory_plus_capstone_v2\Inventory_Plus_Capstone_v2-integration\forecasting_backend'
$forecastPython = (Get-Command python).Source
$forecastLogDir = Join-Path $forecastBackend '.runtime'
New-Item -ItemType Directory -Force -Path $forecastLogDir | Out-Null
$forecastProcesses = @(
  Start-Process -FilePath $forecastPython -WorkingDirectory $forecastBackend -WindowStyle Hidden -PassThru -ArgumentList @('run_forecast_maintenance.py','--daily-policy','--enqueue','--location-id','11111111-1111-1111-1111-111111111111','--max-products','5','--max-pages','1','--interval-seconds','30','--state-file','.runtime/forecast-daily-policy.json') -RedirectStandardOutput (Join-Path $forecastLogDir 'maintenance.out.log') -RedirectStandardError (Join-Path $forecastLogDir 'maintenance.err.log')
  Start-Process -FilePath $forecastPython -WorkingDirectory $forecastBackend -WindowStyle Hidden -PassThru -ArgumentList @('run_forecast_worker.py','--concurrency','1','--poll-seconds','5') -RedirectStandardOutput (Join-Path $forecastLogDir 'worker.out.log') -RedirectStandardError (Join-Path $forecastLogDir 'worker.err.log')
  Start-Process -FilePath $forecastPython -WorkingDirectory $forecastBackend -WindowStyle Hidden -PassThru -ArgumentList @('run_restock_evidence_capture.py','--capture','--location-id','11111111-1111-1111-1111-111111111111','--batch-size','25','--max-pages','1','--interval-seconds','60','--state-file','.runtime/restock-evidence-capture.json') -RedirectStandardOutput (Join-Path $forecastLogDir 'restock-capture.out.log') -RedirectStandardError (Join-Path $forecastLogDir 'restock-capture.err.log')
)
$forecastProcesses | Select-Object Id, ProcessName
```

This starts REAL background work; use it only in the authorized testing
location. The local launcher does not survive Windows reboot. The SQL leases and
cursors survive process loss. Check logs for `forecast_daily_policy`,
`forecast_worker_health`, `forecast_job_succeeded`, `forecast_claim_failed`,
`restock_capture_cycle`, `restock_capture_retry`, and `restock_capture_failed`.
Do not infer service health from a running PID alone; verify recent cycle logs
and actual queued/succeeded/failed counts through authorized read-only queries.
