# Forecasting simulation in the existing Supabase project

`simulation_one_run.py` targets the existing Inventory Plus project
`pzotcznujkuzymndluwl`. It uses its own `SIM-FORECAST-ONE-RUN` location with
deterministic ID `b01ab806-c871-581d-ac4b-f2aa9c952cf9`. The live MCP audit
on 2026-11-21 found one operational location and no rows under this simulation
location, no `SIM-FC-*` products, and no simulation usernames. The runner permits
other stores and never selects their records for writes.

The simulation is additive and uses deterministic IDs. It performs no DELETE,
TRUNCATE, or replacement of operational rows. A completed run is validated on
replay. Partial runs may be retried on the same business day. Live triggers
reject UPDATE and DELETE on recommendation snapshots, allocations, and
reconciliations. A completed scenario cannot be row-reset without bypassing
those safeguards. To create a new scenario, review a new namespace and location.

## Configuration and commands

Install the existing backend dependencies and Psycopg 3:

```powershell
python -m pip install -r forecasting_backend/requirements.txt 'psycopg[binary]>=3.2,<4'
```

Set the following in the local environment. `FORECAST_API_URL` is the existing
HTTPS FastAPI deployment using this same project, with job materialization,
snapshot reads, and recommendation persistence enabled. Keep secret values out
of the repository.

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | Existing project's PostgreSQL connection string as `postgres` |
| `SUPABASE_URL` | `https://pzotcznujkuzymndluwl.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | Existing project's publishable key |
| `SUPABASE_SECRET_KEY` | Existing project's server-only key |
| `SIM_PROJECT_REF` | `pzotcznujkuzymndluwl` |
| `SIM_ADMIN_PASSWORD` | Password for the new simulation admin profile |
| `SIM_STAFF_PASSWORD` | Password for the new simulation staff profile |
| `FORECAST_API_URL` | Existing FastAPI deployment URL |
| `SIM_BACKUP_DIR` | Existing secure local directory outside the repository |
| `SIM_APPLY_ACK` | `APPLY:pzotcznujkuzymndluwl` for `--apply` |

Read-only preflight:

```powershell
python forecasting_backend/simulation_one_run.py --preflight
```

After explicit approval of the affected scope and restoration procedure, one
command performs the simulation:

```powershell
python forecasting_backend/simulation_one_run.py --apply
```

Preflight verifies the project identity, schema, functions, triggers, service
role permissions, and ownership of simulation IDs, SKUs, and usernames. Before
the first write, `--apply` archives all existing simulation-scoped rows into
`SIM_BACKUP_DIR`, reads the archive back, and reports its SHA-256 and row counts.
The archive may contain password and session hashes. Protect it as a secret.

## Exact scope and dependencies

Direct and API writes can affect `public.locations`, `public.profiles`,
`public.products`, `public.orders`, `public.order_history`,
`public.transaction_history`, `public.forecast_replenishment_configs`,
`public.approval_requests`, `public.forecast_recommendation_snapshots`,
`public.forecast_recommendation_receipt_allocations`,
`public.forecast_recommendation_reconciliations`,
`private.forecast_input_revisions`, `private.forecast_jobs`,
`private.forecast_execution_results`, `private.app_sessions`,
`private.approval_evidence_uploads`, and `storage.objects` in the
`approval_evidence` bucket. Existing triggers can also emit realtime signals,
notifications, loading clocks, and restock evidence. No existing user account,
role, store setting, operational product, or unrelated location is changed.

The live foreign-key audit confirmed product and location dependencies, job to
result references, and recommendation to allocation/reconciliation references.
Orders synchronize `order_history`, which increments forecast input revisions.
The script does not bypass triggers or security controls.

## Restoration and limitations

The JSON archive records the exact prior simulation rows. It is a review and
recovery reference, not an executable row-level restore. The safe operational
rollback after a completed run is to stop using the labeled simulation location
and leave its immutable audit trail intact. A database point-in-time restore
would also affect unrelated live writes and needs a separate operational
decision. No destructive cleanup runs automatically.

The runner creates 180 days of synthetic completed orders, roughly 1,300 sales
and checkout records, zero-sale days, durable worker forecasts, a current
recommendation, approval, stock-in, receipt allocation, reconciliation, and
WAPE/Bias checks. Eight historical LightGBM snapshots are calculated from
canonical demand strictly before their origins. Their backdated insert is a
disclosed simulation-only exception because the production save RPC rejects
forecasts older than 24 hours. The current recommendation uses the normal API.
Seasonal Experimental falls back for generated products because they are not
in its product-specific context registry.

This revision has not been applied to the live database. A JSON PASS report is
the runtime acceptance check. Inspect Flutter Overview and Tracking & Accuracy
against the existing API afterward.
