# Milestone 5 snapshot-path testing

The snapshot UI is gated separately in the API and Flutter builds. It never
falls back to `/analysis`; missing results remain pending or unavailable.

## Start the FastAPI read path

Open PowerShell in `forecasting_backend` and configure the existing local
testing-project settings in that process (do not place the secret in source
control or Flutter configuration):

```powershell
$env:FORECAST_API_MODE = 'supabase'
$env:FORECAST_DEPLOYMENT_ENV = 'development'
$env:FORECAST_REVIEW_PERIOD_DAYS = '7'
$env:FORECAST_SNAPSHOT_READS_ENABLED = 'true'
$env:FORECAST_CORS_ORIGINS = 'http://localhost:5173'
$env:SUPABASE_URL = 'https://pzotcznujkuzymndluwl.supabase.co'
# Set SUPABASE_PUBLISHABLE_KEY and SUPABASE_SECRET_KEY from the developer's
# existing local secret store. Never echo the secret or pass it to Flutter.
python run_api.py
```

The read endpoint calls `public.forecast_snapshot_page_v1` using the server-only
key. The SQL draft must be manually reviewed and installed before this setting
is enabled against the testing project. Without it the API returns the
configured unavailable response, not a synchronous forecast.

## Start Flutter in snapshot mode

In a second PowerShell window, from the repository root:

```powershell
flutter run -d chrome `
  --web-port=5173 `
  --dart-define=FORECAST_SNAPSHOT_MODE=true `
  --dart-define=FORECAST_API_URL=http://127.0.0.1:8000
```

Sign in with an authorized Inventory Plus Admin session. Open **Forecasting &
Restocking**. Overview is paginated at 25 products; products without snapshots
show their actual pending/unavailable status. Select the product with a
verified result (`ab0af441-e26b-4d9c-95b3-7b5fd0e42be1`) and open Product Forecast.
The detail view reads its saved 28-day requested, recommendation, and
preliminary series, retaining each stored producer label. Then open Tracking &
Accuracy to confirm existing saved-recommendation and WAPE/Bias evaluation
behavior remains available.

Changing model selection only requests that model's persisted snapshot. It does
not enqueue work or execute a model. Refresh re-reads saved state. Verify that
API logs show `snapshot.overview.read` / `snapshot.product.read` and no
`analysis.*` forecast-execution operations for page loading.

## Read-only database verification

This query verifies the already completed result without changing data:

```sql
select id, job_id, product_id, requested_model_key, horizon_days,
       jsonb_array_length(output_bundle #>
         '{outputs,requested_forecasts,series,0,points}') as requested_points,
       jsonb_array_length(output_bundle #>
         '{outputs,recommendation_forecasts,series,0,points}') as recommendation_points,
       jsonb_array_length(output_bundle #>
         '{outputs,preliminary_forecasts,series,0,points}') as preliminary_points
from private.forecast_execution_results
where id = '086e89bc-cd65-48fc-80d7-aa36ae5143bc';
```

The result should be the existing `blend` job with 28 points in each role.
This query was previously run read-only against the approved testing project;
it returned the expected 28/28/28 point counts.

## Scope of visible restock values

Overview and Product Forecast label any existing `forecast_recommendation_snapshots`
value as a **last saved** recommendation with its saved time. It is historical;
it is not recalculated against current inventory. Demand snapshot retrieval does
not fit models. A live current-stock recommendation requires the existing
recommendation calculation with current policy inputs and is not inferred from
the immutable demand snapshot.
