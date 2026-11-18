# Phase 7 multi-model background preparation

The selected-model Generate/Refresh action now sends mean28, lightgbm, blend
(Calibrated Blend alias), or seasonal_experimental to the existing Admin-scoped
bootstrap route. Each job keeps its own requested-model identity and frozen
input digest. Seasonal Experimental uses 1,095 historical days; the other three
use 365. The worker continues to create requested, recommendation and
preliminary outputs through the existing DemandForecastExecutor. No model
formula or client credential boundary changed.

## Deployment gate

`database/stage_7_multi_model_enqueue.sql` is a REVIEW-ONLY forward migration.
The deployed Stage 6 enqueue RPC currently rejects non-Blend model keys.
Install this exact patch only after isolated PostgreSQL compatibility checks
and owner approval. It replaces the recovery-aware enqueue function in place,
retaining recovery generation and job uniqueness semantics. Do not copy the
older Stage 3B function over Stage 6.

Deploy the backend and Flutter changes together after SQL approval. Restart
FastAPI and background worker so both compute the same source fingerprint.
The materializer source participates in the implementation digest. Existing
queued jobs may have the older digest and will be superseded by the updated
worker; prepare new jobs through the authorized path. Historical successful
results stay immutable and available under their original identity.

The unattended 3:00 AM maintenance sweep remains the approved default Blend
policy. Non-Blend model generation is initiated through the existing authorized
single-product action and processed by the independent worker. No automatic
catalog-wide four-model fan-out is introduced.

## Review-only validation

Verify the SQL in an isolated PostgreSQL 17 clone, including: the exact Stage 6
function owner, service-role-only EXECUTE, recovery generations, model/version
and 365/1095-day guards, duplicate logical job identity, stale revision rejection,
and unchanged priority/lease behavior. Verify one product per model, including
Seasonal fallback, and that clients cannot call the private queue RPC. No SQL,
Flutter tooling, tests, Git or live jobs were executed during this source edit.
