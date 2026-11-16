# Windows automatic forecasting: controlled activation

This procedure uses the installed Stage 5C RPCs, the existing maintenance cursor,
and the existing standalone worker. It does not change the Forecasting UI or
forecast mathematics. Use the testing location
`11111111-1111-1111-1111-111111111111` only.

## Configuration and preview

Run from `forecasting_backend` in PowerShell. Its protected `.env` must contain
`FORECAST_API_MODE=supabase`, `FORECAST_JOB_MATERIALIZATION_ENABLED=true`,
`FORECAST_WORKER_ENABLED=true`, `FORECAST_MAINTENANCE_LOCATIONS` set to the testing
location, `SUPABASE_URL`, and a server-only Supabase secret key. Keep the file
readable only by the service account and administrators. Do not place secret
values in task arguments or Flutter configuration.

Preview five products without enqueueing or advancing the cursor:

```powershell
python run_forecast_maintenance.py --location-id 11111111-1111-1111-1111-111111111111 --max-products 5 --max-pages 1
```

Record the report's `coverage`, `candidates`, `visited`, `duration_ms`,
`preparation_errors`, and `skipped`. Coverage is the full authorized location
for the default Blend identity. It includes current, missing, stale, queued,
retry_pending, running, failed, cancelled, superseded, and excluded. A page
with five visited products may queue fewer than five jobs if some are current
or terminal. A failed product does not prevent the next product being visited.

## Five-product execution gate

Only after explicit approval for the live five-product trial, execute:

```powershell
& .\deployment\windows\Invoke-FiveProductForecastTrial.ps1 -ApprovedFiveProductTrial -PythonExe (Get-Command python).Source
```

The script visits at most five products, advances the normal durable cursor,
and runs the worker once per **newly queued job ID** with concurrency 1. It
does not claim unrelated jobs. Its output contains the maintenance report,
including `queued_job_ids`, and each worker's safe elapsed-time or failure log.
It stops if maintenance or a worker process exits unsuccessfully. A worker may
still exit normally after recording a failed or superseded job, so verify job
statuses rather than treating process exit alone as success.

The trial stores a local checkpoint and separate stdout/stderr logs under
`.runtime`. Rerunning after a worker interruption resumes only its recorded
job IDs; rerunning a completed trial does nothing. A maintenance failure or
unreadable report stops before any worker starts. Review the checkpoint and
the queued-job records before manually starting another batch. Do not delete
the checkpoint merely to retry a failed worker.

An older trial script could have advanced `forecast-maintenance.json` before
PowerShell stopped on a normal stderr INFO line. If that cursor exists but no
trial checkpoint exists, the corrected script refuses to start another batch
until you inspect existing queued jobs. After that read-only check, explicitly
acknowledge that a **new** bounded batch will be visited:

```powershell
& .\deployment\windows\Invoke-FiveProductForecastTrial.ps1 -ApprovedFiveProductTrial -AcknowledgeExistingCursor -PythonExe (Get-Command python).Source
```

Jobs from the interrupted older attempt are not among the new trial's
`queued_job_ids`; handle them separately after identifying their exact IDs.

In the Supabase SQL Editor, replace the example UUID list with only the IDs
reported by this trial and run this read-only check:

```sql
SELECT j.id, j.product_id, j.status, j.attempt_count, j.safe_error_code,
       j.created_at, j.completed_at, r.id AS result_id,
       CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_array_length(
           COALESCE(r.output_bundle #> '{outputs,requested_forecasts,series,0,points}', '[]'::jsonb)) END AS requested_points,
       CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_array_length(
           COALESCE(r.output_bundle #> '{outputs,recommendation_forecasts,series,0,points}', '[]'::jsonb)) END AS recommendation_points,
       CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_array_length(
           COALESCE(r.output_bundle #> '{outputs,preliminary_forecasts,series,0,points}', '[]'::jsonb)) END AS preliminary_points
FROM private.forecast_jobs AS j
LEFT JOIN private.forecast_execution_results AS r ON r.job_id = j.id
WHERE j.id IN ('<TRIAL_JOB_UUID_1>'::uuid, '<TRIAL_JOB_UUID_2>'::uuid)
ORDER BY j.created_at, j.id;
```

Use exactly the number of trial IDs returned; omit the query if none were
queued. Successful jobs must have one persisted result and 28 points in each
required output role. Check Product Forecast for the selected product and
Overview for its unit. Compare live stock, requested-model demand, and current
restock guidance; keep historical recommendations and WAPE/Bias read-only.
Record each worker `elapsed_ms` and the total wall-clock trial duration. Do
not extrapolate an unmeasured total-population duration.

## Disabled Windows tasks

After reviewing the five-product result, register both tasks **disabled** from
an elevated PowerShell session. The command prompts for the dedicated Windows
service account. It does not start, enqueue, or process work:

```powershell
& .\deployment\windows\Register-ForecastTasks.ps1 -PythonExe (Get-Command python).Source
Get-ScheduledTask -TaskName InventoryPlusForecastWorker,InventoryPlusForecastMaintenance |
  Select-Object TaskName,State
```

The task account needs read access to the backend source, Python environment,
and protected `.env`, plus write access to `.runtime` for cursor and logs.
Restrict `.runtime\logs` to that account and administrators. Tasks use startup
and daily recovery triggers, refuse parallel instances, retry three times at
one-minute intervals after a process failure, and have no execution time limit.
The maintenance process uses five-minute cycles, at most four pages of ten
products per cycle, and the durable cursor. The worker polls independently
with concurrency 1. No personal Admin session or open terminal is required.

Only after separate approval for the full initial population and unattended
operation, enable and start the tasks:

```powershell
Enable-ScheduledTask -TaskName InventoryPlusForecastWorker,InventoryPlusForecastMaintenance
Start-ScheduledTask -TaskName InventoryPlusForecastWorker
Start-ScheduledTask -TaskName InventoryPlusForecastMaintenance
```

The first maintenance cycle continues from the five-product trial cursor and
visits the remaining catalog in bounded pages. Later cycles wrap and identify
new products, revision changes, and new Manila business dates. Database job
uniqueness prevents duplicate logical work; terminal failed or cancelled
identities are reported rather than retried forever. Successful snapshots
remain available while a refreshed identity is queued or running, with stale
status shown by snapshot reads. Worker leases recover after a crash or hard
Task Scheduler stop; Ctrl+C in a console uses the worker's graceful path.

## Monitoring and stop controls

```powershell
Get-ScheduledTaskInfo -TaskName InventoryPlusForecastWorker,InventoryPlusForecastMaintenance |
  Select-Object TaskName,LastRunTime,LastTaskResult,NextRunTime
Get-ChildItem .\.runtime\logs\forecast-*.log | Sort-Object LastWriteTime -Descending |
  Select-Object -First 4 Name,LastWriteTime,Length
```

Maintenance logs include `duration_ms`, `coverage`, queued IDs, skipped, and
preparation errors. Worker logs include per-job `elapsed_ms`, safe failure
codes, and final counters. Alert on task down, absent maintenance logs for
more than two intervals, growing failed/cancelled coverage, or no queue
progress across multiple lease periods. The owner's alert destination and
log retention policy remain deployment configuration.

Disable without deleting jobs, results, or history:

```powershell
Disable-ScheduledTask -TaskName InventoryPlusForecastWorker,InventoryPlusForecastMaintenance
Stop-ScheduledTask -TaskName InventoryPlusForecastMaintenance
Stop-ScheduledTask -TaskName InventoryPlusForecastWorker
```

No tasks are registered or activated by this repository change. The full
inventory run and unattended activation require separate approval.
