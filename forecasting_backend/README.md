# Inventory Plus forecasting backend

Stage 5A establishes the authoritative sales-to-daily-demand boundary. Stage
5B adds deterministic Mean28, LightGBM, and calibrated-blend candidates. Stage
5C adds deterministic replenishment guidance, and Stage 5D exposes both through
a read-only authenticated API for the Flutter Forecasting page. POS and
order-completion flows remain unchanged.

## Sales semantics

- Source: `public.order_history`, one persisted snapshot per order.
- Included: orders whose canonical status is `completed` and which have a
  non-null `completed_at` inside the requested half-open period.
- Excluded: pending/cancelled orders, returned orders, inventory adjustments,
  and checkout stock movements.
- Grain: product UUID + location UUID + Philippine business date.
- Quantities and units come from the immutable order item snapshot. A current
  SKU is included when the product still exists; SKU was not historically
  snapshotted by the current checkout schema.

The database RPC is authenticated with the Inventory Plus app-session token,
derives the location from that session, and is currently admin-only. The
Python layer validates the aggregate response and fills missing calendar days
with zero recorded sales before later forecasting stages consume it. Forecast
metadata distinguishes that sales assumption from confirmed underlying demand,
and explicit stockout evidence overrides the zero-sales target treatment.

Returned orders are excluded in full because the verified schema has no
line-level refunded quantity. Partial-return net-demand logic must wait for a
canonical refund model rather than estimating quantities.

## Mean28 baseline

`Mean28Forecaster` forecasts each product/location series independently. Its
input is the Stage 5A `DailyDemand` contract plus an explicit history boundary:

- With at least 28 known calendar days, it averages the latest 28 days.
- Missing RPC rows inside that boundary are zero-sales days. They are not
  silently represented as confirmed unconstrained demand.
- With 1-27 days, it averages the available calendar days and marks the result
  as `insufficient_history` cold-start using `available_day_mean`.
- With no known history, it emits a nonnegative zero forecast marked
  `no_history` cold-start using the explicit `zero` strategy.

Every forecast includes the model/version, lookback and sample sizes, cold-start
state, product/location identity, and dataset provenance. Historical is a data
role; real versus synthetic is a separate provenance field. Unit tests use only
`synthetic` datasets through `from_synthetic_observations`. A future live caller
must wrap validated RPC observations with `from_real_observations`; neither the
model nor the tests persist synthetic records. Batch forecasting rejects mixed
real/synthetic inputs.

The baseline deliberately has no runtime timestamp or randomness, so identical
inputs produce identical forecasts. It is the auditable fallback and comparison
model for the LightGBM implementation.

## Availability and stockout censoring

`AvailabilityEvidence` is optional and remains separate from Stage 5A sales.
When a date is explicitly marked `stockout`, its sales are a censored target:
Mean28 excludes it from the denominator, LightGBM excludes it from training
labels, and rolling-origin calibration excludes it from scoring. Its lag value
is imputed only from earlier values, never later values. Incomplete availability
coverage is reported in `DataQualityMetadata`; missing sales rows are therefore
not silently claimed to be zero underlying customer demand.

Stage 5A currently supplies sales but not availability evidence. A canonical
inventory-availability source must be connected before real-store stockout
censoring can be considered complete.

## LightGBM candidate

`LightGBMForecaster` trains a fresh deterministic model for one product/location
series. It never loads the Walmart model or any other externally trained model
as a validated Inventory Plus model. Features use only information available
before each target date: lags 1/7/14/28, prior 7/28-day means, calendar cycles,
and a chronological trend index. Multi-day forecasts are recursive and remain
finite and nonnegative.

The default model requires at least 84 history days and 40 uncensored training
rows. Missing LightGBM, insufficient history, insufficient uncensored labels,
training errors, and invalid predictions all produce an explicit Mean28
fallback rather than fabricated ML output.

## Rolling-origin calibration and blend

`RollingOriginBacktester` uses expanding chronological windows. Every validation
date is later than its training cutoff. The configurable calibrated candidate:

1. creates out-of-fold LightGBM and Mean28 forecasts on earlier history;
2. forms `0.5 * LightGBM + 0.5 * Mean28` for each uncensored point;
3. learns one multiplicative factor as aggregate actual / aggregate prediction;
4. bounds that factor to the configured safe interval; and
5. applies it to the final 50/50 forecast.

If valid earlier calibration points are insufficient, the candidate returns
Mean28 with a structured fallback reason. Forecast metadata includes model and
component versions, horizon, provenance, calibration factor/period/point count,
cold-start state, fallback reason, and data-quality warnings.

Historical is a dataset role; `real` and `synthetic` are mutually exclusive
provenance values. Batch APIs reject mixed provenance. Automated tests use
controlled synthetic histories only and do not write any database records.
Synthetic holdouts validate implementation behavior, not hardware-store
accuracy or production readiness.

The Stage 4 Python scripts referenced by the implementation brief were not
present in the checked-out repository or its file history. The 50/50 blend and
multiplicative calibration above therefore implement the supplied Stage 4
methodology rather than copying an unavailable artifact.

Stage 5A live Supabase behavioral verification remains blocked until an
isolated database is available.

## Stage 5C recommendation engine

`RecommendationEngine` is a deterministic layer above the forecasting models.
It uses `Decimal` arithmetic and never calls Gemini, writes to Supabase, or
creates purchase orders.

Verified current inventory semantics:

- `products.product_quantity` is reduced when an order is created and restored
  when that order is cancelled. It is therefore saleable stock already net of
  active-order reservations.
- The engine's `NET_OF_RESERVATIONS` basis adds reported reservations back only
  to form a gross equivalent before applying the standard inventory-position
  formula. This prevents subtracting the same commitment twice.
- Existing restock approvals are labeled "Quantity received" and add stock only
  after approval. They are not purchase orders or confirmed on-order inventory.
- The current schema has no verified supplier lead time, MOQ, pack size,
  availability, purchase-order, backorder, safety-stock, or unit-conversion
  model. These are explicit Stage 5C inputs; missing essentials produce
  `NEEDS_REVIEW`.
- `products.max_quantity` is accepted as the configured per-product capacity
  snapshot. The generic measurements table contains unit names/symbols but no
  conversion factors, so conversions must be supplied explicitly.

The implemented formulas are:

```text
Inventory position = gross on-hand equivalent + confirmed on-order
                     - unfulfilled reservations - backorders
Reorder point = expected lead-time demand + safety stock
Protection period = supplier lead time + review period
Target inventory = forecasted protection-period demand + safety stock
Preliminary quantity = max(0, target inventory - inventory position)
```

For protection periods within the supplied forecast horizon, daily forecasts
are summed directly. If a requested period exceeds the horizon, the documented
approximation is `forecast-horizon average daily demand × requested days`; the
result is marked `NEEDS_REVIEW`. The engine does not assume a 28-day forecast is
the supplier lead time.

MOQ is applied before pack-size ceiling. Explicit supplier/inventory unit
conversion is applied before capacity checks. When capacity and supplier
constraints conflict, the engine either returns a feasible packed quantity with
a review warning or returns no exact quantity when the MOQ cannot fit.

`no_history` is treated as unknown demand. A timestamped manual daily estimate
with a rationale can drive a provisional cold-start calculation, but the result
still requires review. Safety stock must be supplied as actual, configured, or
an explicit assumption; the engine does not invent statistical uncertainty.

Every result includes the input inventory and supplier snapshots, source
timestamps, forecast model/version/provenance/data quality, policy version,
intermediate calculations, warnings, explanations, and the human-approval flag.

## Stage 5D/5F forecasting API

The FastAPI application in `app/api` is an adapter around the Stage 5A, 5B,
and 5C modules; it contains no duplicate forecasting or replenishment math.
Forecast analysis remains read-only. Stage 5F adds only the scoped Admin
configuration read/write endpoints:

```text
POST /v1/forecasting/products/{product_id}/analysis
GET /v1/forecasting/products/{product_id}/replenishment-config
PUT /v1/forecasting/products/{product_id}/replenishment-config
Authorization: Bearer <Inventory Plus app session token>
```

The request selects `mean28`, `lightgbm`, or `calibrated_blend` (`blend` is
also accepted), a 1-90 day horizon, and an optional cold-start manual daily
demand estimate. The response preserves product/location identity, model and
policy versions, provenance, source and generation timestamps, data-quality
warnings, recommendation calculations, and explicit read-only capability
flags. There are no inventory or purchase-order mutation routes.

In `supabase` mode, the server restores the opaque Inventory Plus session with
`profile_restore_session_v1`, permits Admin profiles only, derives the
authorized location from that restored profile, and fetches historical sales
through `forecast_daily_demand_v1`. Product identity, current saleable stock,
capacity, and product timestamps come from the forecasting-only,
session-authorized `forecast_product_context_v1` RPC. A client-provided
location is only a consistency assertion; it cannot expand the session scope.
The API uses a Supabase publishable key and never sends a service-role
credential to Flutter.

The production adapter has no dependency on the undeployed Stage 6B.7
`forecast_product_snapshot_v1` function and performs no direct product-table
REST query. Before starting the API, the target Supabase environment must have
the following forecasting dependencies, in order:

1. `private.require_app_session_v1` and `profile_restore_session_v1` from the
   existing application-session migration;
2. `database/stage_5a_daily_demand.sql`; and
3. `database/stage_5d_forecast_product_context.sql`.

The configuration endpoints additionally require
`database/stage_5f_forecast_replenishment_configuration.sql`. Until that
migration is explicitly approved and applied, the production adapter detects
PostgREST's missing-function response, keeps configuration reads/writes
unavailable with an explicit HTTP 503, and continues read-only analysis with
unknown replenishment inputs and `NEEDS_REVIEW`.

Both forecasting RPCs are read-only, Admin-only, and derive location from the
opaque session. Deploy and behavior-test them in an isolated Supabase project
before applying them to production.

The currently verified product record supplies saleable on-hand and maximum
capacity only. Confirmed inbound orders, backorders, supplier lead time/MOQ/
pack availability, safety stock, availability history, and conversions remain
unconfigured canonical sources. The production adapter therefore returns a
forecast with `NEEDS_REVIEW` instead of inventing those inputs.

The recommendation policy is periodic review with an order-up-to target. The
reorder point communicates urgency; the protection-period target determines
the suggested quantity. Consequently, an above-reorder-point item can still
have a positive scheduled top-up without being labeled an urgent reorder.

For isolated development only, `synthetic` mode uses an in-memory fixture and
an explicit development token. It never connects to or writes synthetic sales
into Supabase, and every response is labeled synthetic.

Stage 5E hardens that boundary: synthetic mode is rejected when
`FORECAST_DEPLOYMENT_ENV=production`, has no built-in/default access token, and
requires both a `development` or `test` deployment environment and an explicit
`FORECAST_SYNTHETIC_SESSION_TOKEN`. The adapter also rejects direct construction
unless those non-production settings explicitly enable it.

For `no_history`, the numerical forecast remains a zero technical fallback and
the response sets `zero_is_unknown_demand=true`; this is never represented as
confirmed zero customer demand. An authenticated Admin may attach a manual
daily-demand estimate only to a cold-start result. Quantity, unit, rationale,
explicit staff confirmation, authenticated profile identity, timestamp, and
source are returned as provisional recommendation metadata. The estimate does
not alter the numerical historical forecast and never creates sales history.
Missing supplier, lead-time, safety-stock, inbound-order, backorder, or unit-
conversion inputs still produce `NEEDS_REVIEW` and may leave the suggested
quantity uncalculable while preserving the forecast-only result.

Required server configuration:

```text
FORECAST_API_MODE=supabase
FORECAST_DEPLOYMENT_ENV=production
SUPABASE_URL=<project URL>
SUPABASE_PUBLISHABLE_KEY=<publishable/anon key, never service role>
FORECAST_REVIEW_PERIOD_DAYS=<explicit nonnegative integer>
FORECAST_POLICY_VERSION=stage5d-periodic-review-v1
FORECAST_UPSTREAM_TIMEOUT_SECONDS=15
FORECAST_API_HOST=127.0.0.1
FORECAST_API_PORT=8000
FORECAST_CORS_ORIGINS=http://127.0.0.1:7357,http://localhost:7357
FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=false
```

Stage 2.9C recommendation tracking remains disabled by default. After its SQL
migration has passed isolated-database review and has been manually approved,
the FastAPI process may be configured with both:

```text
FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED=true
SUPABASE_SECRET_KEY=<server-only sb_secret key>
```

`SUPABASE_SECRET_KEY` must exist only in the backend process environment. Never
put it in Flutter `--dart-define` values, browser code, API payloads, URLs, or
logs. A legacy `SUPABASE_SERVICE_ROLE_KEY` is accepted for controlled migration,
but a scoped `sb_secret_` key is preferred. Enabling persistence without a
distinct server secret fails at startup. The ordinary forecasting workflow is
unchanged while the flag is false.

Run locally from `forecasting_backend` after installing `requirements.txt`:

```powershell
python run_api.py
```

For an isolated synthetic development server, use an explicit non-production
token and no Supabase credentials:

```powershell
$env:FORECAST_API_MODE = 'synthetic'
$env:FORECAST_DEPLOYMENT_ENV = 'development'
$env:FORECAST_SYNTHETIC_SESSION_TOKEN = '<explicit local-only token>'
$env:FORECAST_API_HOST = '127.0.0.1'
$env:FORECAST_API_PORT = '8000'
python run_api.py
```

Keep `127.0.0.1` for Windows desktop. Use `0.0.0.0` only when an emulator or
physical device must reach the development server. Android emulator clients
use `http://10.0.2.2:8000`; a physical device uses the PC's LAN address and
must be on the same trusted network. Local cleartext HTTP is enabled only in
the Android debug manifest; release deployments must use HTTPS.

Flutter reads `FORECAST_API_URL` first from `--dart-define` and then from its
existing ignored `lib/.env` file. Example launches from the repository root:

```powershell
flutter run -d windows --dart-define=FORECAST_API_URL=http://127.0.0.1:8000
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 7357 --dart-define=FORECAST_API_URL=http://127.0.0.1:8000
flutter run -d <android-emulator-id> --dart-define=FORECAST_API_URL=http://10.0.2.2:8000
flutter run -d <physical-device-id> --dart-define=FORECAST_API_URL=http://<PC-LAN-IP>:8000
```

For Flutter web, each browser origin must be listed explicitly in
`FORECAST_CORS_ORIGINS`; do not use a wildcard with authenticated requests.

The Flutter application sends its current opaque application session token;
it does not embed a Supabase or synthetic credential. Gemini may provide future
narrative explanation, but neither the API client nor the Forecasting page
allows Gemini to calculate or override any numeric value.

## Hardware classification test service

`POST /v1/classification` is an authenticated Admin-only, read-only endpoint
used by the temporary Flutter `/classification_test` page. Its request selects
`engine: "existing"` or `engine: "gemini"`; both return the same response
contract and neither reads or writes product records.

The existing engine runs exact audited rules first. Unmatched input is compared
only with the product types in `app/classification/hardware_taxonomy.json` using
typo-tolerant lexical similarity and the local
`sentence-transformers/all-MiniLM-L6-v2` embedding model through
`fastembed`/ONNX Runtime. The model cannot generate new labels.

The approximately 90 MB model is downloaded from Hugging Face on the first
generalized classification and then cached locally. This engine has no hosted
AI call or per-request fee. Set `HARDWARE_CLASSIFIER_MODEL_CACHE` to choose a
cache directory. If model loading fails, normal API mode falls back to the same
closed taxonomy's lexical matcher and identifies that method in the response.

The Gemini engine uses the official `google-genai` SDK and the cost-efficient
`gemini-3.5-flash-lite` model. The Python backend reads
`GEMINI_CLASSIFICATION_KEY` from the process environment or the existing local
`.env`/`lib/.env`, explicitly passes it to the SDK client, and never returns or
logs it. The Flutter application receives no key. Requests use structured JSON,
a 20-second SDK timeout, and bounded retries for HTTP 408, 429, and transient
5xx failures. The API maps exhausted rate limits to 429, timeouts to 504, and
other Gemini availability failures to 503.

Gemini can only propose an identifier from the controlled taxonomy. The backend
rejects invented labels and proposals that fail the taxonomy's local context
guards, canonicalizes intended use/category from local data, and caps high
confidence unless the product name directly supports the type. Gemini output
never supplies seasonal relevance, sources, or percentages. After identity
validation, the existing local seasonal knowledge base alone resolves those
fields.

Seasonal resolution is hierarchical and recalculated on each classification:

```text
product type -> intended-use group -> industry-activity group -> relevance
```

A documented product-specific rule takes priority. Otherwise, a controlled
product/use link may inherit an activity relationship only when that activity
has cited support. The current weather-exposed construction group uses PAGASA
Philippine climatology plus PIDS evidence that construction labor is vulnerable
to rainfall-related work-hour reductions. The inherited result is explicitly
provisional and is not SKU-sales proof. Mixed-use tools, poultry netting, and
unmapped products remain `unknown`/`insufficient`.

Classification responses expose `seasonal_match_type` (`product_specific`,
`inherited_industry_activity`, or `insufficient`) and a readable
`seasonal_hierarchy`. Results are not stored on products, so a deployed
knowledge-base update is used when the backend reloads and the product is
classified again. There are no background writes.

Generalized matches are capped at medium product-identification confidence and
always return seasonal relevance `unknown` with insufficient seasonal-demand
evidence. Low-score, close, unsupported, or context-poor matches return UNKNOWN
and request clarification. Classification has no forecasting, replenishment,
inventory-write, or product-creation effect.

Run the reproducible evaluation after the model is cached:

```powershell
$env:PYTHONPATH = "."
python run_classification_evaluation.py
```

The complete regression, safety-validation, and frozen final-holdout results
are written to `simulation_reports/HARDWARE_CLASSIFICATION_REPORT.md` and its
JSON companion.

The direct comparison uses the same frozen final holdout for both engines and
incurs Gemini API usage:

```powershell
$env:PYTHONPATH = "."
python run_gemini_classification_comparison.py
```

Results are written to
`simulation_reports/GEMINI_CLASSIFICATION_COMPARISON.md` and its JSON companion.
The runner paces calls for the observed free-tier request limit. API pricing and
quotas remain controlled by the Google account associated with the configured
key and may change independently of this repository.

The hierarchical seasonal acceptance evaluation is local and incurs no Gemini
usage:

```powershell
$env:PYTHONPATH = "."
python run_seasonal_hierarchy_evaluation.py
```

It writes `simulation_reports/SEASONAL_HIERARCHY_EVALUATION.md` and its JSON
companion. These acceptance cases validate resolver behavior and evidence
boundaries; they are not an independent estimate of hardware-retail demand.

## Tests

From this directory:

```powershell
$env:PYTHONPATH = "."
python -m unittest discover -s tests -v
```

These tests are pure and do not connect to a live or production database.

Pinned local model dependencies are listed in `requirements.txt`.

