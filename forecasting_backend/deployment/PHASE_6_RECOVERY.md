# Phase 6 terminal failure recovery

Stage 6 is already installed. The forward-only correction
`database/stage_6a_forecast_recovery_profile_id.sql` requires separate approval.
It replaces the mistaken UUID operator type with BIGINT. It was not deployed
during this correction; no recovery jobs were run.

An operator supplies a unique approval UUID, existing Admin BIGINT `public.profiles.id` (for example `1`), a failed job UUID, and one enumerated correction reason.
The service-only RPC checks the installed maintenance location allowlist, active
product, current revisions, current Manila date and local implementation digest.
Possession of the protected service credential is the authorization boundary.
The RPC additionally requires an active Admin profile in the allowed location.
The supplied profile ID records the approver; it is not a replacement for a
service credential or proof of a personal login. Approval IDs remain UUIDs.
The audit ID is retained as a historical value even if a profile is later removed.
Stage 6A locks jobs and aborts if any UUID operator audit already exists, rather
than casting or erasing it. Read-only inspection found zero such rows.
Existing job identities, errors, recovery limits, and result constraints are unchanged.
Never expose this command through an unauthenticated HTTP route or call it from
automatic maintenance. The CLI additionally requires `--approved`.

Recovery inserts a new child job with identical demand identity. It retains the
parent, its error and attempts unchanged. Three explicit recovery generations
are allowed; each gets the existing bounded transient-retry budget. A unique
parent reference plus row locking serializes competing recovery requests. Repeating
the request returns the existing child, including a failed child; another recovery
requires explicit authorization targeting that child. Cancelled jobs cannot recover.
Revision locking uses the same revision-then-job order as enqueue. Existing result
logical uniqueness and lease validation remain unchanged, preventing two successful
publications for one identity. Ordinary enqueue defaults to generation zero and
returns the latest generation on a duplicate. Maintenance already selects the latest
job and therefore does not repeatedly prepare terminal recovery identities.

The worker uses its existing executor, bundle serializer and publication RPC. No
new worker or maintenance service is needed. Source/configuration changes that alter
the implementation digest require normal materialization of a new identity; recovery
does not relabel old frozen inputs with a new implementation digest.

## Verification and approval

Run the migration on an isolated clone first, then use:

```text
psql <ISOLATED_DSN> -v ON_ERROR_STOP=1 -f database/stage_6_forecast_recovery.sql
psql <ISOLATED_DSN> -v ON_ERROR_STOP=1 -f database/stage_6a_forecast_recovery_profile_id.sql
psql <ISOLATED_DSN> -v operator_id=<EXISTING_ADMIN_PROFILE_ID> -v failed_job_id=<CURRENT_DATE_FAILED_FIXTURE> -f database/stage_6_forecast_recovery_validation.sql
```

For a concurrent test in that clone, have two sessions BEGIN and invoke recovery
on the same fixture. Hold session A before COMMIT. Session B must wait; after A
commits, B must return the same child with duplicate=true. Confirm exactly one child
and unchanged parent. Do this only in the disposable clone: the concurrency test
needs a committed fixture to be visible to both sessions. PostgreSQL concurrency
and migration execution were not verified locally because no PostgreSQL executable
was available. Python mocked tests do not replace this gate.

An automated two-connection version is provided in
`tests.test_forecast_recovery_postgres`. Configure `FORECAST_RECOVERY_ISOLATED_DSN`
privately, `FORECAST_RECOVERY_TEST_JOB` to a current failed fixture UUID,
`FORECAST_RECOVERY_TEST_OPERATOR_ID` to its location's existing Admin BIGINT ID, and
`FORECAST_RECOVERY_ISOLATED_CONFIRM=disposable`, then run
`python -m unittest tests.test_forecast_recovery_postgres -v` with psql on PATH.
This test commits one child in the disposable clone; use a fresh failed fixture for
each run. Do not use the Inventory Plus testing project as this disposable fixture.

After successful isolated validation, approve installation of Stage 6A only
on the existing testing project. Do not rerun the original Stage 6 migration. SQL Editor runs the complete BEGIN/COMMIT script.
Any error must roll back the transaction. Do not run isolated fixture tests on live
application data. The final read-only privilege query is safe after installation.

## Explicit recovery after installation

From forecasting_backend, with the protected server environment configured:

```text
python run_forecast_recovery.py --approved --location-id 11111111-1111-1111-1111-111111111111 --job-id <FAILED_JOB> --approval-id <APPROVAL_UUID> --operator-id 1 --reason publication_serialization_corrected
python run_forecast_worker.py --job-id <RETURNED_CHILD_JOB> --max-jobs 1 --concurrency 1
```

The second command is needed only for a controlled test without a running service.
In normal operation the existing worker consumes the child automatically. Verify
job status and its result through snapshot reads; queued does not mean succeeded.
Do not modify previous trial cursors/checkpoints. Keep each approval UUID in the
operator's change record; the child stores it permanently.

## Linux operation and disablement

Existing inventory-forecast-worker.service and inventory-forecast-maintenance.service
already run independently of FastAPI, restart on failure, bound concurrency to one,
and use the protected /etc/inventory-plus/forecast.env. Maintenance's StateDirectory
allows its cursor/lock writes under ProtectSystem=strict. Install both units under
/etc/systemd/system only after deployment approval; provision the inventoryplus OS
account, /opt/inventory-plus/forecasting_backend virtualenv, and protected env file.
Pin the same source and dependency versions on materializer and worker. Review the
combined 3 GiB service memory limits against VM RAM before activation.

```text
sudo systemctl daemon-reload
sudo systemctl enable --now inventory-forecast-worker inventory-forecast-maintenance
journalctl -u inventory-forecast-worker -u inventory-forecast-maintenance -f
```

These commands were not executed. Stop/disable both units to halt automatic work.
Disable recovery without deleting audit data by revoking service_role EXECUTE on
recover_forecast_job_v1. Before any recovery rows exist, a separately reviewed reverse
migration may restore the original enqueue definition and uniqueness. Once recoveries
exist, retain the additive schema and revoke the RPC rather than deleting history or
reinstating a uniqueness constraint that the historical generations cannot satisfy.

## Stage 6A read-only installation verification

After approved installation, run only these catalog queries before any recovery:

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='private' AND table_name='forecast_jobs'
  AND column_name IN ('recovery_operator_id','recovery_approval_id');
-- Expected: bigint operator; uuid approval.
SELECT p.oid::regprocedure, p.prosecdef, p.proowner::regrole, p.proconfig,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_exec,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS client_exec,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS server_exec
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='recover_forecast_job_v1';
-- Expected: one bigint-operator signature, postgres owner, SECURITY DEFINER,
-- pg_catalog/pg_temp search path, false / false / true execution privileges.
```

The migration is one transaction, removes the UUID RPC overload without CASCADE,
and reloads PostgREST's schema cache at commit. A failed statement rolls back all
changes. Do not retry recovery with the updated CLI until Stage 6A is installed.
