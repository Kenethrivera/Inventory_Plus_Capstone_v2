# Stage 2.6 Historical Accuracy and Seasonal Learning

**Stage decision: PASS**

## Imported-history verification

- Live database comparison: **PASS**.
- Frozen CSV integrity: **PASS**.
- Frozen coverage: 24 products x 1,461 dates = 35064 rows, 2022-11-10 through 2026-11-09.
- Demand rows: 26606 positive and 8458 explicit zero-demand rows.
- Shape mismatches: 0 missing and 0 unexpected product/date rows.
- Value/metadata mismatches against the frozen generator: 0 quantity and 0 metadata.
- Accuracy metrics include only the 24 imported seasonal products; the original products are deliberately kept outside this benchmark.

## Overall accuracy

| Horizon | Model | MAE | WAPE | Bias | Actual | Predicted |
|---:|---|---:|---:|---:|---:|---:|
| 7 | existing_lightgbm | 1.0626 | 31.66% | -1.29% | 10149.0 | 10018.1 |
| 7 | matched_nonseasonal_ablation | 1.0511 | 31.32% | -1.56% | 10149.0 | 9990.9 |
| 7 | mean28 | 1.0880 | 32.42% | -0.78% | 10149.0 | 10069.6 |
| 7 | product_specific_seasonal_lightgbm | 1.0472 | 31.20% | -2.12% | 10149.0 | 9934.0 |
| 28 | existing_lightgbm | 1.0695 | 31.92% | -1.08% | 40532.5 | 40095.8 |
| 28 | matched_nonseasonal_ablation | 1.0639 | 31.75% | -1.63% | 40532.5 | 39870.3 |
| 28 | mean28 | 1.1019 | 32.88% | -0.63% | 40532.5 | 40278.5 |
| 28 | product_specific_seasonal_lightgbm | 1.0601 | 31.63% | -2.07% | 40532.5 | 39692.2 |

## 28-day WAPE by seasonal group

| Group | Existing LGBM | Ablation | Seasonal LGBM | Mean28 |
|---|---:|---:|---:|---:|
| NEUTRAL | 33.74% | 33.27% | 33.32% | 34.89% |
| RAINY | 48.43% | 48.35% | 48.14% | 48.95% |
| SUMMER | 25.51% | 25.45% | 25.30% | 26.54% |

## 28-day WAPE by compatible unit

| Group | Existing LGBM | Ablation | Seasonal LGBM | Mean28 |
|---|---:|---:|---:|---:|
| bag | 25.58% | 25.66% | 25.48% | 26.46% |
| box | 25.62% | 25.36% | 25.34% | 26.38% |
| cu.m. | 67.59% | 67.02% | 67.28% | 66.55% |
| pail | 42.28% | 42.65% | 41.46% | 44.32% |
| pcs | 28.53% | 28.42% | 28.29% | 29.74% |
| roll | 45.26% | 44.82% | 45.32% | 45.68% |
| set | 105.88% | 100.70% | 100.80% | 126.88% |
| sheet | 78.84% | 78.87% | 77.89% | 77.42% |
| tube | 30.44% | 29.64% | 29.42% | 29.85% |

## 28-day WAPE by demand pattern

| Group | Existing LGBM | Ablation | Seasonal LGBM | Mean28 |
|---|---:|---:|---:|---:|
| intermittent | 77.10% | 76.38% | 76.59% | 75.94% |
| intermittent_low | 104.76% | 100.56% | 100.65% | 135.32% |
| neutral | 29.56% | 29.23% | 29.27% | 30.31% |
| no_sales | n/a | n/a | n/a | n/a |
| rainy | 37.96% | 38.09% | 37.73% | 38.37% |
| summer | 22.93% | 22.90% | 22.72% | 24.08% |

The never-sold control remained at 0.0 predicted units for 0.0 actual units; WAPE is undefined when actual demand is zero.

## 28-day transition WAPE

| Group | Existing LGBM | Ablation | Seasonal LGBM | Mean28 |
|---|---:|---:|---:|---:|
| to_dry | 36.16% | 36.06% | 35.97% | 36.06% |
| to_rainy | 29.70% | 29.84% | 29.76% | 30.39% |

## Pre-transition seasonal contribution

- to_dry: 0.19% WAPE-point gain.
- to_rainy: 0.13% WAPE-point gain.

## Historical replay

- Products: SIM-SUM-001, SIM-RAIN-006, SIM-NEU-002, SIM-RAIN-007.
- Period-to-period absolute error improved: 16 comparisons.
- Period-to-period absolute error worsened: 19 comparisons.
- Each next forecast is refit with seven newly revealed sales days. No previous error is subtracted and no residual calibration exists.
- Largest observed replay overprediction: SIM-SUM-001 forecast 125.90, actual 115.00, error +10.90.
- Constructed Hammer arithmetic example: forecast 20, actual 5, overprediction 15. This is explicitly not model output; no next prediction is invented.

## Stage 2.3 reproducibility check

- existing_lightgbm: Stage 2.6 31.92%; Stage 2.3 31.92%; difference -5.596e-18.
- matched_nonseasonal_ablation: Stage 2.6 31.75%; Stage 2.3 31.75%; difference 9.752e-18.
- product_specific_seasonal_lightgbm: Stage 2.6 31.63%; Stage 2.3 31.63%; difference 2.167e-17.

## Recommendation

- Candidate on frozen synthetic history: **ACCEPT**.
- Frontend recommendation: use a forecast-versus-actual timeline with frozen forecast vintages, actuals revealed afterward, signed-error bars, and separate model comparison toggles. Keep synthetic and provisional badges visible.
- Do not connect these artifacts to replenishment or the active model automatically.

## Limitations

- Synthetic results do not establish real Philippine hardware retail effects.
- Frozen SUMMER/RAINY/NEUTRAL labels are supplied context, not independently discovered labels.
- The candidate relearns from appended sales; explicit residual/error calibration is not implemented.
- A later forecast is not guaranteed to improve after every prior error.
- The live export matched the frozen fixture exactly.
