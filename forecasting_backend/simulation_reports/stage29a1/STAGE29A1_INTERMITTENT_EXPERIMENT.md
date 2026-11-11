# Stage 2.9A-1 Controlled Intermittent-Demand Experiment

**Decision: REVISE**

**Recommendation: KEEP CURRENT MODEL**

This is an isolated synthetic experiment. No production model, Supabase data, Flutter code, or replenishment calculation is changed.

## Independent evaluation contract

- Frozen manifest SHA-256: `bad9c1380d02e657ed228586eb03d092f7fe7f1c89c8e051e006b1b41ca8b4e5`.
- Development seed: 29010101.
- Independent final seed: 29019991.
- Development selection fingerprint: `c473c49798bc073ca5898b5202224d0cef37dc65e543aae2b7fae3bbaf372fc3`.
- Development origins: 20; final origins: 20.
- The Stage 2.6 period and observations were not reused.
- The final realization was generated and evaluated only after candidate configuration, product choices, and strategy were frozen from development results.

## Intermittent products in the independent final realization

| SKU | Product | Class | History days | Sale days | Demand frequency | Zero-sales frequency |
|---|---|---|---:|---:|---:|---:|
| SIM-SUM-003 | Washed Construction Sand | intermittent | 1095 | 621 | 56.71% | 43.29% |
| SIM-SUM-004 | Construction Gravel 3/4-inch | intermittent | 1095 | 871 | 79.54% | 20.46% |
| SIM-SUM-008 | Masonry Mortar Mix 25kg | intermittent | 1095 | 749 | 68.40% | 31.60% |
| SIM-RAIN-002 | Waterproofing Membrane Roll | intermittent_low | 1095 | 497 | 45.39% | 54.61% |
| SIM-RAIN-003 | Galvanized Roof Flashing | intermittent | 1095 | 844 | 77.08% | 22.92% |
| SIM-RAIN-005 | PVC Gutter Downspout 3m | intermittent | 1095 | 847 | 77.35% | 22.65% |
| SIM-RAIN-007 | Drainage Sump Pump 1HP | intermittent_low | 1095 | 94 | 8.58% | 91.42% |
| SIM-RAIN-008 | Roof Leak Repair Tape | intermittent | 1095 | 668 | 61.00% | 39.00% |
| SIM-NEU-004 | HSS Drill Bit Set | intermittent_low | 1095 | 259 | 23.65% | 76.35% |
| SIM-NEU-007 | Brass Padlock 40mm | intermittent_low | 1095 | 492 | 44.93% | 55.07% |

## Development-only selection

- Selected two-stage configuration: **two_stage_conservative**.
- Candidate eligibility guardrails passed: **False**.
- Selected deployment strategy for final confirmation: **universal_two_stage**.
- Product-policy SKUs assigned to two-stage: none.
- No final labels, quantities, errors, or random streams entered these decisions.

## Independent final metrics

| Model | Daily MAE | Daily WAPE | Daily bias | 7-day total WAPE | 28-day total WAPE |
|---|---:|---:|---:|---:|---:|
| mean28 | 1.1721 | 35.91% | -0.78% | 16.40% | 12.40% |
| existing_lightgbm | 1.1355 | 34.79% | -2.01% | 17.27% | 11.51% |
| seasonal_lightgbm | 1.1331 | 34.72% | -1.85% | 16.92% | 11.35% |
| tsb_intermittent_baseline | 1.1792 | 36.13% | -0.76% | 16.87% | 13.21% |
| two_stage_conservative | 1.1410 | 34.96% | -2.00% | 15.65% | 9.47% |
| development_selected_product_policy | 1.1331 | 34.72% | -1.85% | 16.92% | 11.35% |

## Selected strategy versus Seasonal LightGBM

Selected final strategy model: **two_stage_conservative**.

| Comparison | Improvement | 95% CI | Origins |
|---|---:|---:|---:|
| intermittent_daily | -2.14% | [-3.02%, -1.24%] | 20 |
| intermittent_quantity_28_day | 8.22% | [5.94%, 10.44%] | 20 |
| overall_quantity_28_day | 1.88% | [1.31%, 2.41%] | 20 |
| regular_daily | 0.07% | [-0.09%, 0.23%] | 20 |

## Acceptance checks

- development_strategy_guardrails_passed: **FAIL**
- intermittent_daily_positive_ci: **FAIL**
- intermittent_28_day_positive_ci: **PASS**
- overall_28_day_not_worse: **PASS**
- regular_daily_not_worse: **PASS**
- all_seasonal_groups_not_worse: **FAIL**
- never_sold_exact_zero: **PASS**

## Demand-group comparison

| Group | Seasonal daily WAPE | Selected daily WAPE | Seasonal 28-day total WAPE | Selected 28-day total WAPE |
|---|---:|---:|---:|---:|
| intermittent | 69.84% | 70.38% | 19.47% | 16.97% |
| intermittent_low | 104.46% | 114.30% | 60.04% | 24.28% |
| no_sales | n/a | n/a | n/a | n/a |
| regular | 27.94% | 27.87% | 8.86% | 8.02% |

## Seasonal-group regression check

| Group | Seasonal daily WAPE | Selected daily WAPE | Nonregression |
|---|---:|---:|---|
| SUMMER | 29.48% | 29.50% | FAIL |
| RAINY | 50.94% | 51.31% | FAIL |
| NEUTRAL | 34.26% | 34.86% | FAIL |

## Interpretation

The preselected strategy did not pass every frozen independent-final acceptance check. Keep the current operational model; do not integrate this candidate.

## Limitations

- Results are from independently seeded synthetic realizations and do not prove real-store accuracy.
- Frozen seasonal groups are simulation hypotheses, not verified Philippine retail-sales effects.
- Confidence intervals resample forecast origins; with a limited number of origins they remain uncertain.
- Product-policy selection is tied to these product identities and cannot be transferred automatically to new products.
