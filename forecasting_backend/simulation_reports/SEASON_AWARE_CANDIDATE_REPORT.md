# Philippine Season-Aware Forecasting Candidate

Date: 2026-11-09  
Status: Experimental; **not approved for normal application or replenishment use**

## Implementation boundary

The candidate is deliberately isolated from `ForecastAnalysisService`. Mean28,
the existing LightGBM model, the calibrated blend, the recommendation engine,
the FastAPI routes, and Flutter remain unchanged. The normal launch commands are
unchanged.

No Supabase migration is required. The evidence registry is version-controlled
backend research configuration, and the live catalog/history were inspected
read-only.

## Philippine climate context

The resolver uses:

- PAGASA's Philippine dry/rainy climatological context:
  <https://www.pagasa.dost.gov.ph/information/climate-philippines>
- Modified Coronas Type I context for the inspected Biñan, western-Laguna store,
  corroborated by the DA-BSWM Laguna climate map:
  <https://www.bswm.da.gov.ph/wp-content/uploads/LAGUNA_SUITABILITY_ROBUSTA.pdf>

For the experimental resolver, December-April are the Type I dry core,
June-October are the rainy core, May is the dry-to-rainy transition, and
November is the rainy-to-dry transition. Each forecast date is resolved
independently. Boundary months are a documented modeling interpretation that
prevents a 28-day horizon from receiving one coarse label; they are not demand
multipliers or observed onset declarations.

The store record contains an address but no coordinates. The Type I assignment
is therefore `corroborated_external_map`, not coordinate-verified. A future
production rollout to multiple locations requires verified coordinates and a
versioned location-to-climate assignment.

## Product evidence registry

The registry covers all 13 active products inspected on 2026-11-09. It records
source, rationale, relevance, evidence level, and qualitative guidance. Every
entry has `numerical_adjustment_allowed=false`.

The Philippine mechanism source is PIDS, *When Rain Falls, Work Slows*:
<https://pids.gov.ph/publication/discussion-papers/when-rain-falls-work-slows-rainfall-variability-and-working-hours-in-the-philippine-labor-market>.
It supports a general rainfall/work-exposure pathway, not any SKU coefficient.

| SKU | Product | Relevance | Evidence level | Numerical effect |
|---|---|---|---|---|
| SKU-001 | Heavy Duty Staple Gun | Mixed project activity | Provisional domain hypothesis | Prohibited |
| SKU-002 | Concrete Nails 2-inch | Construction activity | Corroborated general mechanism | Prohibited |
| SKU-1004 | Claw Hammer | Mixed project activity | Provisional domain hypothesis | Prohibited |
| SKU-1005 | Phillips Screwdriver | Mixed project activity | Provisional domain hypothesis | Prohibited |
| SKU-1006 | Tape Measure | Construction activity | Provisional domain hypothesis | Prohibited |
| SKU-1007 | Cordless Drill | Mixed project activity | Provisional domain hypothesis | Prohibited |
| SKU-1008 | PVC Pipe | Plumbing installation and repair | Provisional domain hypothesis | Prohibited |
| SKU-1009 | Teflon Tape | Plumbing installation and repair | Provisional domain hypothesis | Prohibited |
| SKU-1010 | Safety Goggles | Construction activity | Provisional domain hypothesis | Prohibited |
| SKU-3UWPD0GN | Adjustable wrench | Mixed project activity | Provisional domain hypothesis | Prohibited |
| SKU-4W6D3LVI | realtime_test2 | Unclassified test item | Unknown | Prohibited |
| SKU-69QAUJ4Z | test item | Unclassified test item | Unknown | Prohibited |
| SKU-K1CB7XQV | Concrete Nails 1-inch | Construction activity | Corroborated general mechanism | Prohibited |

No reviewed source provides a defensible Philippine seasonal demand magnitude
for these exact products. The registry consequently supplies knowledge and
guidance from the outset without fabricating numerical certainty.

## Experimental model

`SeasonAwareLightGBMForecaster` preserves the existing lag, rolling-mean,
weekday, annual-cycle, and trend features. It adds:

- date-specific Type I season and transition indicators;
- the configured climate-type indicator;
- product relevance-class indicators; and
- season/relevance interaction indicators.

These are features, not fixed effects. LightGBM must learn any quantity impact
from observations available at the training origin. Insufficient history,
missing product evidence, missing location context, unavailable LightGBM, or an
invalid prediction fails back to Mean28. Metadata marks the candidate as
experimental and states that the registry contains no numerical multiplier.

## Database-fixture reconciliation

The offline evaluator mirrors the deterministic SQL 02 formula but does not
provide its demand-pattern label or future formula to any model. A read-only
Supabase aggregation was compared with the mirror before evaluation.

- History: 2025-01-01 through 2026-11-07, 676 calendar days
- Products: 13
- Reconciliation: exact match for every product's first/last sale date,
  nonzero-sales day count, and total quantity
- Last-28 verification: matches the independently verified 2026-10-12 through
  2026-11-08 Mean28 window, including the final zero-sale calendar day

## Leakage controls

- Each training dataset ends at its rolling origin.
- Each training dataset is capped at the deployed latest-365-calendar-day
  history window.
- No training observation may be later than the origin.
- Every forecast date must be strictly later than its origin.
- Future demand is looked up only after predictions are produced.
- `demand_pattern` is used only to group evaluation results.
- The SQL generating formula and future deterministic noise are not model inputs.
- Season labels are future-known climatology; realized future rainfall is not used.
- Regular 28-day origins are supplemented with April/May and October/November
  transition origins.

The evaluation covers 29 origins, 28 forecast days per origin, 13 products, and
10,556 daily observations per model.

## Overall accuracy

WAPE and signed bias below are percentages; bias is predicted minus actual.

| Requested model | WAPE | MAE | Signed bias | Predicted / actual units |
|---|---:|---:|---:|---:|
| Mean28 | 22.649% | 0.8337 | -1.817% | 38,148.00 / 38,854 |
| Existing LightGBM | **16.928%** | **0.6231** | -6.547% | 36,310.06 / 38,854 |
| Calibrated blend | 20.267% | 0.7460 | **+0.450%** | 39,028.80 / 38,854 |
| Seasonal LightGBM | 16.954% | 0.6240 | -6.574% | 36,299.92 / 38,854 |

The seasonal candidate is 0.026 percentage points worse in WAPE than existing
LightGBM. This small difference should be treated as no demonstrated aggregate
improvement, not as evidence of harm or benefit in real demand.

The calibrated blend used its calibrated model in 338 of 377 product-origin
forecasts and its designed Mean28 fallback in 39 early-history forecasts.

## Product-level WAPE

`n/a` means the product had zero actual demand, so WAPE is undefined.

| SKU | Mean28 | Existing LGBM | Blend | Seasonal LGBM | Seasonal vs existing LGBM |
|---|---:|---:|---:|---:|---|
| SKU-001 | **14.00%** | 19.96% | 16.58% | 19.96% | Tied |
| SKU-002 | 24.64% | **15.94%** | 21.74% | 16.01% | Worse |
| SKU-1004 | 22.59% | 13.72% | 18.35% | **13.70%** | Better |
| SKU-1005 | 21.84% | 18.26% | 19.18% | **18.23%** | Better |
| SKU-1006 | 37.49% | **30.88%** | 36.41% | **30.88%** | Tied |
| SKU-1007 | 178.69% | **108.91%** | 181.78% | **108.91%** | Tied |
| SKU-1008 | 12.33% | 11.88% | **10.40%** | 11.90% | Worse |
| SKU-1009 | 16.14% | **5.35%** | 11.09% | **5.35%** | Tied |
| SKU-1010 | 23.44% | **23.11%** | 24.35% | 23.29% | Worse |
| SKU-3UWPD0GN | **17.27%** | 18.28% | 16.96% | 18.28% | Tied |
| SKU-4W6D3LVI | 197.91% | **72.98%** | 169.34% | **72.98%** | Tied |
| SKU-69QAUJ4Z | n/a | n/a | n/a | n/a | Zero-demand control |
| SKU-K1CB7XQV | 157.09% | **80.83%** | 127.78% | **80.83%** | Tied |

Against existing LightGBM, the seasonal candidate is better for 2 products,
worse for 3, tied for 7, and not WAPE-comparable for the zero-demand product.
Against Mean28 it is better for 10 and worse for 2; against the calibrated blend
it is better for 9 and worse for 3.

## Results by season

| Season | Mean28 WAPE | Existing LGBM | Blend | Seasonal LGBM |
|---|---:|---:|---:|---:|
| Dry core | 22.079% | **16.048%** | 19.415% | 16.064% |
| Rainy core | 22.811% | 17.046% | 20.850% | **17.033%** |
| Transition months | 22.822% | **17.378%** | 20.051% | 17.465% |

Transition detail:

| Transition | Mean28 WAPE | Existing LGBM | Blend | Seasonal LGBM |
|---|---:|---:|---:|---:|
| To rainy | 18.753% | **11.917%** | 17.056% | 11.972% |
| To dry | 28.854% | **25.476%** | 24.493% | 25.609% |

The candidate does not improve transition forecasting. Its rainy-core result is
slightly better, but its dry-core and both transition results are worse than
existing LightGBM.

## Limitations

1. The synthetic month effects were chosen for test coverage and do not validate
   Philippine hardware-market behavior.
2. Only climatology is available. No archived PAGASA outlook vintages, observed
   rainfall, onset declarations, or station/grid data are included.
3. The current per-product model cannot safely transfer numerical effects to a
   cold-start product. Provisional profiles therefore remain qualitative.
4. The store's Type I assignment needs coordinate verification before production
   use or extension to another location.
5. Intermittent and dead-stock products have unstable percentage metrics because
   their actual totals are small.
6. Tuning seasonal definitions or features against this same completed backtest
   would overfit the evaluation. A new frozen holdout or additional simulation
   scenarios are required for subsequent model selection.

## Recommendation

Do **not** activate the season-aware candidate in the normal FastAPI/Flutter
workflow or replenishment recommendations.

Retain:

- Mean28 as the transparent baseline/fallback;
- existing LightGBM and calibrated blend as comparison candidates; and
- the seasonal implementation as an offline experimental candidate.

Before reconsidering activation, add coordinate-verified climate assignment,
archived as-of PAGASA outlook data, multiple real seasonal cycles with stockout
and promotion controls, and a newly frozen leakage-safe evaluation. Activation
should require material product-level and transition-period improvement without
degrading stable/trending products.
