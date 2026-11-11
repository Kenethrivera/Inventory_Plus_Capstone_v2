# Stage 2.9A Forecast Accuracy Diagnostics

**Recommendation: RUN A CONTROLLED IMPROVEMENT EXPERIMENT**

This report is diagnostic only. It does not alter forecasting, training, Supabase, Flutter, or replenishment.

## Frozen Stage 2.6 reproduction

| Model | 28-day daily WAPE |
|---|---:|
| mean28 | 32.88% |
| existing_lightgbm | 31.92% |
| matched_nonseasonal_ablation | 31.75% |
| product_specific_seasonal_lightgbm | 31.63% |

## Ranked product error contributors

The overall rank and contribution share reproduce the mixed-unit Stage 2.6 WAPE diagnostic. They must not be interpreted as interchangeable physical quantities; use the unit and within-unit rank for operational comparisons.

| Overall rank | Unit rank | SKU | Product | Unit | Group | Pattern | Actual | Predicted | Absolute error | Share | WAPE | Bias | vs ablation |
|---:|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 1 | 1 | SIM-SUM-001 | Concrete Hollow Blocks 4-inch | pcs | SUMMER | summer | 7235.0 | 7108.5 | 1038.1 | 8.10% | 14.35% | -1.75% | better |
| 2 | 2 | SIM-SUM-005 | Steel Reinforcing Bar 10mm | pcs | SUMMER | summer | 3552.0 | 3575.3 | 922.6 | 7.20% | 25.97% | 0.66% | worse |
| 3 | 1 | SIM-SUM-002 | Portland Cement 40kg | bag | SUMMER | summer | 5050.0 | 4787.7 | 911.8 | 7.11% | 18.06% | -5.19% | better |
| 4 | 2 | SIM-SUM-007 | Cementitious Tile Adhesive 25kg | bag | SUMMER | summer | 2192.0 | 2167.5 | 703.9 | 5.49% | 32.11% | -1.12% | better |
| 5 | 1 | SIM-NEU-002 | Hex Bolts M8 Box | box | NEUTRAL | neutral | 2919.0 | 2922.4 | 693.7 | 5.41% | 23.77% | 0.12% | better |
| 6 | 3 | SIM-SUM-008 | Masonry Mortar Mix 25kg | bag | SUMMER | summer | 1760.0 | 1835.5 | 678.4 | 5.29% | 38.55% | 4.29% | better |
| 7 | 1 | SIM-NEU-005 | Electrical Insulation Tape | roll | NEUTRAL | neutral | 2276.0 | 2160.5 | 624.1 | 4.87% | 27.42% | -5.07% | worse |
| 8 | 3 | SIM-RAIN-006 | Heavy-Duty Tarpaulin 4x6m | pcs | RAINY | rainy | 1774.0 | 1821.4 | 614.9 | 4.80% | 34.66% | 2.67% | better |
| 9 | 4 | SIM-RAIN-004 | PVC Rain Gutter 3m | pcs | RAINY | rainy | 1251.0 | 1308.0 | 606.5 | 4.73% | 48.48% | 4.56% | better |
| 10 | 2 | SIM-NEU-006 | Wood Screws 2-inch Box | box | NEUTRAL | neutral | 2051.0 | 2036.6 | 565.4 | 4.41% | 27.57% | -0.70% | better |
| 11 | 2 | SIM-RAIN-008 | Roof Leak Repair Tape | roll | RAINY | intermittent | 647.0 | 568.7 | 549.4 | 4.29% | 84.92% | -12.11% | worse |
| 12 | 1 | SIM-SUM-006 | Exterior Masonry Paint 4L | pail | SUMMER | summer | 1290.0 | 1293.8 | 534.8 | 4.17% | 41.46% | 0.29% | better |
| 13 | 5 | SIM-NEU-001 | Combination Pliers 8-inch | pcs | NEUTRAL | neutral | 1234.0 | 1286.4 | 527.3 | 4.11% | 42.73% | 4.25% | worse |
| 14 | 1 | SIM-RAIN-001 | Roof Waterproofing Sealant | tube | RAINY | rainy | 1761.0 | 1685.2 | 518.0 | 4.04% | 29.42% | -4.31% | better |
| 15 | 6 | SIM-NEU-003 | Retractable Utility Knife | pcs | NEUTRAL | neutral | 1484.0 | 1492.9 | 506.3 | 3.95% | 34.12% | 0.60% | better |
| 16 | 1 | SIM-RAIN-003 | Galvanized Roof Flashing | sheet | RAINY | intermittent | 637.0 | 622.6 | 496.2 | 3.87% | 77.89% | -2.26% | better |
| 17 | 1 | SIM-SUM-003 | Washed Construction Sand | cu.m. | SUMMER | intermittent | 710.0 | 719.4 | 452.2 | 3.53% | 63.69% | 1.33% | better |
| 18 | 7 | SIM-RAIN-005 | PVC Gutter Downspout 3m | pcs | RAINY | rainy | 933.0 | 920.4 | 418.1 | 3.26% | 44.81% | -1.35% | better |
| 19 | 2 | SIM-SUM-004 | Construction Gravel 3/4-inch | cu.m. | SUMMER | intermittent | 582.5 | 535.2 | 417.4 | 3.26% | 71.66% | -8.11% | worse |
| 20 | 8 | SIM-NEU-007 | Brass Padlock 40mm | pcs | NEUTRAL | intermittent | 455.0 | 379.0 | 394.9 | 3.08% | 86.78% | -16.70% | better |
| 21 | 3 | SIM-RAIN-002 | Waterproofing Membrane Roll | roll | RAINY | intermittent | 446.0 | 452.2 | 353.4 | 2.76% | 79.25% | 1.40% | worse |
| 22 | 1 | SIM-NEU-004 | HSS Drill Bit Set | set | NEUTRAL | intermittent_low | 237.0 | 12.9 | 238.9 | 1.86% | 100.80% | -94.54% | worse |
| 23 | 9 | SIM-RAIN-007 | Drainage Sump Pump 1HP | pcs | RAINY | intermittent_low | 56.0 | 0.0 | 56.0 | 0.44% | 100.00% | -100.00% | equal |
| 24 | 10 | SIM-NEU-008 | LED Utility Bulb 9W Control | pcs | NEUTRAL | no_sales | 0.0 | 0.0 | 0.0 | 0.00% | n/a | n/a | equal |

## Seasonal groups

| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |
|---|---:|---:|---:|---:|---:|---:|
| NEUTRAL | 4032 | 10656.0 | 10290.8 | 33.32% | -3.43% | 3550.6 |
| RAINY | 4032 | 7505.0 | 7378.4 | 48.14% | -1.69% | 3612.6 |
| SUMMER | 4032 | 22371.5 | 22023.0 | 25.30% | -1.56% | 5659.2 |

## Regular, intermittent and no-sales

| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |
|---|---:|---:|---:|---:|---:|---:|
| intermittent | 4032 | 3770.5 | 3290.1 | 78.46% | -12.74% | 2958.4 |
| no_sales | 504 | 0.0 | 0.0 | n/a | n/a | 0.0 |
| regular | 7560 | 36762.0 | 36402.1 | 26.83% | -0.98% | 9864.0 |

## Actual-volume bands

| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |
|---|---:|---:|---:|---:|---:|---:|
| high | 3024 | 23224.0 | 22722.0 | 21.07% | -2.16% | 4894.1 |
| low | 3024 | 2413.5 | 2002.0 | 81.08% | -17.05% | 1956.8 |
| middle | 5544 | 14895.0 | 14968.2 | 40.09% | 0.49% | 5971.5 |
| no_sales | 504 | 0.0 | 0.0 | n/a | n/a | 0.0 |

## Dry/rainy transitions

| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |
|---|---:|---:|---:|---:|---:|---:|
| none | 9072 | 30085.0 | 29439.1 | 31.74% | -2.15% | 9548.8 |
| to_dry | 912 | 2647.0 | 2625.1 | 35.97% | -0.83% | 952.1 |
| to_rainy | 2112 | 7800.5 | 7628.0 | 29.76% | -2.21% | 2321.5 |

## Zero- versus positive-demand rows

| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |
|---|---:|---:|---:|---:|---:|---:|
| positive_demand | 9249 | 40532.5 | 36881.3 | 24.70% | -9.01% | 10011.5 |
| zero_demand | 2847 | 0.0 | 2810.9 | n/a | n/a | 2810.9 |

## Model comparison by demand segment

| Dimension | Group | Mean28 | Existing LGBM | Ablation | Seasonal LGBM |
|---|---|---:|---:|---:|---:|
| seasonal_group | NEUTRAL | 34.89% | 33.74% | 33.27% | 33.32% |
| seasonal_group | RAINY | 48.95% | 48.43% | 48.35% | 48.14% |
| seasonal_group | SUMMER | 26.54% | 25.51% | 25.45% | 25.30% |
| demand_class | intermittent | 80.55% | 79.25% | 78.25% | 78.46% |
| demand_class | no_sales | n/a | n/a | n/a | n/a |
| demand_class | regular | 27.99% | 27.06% | 26.98% | 26.83% |
| actual_volume_band | high | 22.36% | 21.17% | 21.13% | 21.07% |
| actual_volume_band | low | 85.00% | 82.04% | 80.85% | 81.08% |
| actual_volume_band | middle | 40.85% | 40.54% | 40.35% | 40.09% |
| actual_volume_band | no_sales | n/a | n/a | n/a | n/a |
| seasonal_transition | none | 33.25% | 32.12% | 31.86% | 31.74% |
| seasonal_transition | to_dry | 36.06% | 36.16% | 36.06% | 35.97% |
| seasonal_transition | to_rainy | 30.39% | 29.70% | 29.84% | 29.76% |

## Overforecasting versus underforecasting

| Direction | Observations | Signed error | Absolute error |
|---|---:|---:|---:|
| exact | 1162 | 0.0 | 0.0 |
| overforecast | 5180 | 5991.1 | 5991.1 |
| underforecast | 5754 | -6831.3 | 6831.3 |

## Daily versus decision-horizon accuracy

The published daily WAPE remains unchanged. Horizon-total WAPE first sums each product forecast over one origin and then calculates absolute error, which better matches an order-quantity decision while allowing daily timing errors to cancel.

| Horizon | Model | Quantity-total WAPE | Quantity-total MAE | Bias |
|---:|---|---:|---:|---:|
| 7 | existing_lightgbm | 15.58% | 3.661 | -1.29% |
| 7 | matched_nonseasonal_ablation | 15.52% | 3.647 | -1.56% |
| 7 | mean28 | 16.15% | 3.795 | -0.78% |
| 7 | product_specific_seasonal_lightgbm | 15.39% | 3.615 | -2.12% |
| 28 | existing_lightgbm | 9.67% | 9.072 | -1.08% |
| 28 | matched_nonseasonal_ablation | 9.99% | 9.372 | -1.63% |
| 28 | mean28 | 11.12% | 10.433 | -0.63% |
| 28 | product_specific_seasonal_lightgbm | 9.81% | 9.204 | -2.07% |

## Main findings

- The five largest product contributors account for 33.30% of seasonal-model absolute error.
- Intermittent 28-day daily WAPE is 78.46%, compared with 26.83% for regular products.
- The seasonal candidate improves 15 products and worsens 7 versus the matched ablation.
- Overall seasonal-model bias is -2.07%; the error is mostly absolute dispersion rather than a single global offset.
- Seven-day daily WAPE is 31.20%, while seven-day quantity-total WAPE is 15.39%.
- Twenty-eight-day daily WAPE is 31.63%, while 28-day quantity-total WAPE is 9.81%.
- Stockout effects cannot be measured: the synthetic generator is not availability-censored and the frozen forecast rows have no stockout flags.

## Error-source assessment

- **random_daily_and_weekly_generator_noise (major):** The frozen generator includes weekly noise, daily square-root noise and 1.8% shock days. Horizon-total WAPE is materially below daily WAPE, showing that some day-level timing error cancels over ordering horizons.
- **sparse_and_intermittent_demand (major):** Intermittent products have much higher WAPE than regular products, and the intermittent-low control is strongly underforecast.
- **seasonal_feature_limit (minor_overall):** The seasonal candidate improves only 0.114 WAPE percentage points over its matched nonseasonal ablation, so most remaining error is not removed by the current calendar features.
- **forecast_horizon_and_daily_timing (material_for_decision_support):** Daily WAPE and horizon-total WAPE answer different questions. The total metric is closer to seven- and 28-day stocking decisions but does not replace the frozen daily benchmark.
- **stockout_or_availability_censoring (not_measurable_in_fixture):** The synthetic demand generator is not censored by stock availability and Stage 2.6 points contain no stockout flags. No stockout attribution is defensible from these artifacts.
- **product_specific_model_limitations (mixed):** The seasonal model improves 15 products but worsens 7 versus the matched ablation. An overall gain can therefore hide SKU-level regressions.

## Controlled experiments, not implementations

- Stage 2.6 final-period use: **diagnosis_only**; it is not eligible for experiment selection.
- Select and tune only with chronological training/validation folds, then use a newly reserved and frozen secondary confirmation period for an unbiased acceptance decision.

1. **Intermittent-demand occurrence/size treatment** — expected benefit: high_for_sparse_products; risk: medium. Derive intermittency status only from history available at each origin. Compare a two-stage occurrence-plus-size or established intermittent baseline against the unchanged models on rolling validation origins. Freeze eligibility and parameters there; do not use the already-inspected Stage 2.6 final period for selection. Confirm once on a newly reserved secondary holdout.
2. **Decision-horizon target or loss evaluation** — expected benefit: medium_for_replenishment_horizons; risk: medium. On training/validation only, compare daily forecasts aggregated afterward with models trained for seven- or 28-day totals. Keep daily WAPE as a co-primary guardrail and reject improvements that materially regress products or seasonal groups. Freeze the choice on validation and confirm it only on a new secondary holdout.
3. **Validation-only shrinkage bias calibration** — expected benefit: low_to_medium_if_bias_is_stable; risk: high. Estimate residual bias only from rolling validation residuals, shrink product corrections toward zero, and require stable sign across folds. Do not tune from Stage 2.6 final errors; apply a frozen rule once to a new secondary holdout and report regressions.

## Calibration assessment

- Global calibration justified now: **False**.
- Overall bias is small compared with absolute error and product/group biases have mixed signs. A final-test-derived correction would leak holdout information and could worsen correctly calibrated products.
- Only test shrinkage-based per-product or demand-class calibration if bias direction is stable across rolling training/validation origins; freeze the rule before one untouched final-test evaluation.

## Limitations

- This is a post-hoc diagnostic of a synthetic final test, not new model selection evidence.
- The frozen simulation labels and hidden generator rules are used only to explain the synthetic benchmark.
- Mixed-unit overall totals are diagnostics; operational comparisons must remain within compatible units.
- Synthetic accuracy does not establish real Philippine hardware-store accuracy.
