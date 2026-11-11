# Stage 2.1 Seasonal Data Audit and Expanded Simulation

Status: offline experiment only. No Supabase data, Flutter behavior, active forecast selection, or replenishment logic was changed.

## Recommendation

**REJECT** for seasonal-model integration. `activation_allowed` remains false.

## Original 676-day dataset audit

- Products with an explicit generator month effect: 4 of 13.
- Products crossing the frozen calendar-signal threshold: 7 of 13.
- Knowledge-label direction mismatches: SKU-002, SKU-K1CB7XQV.
- The fixture spans less than two full annual cycles, while the deployed application experiment used only the latest 365 calendar days at each origin.
- Month effects were programmed for reporting variety, not as a balanced SUMMER/RAINY/NEUTRAL experiment.

The fixture contains a few learnable calendar patterns, but it is not a controlled seasonal-class experiment: only four formulas contain explicit month effects, programmed peaks are heterogeneous, and the 365-day model window provides at most one annual cycle.

### Why the original shared seasonal model underperformed

1. The fixture was built for broad transaction testing, not balanced seasonal-class learning; only four formulas had explicit month effects.
2. Programmed peaks and qualitative knowledge labels do not always align; two classified products have an audited direction mismatch.
3. The 365-day model window exposed at most one annual cycle, making stable product-by-season effects hard to separate from trend and noise.
4. Existing per-product LightGBM already has annual sine/cosine features, so pooling needed genuine cross-product signal to add value.
5. Pooling transferred positive demand into dead-stock, intermittent and no-sales products, producing a structural false-positive regression.

### Frozen original benchmark

| Model | WAPE | MAE | Bias |
|---|---:|---:|---:|
| Mean28 | 22.65 | 0.834 | -1.82 |
| Existing per-product LightGBM | 16.93 | 0.623 | -6.55 |
| Shared nonseasonal LightGBM | 19.11 | 0.703 | -9.18 |
| Shared seasonal LightGBM | 19.26 | 0.709 | -8.66 |

Original recommendation: **REJECT**. These results were not overwritten by the expanded experiment.

## Database seasonal-support assessment

No schema change is required. `products` already stores product identity, normal hardware category, description, unit and location. Completed dated sales are represented by `order_history.completed_at` plus complete JSON item snapshots, and `forecast_daily_demand_v1` converts those timestamps into Asia/Manila business dates and aggregates quantity by product and unit.

The deployed RPC accepts periods up to five years. The current application experiment requests 365 days, so a later multi-cycle integration would require a reviewed backend history-window change, not a database column or table.

The experimental SUMMER/RAINY/NEUTRAL labels remain in this versioned offline manifest. They are not written to operational products because they are hypotheses and should be reassessed as knowledge improves.

Live MCP query tools were unavailable during this run; this assessment was checked against the repository's declarative schema and deployed RPC source. The proposed import includes a schema-drift preflight and must not be executed until live metadata is rechecked.

## Expanded dataset contract

- Manifest: `expanded-ph-seasonal-simulation-v1`
- Frozen SHA-256: `f6f5d9773384ea5a468ccdd3d61e0a09800e980a75ee3d711bdc59e3f4b5dc72`
- History: 2022-11-10 through 2026-11-09 (1461 days)
- Training: 2022-11-10 through 2024-11-09
- Validation: 2024-11-10 through 2025-11-09
- Final test: 2025-11-10 through 2026-11-09
- 24 new, nonduplicating proposed products: eight per experimental group.
- The final daily CSV includes zero-demand dates and contains 35,064 rows.
- Models receive at most 1,095 prior calendar days; generator-only amplitudes, random streams, shocks and gates are withheld.

### Signal qualification before model evaluation

- SUMMER: 7 of 8 cross the frozen signal threshold.
- RAINY: 6 of 8 cross the frozen signal threshold.
- NEUTRAL: 0 of 8 cross it, as intended.
- Weak/ambiguous seasonal exceptions and intermittent products are retained; season alone cannot perfectly predict demand.

### Product-list review and evidence boundary

The suggested Phillips screwdriver, adjustable wrench and measuring tape were excluded because those products already exist in the original catalog. They were replaced with wood screws, a padlock and an explicit LED no-sales control. Normal hardware categories remain separate from seasonal groups.

Construction labels inherit only the general PAGASA/PIDS weather-exposed work mechanism. Waterproofing, roof-drainage and temporary-cover labels are provisional use-timing hypotheses. Roof flashing deliberately has nearly offset rainy-repair and dry-installation effects. No reviewed source supplies a Philippine retail-sales percentage for any product.

The manifest retains PAGASA climatology, PIDS rainfall/construction evidence, and the Inventory Plus controlled taxonomy as sources for context and intended use—not for the synthetic amplitudes.

## Final product list and frozen assumptions

| Group | SKU | Product | Unit | Baseline/day | Primary amplitude | Secondary amplitude | Intermittency | Evidence |
|---|---|---|---|---:|---:|---:|---:|---|
| SUMMER | SIM-SUM-001 | Concrete Hollow Blocks 4-inch | pcs | 13.00 | 0.28 | 0.00 | 1.00 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-002 | Portland Cement 40kg | bag | 9.50 | 0.24 | 0.05 | 1.00 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-003 | Washed Construction Sand | cu.m. | 1.80 | 0.38 | 0.00 | 0.78 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-004 | Construction Gravel 3/4-inch | cu.m. | 1.50 | 0.31 | 0.08 | 0.72 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-005 | Steel Reinforcing Bar 10mm | pcs | 6.50 | 0.15 | 0.04 | 0.94 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-006 | Exterior Masonry Paint 4L | pail | 2.40 | 0.42 | 0.00 | 0.88 | simulation_hypothesis_inherited_industry |
| SUMMER | SIM-SUM-007 | Cementitious Tile Adhesive 25kg | bag | 3.80 | 0.16 | 0.07 | 0.94 | provisional_simulation_assumption |
| SUMMER | SIM-SUM-008 | Masonry Mortar Mix 25kg | bag | 4.20 | 0.22 | 0.06 | 0.91 | simulation_hypothesis_inherited_industry |
| RAINY | SIM-RAIN-001 | Roof Waterproofing Sealant | tube | 3.10 | 0.38 | 0.08 | 0.94 | provisional_domain_assumption |
| RAINY | SIM-RAIN-002 | Waterproofing Membrane Roll | roll | 1.30 | 0.42 | 0.10 | 0.68 | provisional_conflicting_mechanisms |
| RAINY | SIM-RAIN-003 | Galvanized Roof Flashing | sheet | 1.70 | 0.18 | 0.15 | 0.68 | provisional_conflicting_mechanisms |
| RAINY | SIM-RAIN-004 | PVC Rain Gutter 3m | pcs | 2.60 | 0.26 | 0.10 | 0.86 | provisional_domain_assumption |
| RAINY | SIM-RAIN-005 | PVC Gutter Downspout 3m | pcs | 2.10 | 0.30 | 0.09 | 0.88 | provisional_domain_assumption |
| RAINY | SIM-RAIN-006 | Heavy-Duty Tarpaulin 4x6m | pcs | 3.70 | 0.45 | 0.05 | 0.92 | provisional_domain_assumption |
| RAINY | SIM-RAIN-007 | Drainage Sump Pump 1HP | pcs | 0.42 | 0.50 | 0.00 | 0.22 | provisional_domain_assumption |
| RAINY | SIM-RAIN-008 | Roof Leak Repair Tape | roll | 1.80 | 0.50 | 0.04 | 0.68 | provisional_domain_assumption |
| NEUTRAL | SIM-NEU-001 | Combination Pliers 8-inch | pcs | 2.50 | 0.00 | 0.00 | 0.90 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-002 | Hex Bolts M8 Box | box | 5.80 | 0.03 | 0.00 | 0.98 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-003 | Retractable Utility Knife | pcs | 3.20 | 0.00 | 0.00 | 0.91 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-004 | HSS Drill Bit Set | set | 0.95 | 0.02 | 0.02 | 0.42 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-005 | Electrical Insulation Tape | roll | 4.40 | 0.00 | 0.00 | 0.97 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-006 | Wood Screws 2-inch Box | box | 3.60 | 0.00 | 0.04 | 0.94 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-007 | Brass Padlock 40mm | pcs | 1.50 | 0.00 | 0.00 | 0.66 | insufficient_for_direction |
| NEUTRAL | SIM-NEU-008 | LED Utility Bulb 9W Control | pcs | 0.00 | 0.00 | 0.00 | 0.00 | no_sales_control |

Amplitudes are generator parameters for this simulation only. They are never passed to the forecasting models and must not be interpreted as real sales percentages.

## Expanded validation-cycle overall results

| Model | MAE | WAPE | Bias |
|---|---:|---:|---:|
| Mean28 | 1.098 | 33.62 | -0.58 |
| Existing per-product LightGBM | 1.069 | 32.72 | -0.54 |
| Shared nonseasonal LightGBM | 1.113 | 34.09 | -5.14 |
| Shared seasonal LightGBM | 1.109 | 33.96 | -4.23 |

## Expanded final-test overall results

| Model | MAE | WAPE | Bias |
|---|---:|---:|---:|
| Mean28 | 1.102 | 32.88 | -0.63 |
| Existing per-product LightGBM | 1.070 | 31.92 | -1.08 |
| Shared nonseasonal LightGBM | 1.121 | 33.46 | -4.46 |
| Shared seasonal LightGBM | 1.114 | 33.25 | -4.49 |

## Final-test results by experimental group

| Group | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| NEUTRAL | Mean28 | 0.922 | 34.89 | -1.48 | 10656.0 | 10498.0 |
| NEUTRAL | Existing per-product LightGBM | 0.892 | 33.74 | -2.08 | 10656.0 | 10434.6 |
| NEUTRAL | Shared nonseasonal LightGBM | 0.933 | 35.30 | -4.47 | 10656.0 | 10179.6 |
| NEUTRAL | Shared seasonal LightGBM | 0.937 | 35.46 | -5.01 | 10656.0 | 10122.0 |
| RAINY | Mean28 | 0.911 | 48.95 | -1.09 | 7505.0 | 7423.0 |
| RAINY | Existing per-product LightGBM | 0.901 | 48.43 | 0.66 | 7505.0 | 7554.2 |
| RAINY | Shared nonseasonal LightGBM | 0.913 | 49.07 | 2.15 | 7505.0 | 7666.4 |
| RAINY | Shared seasonal LightGBM | 0.915 | 49.17 | 1.94 | 7505.0 | 7650.8 |
| SUMMER | Mean28 | 1.472 | 26.54 | -0.06 | 22371.5 | 22357.5 |
| SUMMER | Existing per-product LightGBM | 1.415 | 25.51 | -1.18 | 22371.5 | 22107.1 |
| SUMMER | Shared nonseasonal LightGBM | 1.518 | 27.35 | -6.67 | 22371.5 | 20878.6 |
| SUMMER | Shared seasonal LightGBM | 1.490 | 26.86 | -6.39 | 22371.5 | 20941.1 |

## Final-test results by demand pattern

| Pattern | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| intermittent | Mean28 | 0.873 | 75.94 | -0.43 | 3477.5 | 3462.5 |
| intermittent | Existing per-product LightGBM | 0.887 | 77.10 | -4.72 | 3477.5 | 3313.3 |
| intermittent | Shared nonseasonal LightGBM | 0.870 | 75.62 | 8.78 | 3477.5 | 3782.8 |
| intermittent | Shared seasonal LightGBM | 0.871 | 75.70 | 10.84 | 3477.5 | 3854.6 |
| intermittent_low | Mean28 | 0.393 | 135.32 | -6.48 | 293.0 | 274.0 |
| intermittent_low | Existing per-product LightGBM | 0.305 | 104.76 | -85.37 | 293.0 | 42.9 |
| intermittent_low | Shared nonseasonal LightGBM | 0.401 | 137.85 | -30.07 | 293.0 | 204.9 |
| intermittent_low | Shared seasonal LightGBM | 0.402 | 138.16 | -32.62 | 293.0 | 197.4 |
| neutral | Mean28 | 1.198 | 30.31 | -1.51 | 9964.0 | 9814.0 |
| neutral | Existing per-product LightGBM | 1.169 | 29.56 | 0.41 | 9964.0 | 10004.4 |
| neutral | Shared nonseasonal LightGBM | 1.191 | 30.13 | -5.20 | 9964.0 | 9445.5 |
| neutral | Shared seasonal LightGBM | 1.198 | 30.29 | -5.71 | 9964.0 | 9394.6 |
| no_sales | Mean28 | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Existing per-product LightGBM | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Shared nonseasonal LightGBM | 0.194 | n/a | n/a | 0.0 | 97.9 |
| no_sales | Shared seasonal LightGBM | 0.205 | n/a | n/a | 0.0 | 103.5 |
| rainy | Mean28 | 1.089 | 38.37 | -2.01 | 5719.0 | 5604.0 |
| rainy | Existing per-product LightGBM | 1.077 | 37.96 | 2.64 | 5719.0 | 5870.0 |
| rainy | Shared nonseasonal LightGBM | 1.077 | 37.98 | -0.42 | 5719.0 | 5695.0 |
| rainy | Shared seasonal LightGBM | 1.073 | 37.83 | -1.45 | 5719.0 | 5635.8 |
| summer | Mean28 | 1.679 | 24.08 | 0.21 | 21079.0 | 21124.0 |
| summer | Existing per-product LightGBM | 1.598 | 22.93 | -1.01 | 21079.0 | 20865.2 |
| summer | Shared nonseasonal LightGBM | 1.738 | 24.94 | -7.50 | 21079.0 | 19498.6 |
| summer | Shared seasonal LightGBM | 1.705 | 24.45 | -7.36 | 21079.0 | 19528.0 |

## Final-test results by compatible unit

| Unit | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| bag | Mean28 | 1.575 | 26.46 | 0.43 | 9002.0 | 9041.0 |
| bag | Existing per-product LightGBM | 1.523 | 25.58 | -2.21 | 9002.0 | 8803.0 |
| bag | Shared nonseasonal LightGBM | 1.558 | 26.17 | -5.75 | 9002.0 | 8484.1 |
| bag | Shared seasonal LightGBM | 1.560 | 26.19 | -5.85 | 9002.0 | 8475.5 |
| box | Mean28 | 1.300 | 26.38 | -1.21 | 4970.0 | 4910.0 |
| box | Existing per-product LightGBM | 1.263 | 25.62 | 0.61 | 4970.0 | 5000.5 |
| box | Shared nonseasonal LightGBM | 1.297 | 26.31 | -5.47 | 4970.0 | 4697.9 |
| box | Shared seasonal LightGBM | 1.311 | 26.58 | -5.73 | 4970.0 | 4685.1 |
| cu.m. | Mean28 | 0.853 | 66.55 | -4.56 | 1292.5 | 1233.5 |
| cu.m. | Existing per-product LightGBM | 0.867 | 67.59 | -3.92 | 1292.5 | 1241.8 |
| cu.m. | Shared nonseasonal LightGBM | 0.855 | 66.68 | 6.77 | 1292.5 | 1380.0 |
| cu.m. | Shared seasonal LightGBM | 0.847 | 66.05 | 9.33 | 1292.5 | 1413.1 |
| pail | Mean28 | 1.134 | 44.32 | -1.47 | 1290.0 | 1271.0 |
| pail | Existing per-product LightGBM | 1.082 | 42.28 | 0.28 | 1290.0 | 1293.6 |
| pail | Shared nonseasonal LightGBM | 1.122 | 43.85 | -2.08 | 1290.0 | 1263.1 |
| pail | Shared seasonal LightGBM | 1.113 | 43.48 | -1.38 | 1290.0 | 1272.3 |
| pcs | Mean28 | 1.060 | 29.74 | -0.36 | 17974.0 | 17909.0 |
| pcs | Existing per-product LightGBM | 1.017 | 28.53 | 0.42 | 17974.0 | 18049.5 |
| pcs | Shared nonseasonal LightGBM | 1.120 | 31.41 | -4.71 | 17974.0 | 17127.0 |
| pcs | Shared seasonal LightGBM | 1.102 | 30.90 | -4.82 | 17974.0 | 17107.9 |
| roll | Mean28 | 1.018 | 45.68 | -1.28 | 3369.0 | 3326.0 |
| roll | Existing per-product LightGBM | 1.009 | 45.26 | -2.82 | 3369.0 | 3273.9 |
| roll | Shared nonseasonal LightGBM | 1.015 | 45.55 | 0.40 | 3369.0 | 3382.4 |
| roll | Shared seasonal LightGBM | 1.018 | 45.70 | -0.22 | 3369.0 | 3361.7 |
| set | Mean28 | 0.597 | 126.88 | -5.06 | 237.0 | 225.0 |
| set | Existing per-product LightGBM | 0.498 | 105.88 | -81.91 | 237.0 | 42.9 |
| set | Shared nonseasonal LightGBM | 0.533 | 113.43 | -54.75 | 237.0 | 107.2 |
| set | Shared seasonal LightGBM | 0.527 | 112.04 | -59.88 | 237.0 | 95.1 |
| sheet | Mean28 | 0.978 | 77.42 | 3.30 | 637.0 | 658.0 |
| sheet | Existing per-product LightGBM | 0.996 | 78.84 | 0.38 | 637.0 | 639.4 |
| sheet | Shared nonseasonal LightGBM | 0.967 | 76.53 | -6.67 | 637.0 | 594.5 |
| sheet | Shared seasonal LightGBM | 0.977 | 77.33 | 2.03 | 637.0 | 649.9 |
| tube | Mean28 | 1.043 | 29.85 | -3.18 | 1761.0 | 1705.0 |
| tube | Existing per-product LightGBM | 1.063 | 30.44 | -0.56 | 1761.0 | 1751.2 |
| tube | Shared nonseasonal LightGBM | 1.063 | 30.43 | -4.12 | 1761.0 | 1688.4 |
| tube | Shared seasonal LightGBM | 1.053 | 30.13 | -6.11 | 1761.0 | 1653.4 |

## Final-test seasonal transitions

| Transition | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| to_dry | Mean28 | 1.047 | 36.06 | 0.71 | 2647.0 | 2665.7 |
| to_dry | Existing per-product LightGBM | 1.050 | 36.16 | 1.32 | 2647.0 | 2682.0 |
| to_dry | Shared nonseasonal LightGBM | 1.049 | 36.15 | -0.31 | 2647.0 | 2638.7 |
| to_dry | Shared seasonal LightGBM | 1.055 | 36.34 | -0.99 | 2647.0 | 2620.7 |
| to_rainy | Mean28 | 1.123 | 30.39 | -0.45 | 7800.5 | 7765.5 |
| to_rainy | Existing per-product LightGBM | 1.097 | 29.70 | -0.42 | 7800.5 | 7767.5 |
| to_rainy | Shared nonseasonal LightGBM | 1.168 | 31.62 | -6.24 | 7800.5 | 7313.8 |
| to_rainy | Shared seasonal LightGBM | 1.167 | 31.60 | -5.81 | 7800.5 | 7347.2 |

## Final-test per-product results

| SKU | Model | MAE | WAPE | Bias |
|---|---|---:|---:|---:|
| SIM-NEU-001 | Mean28 | 1.081 | 44.14 | -2.11 |
| SIM-NEU-001 | Existing per-product LightGBM | 1.058 | 43.22 | 4.17 |
| SIM-NEU-001 | Shared nonseasonal LightGBM | 1.084 | 44.29 | -8.84 |
| SIM-NEU-001 | Shared seasonal LightGBM | 1.092 | 44.60 | -11.69 |
| SIM-NEU-002 | Mean28 | 1.420 | 24.51 | -0.00 |
| SIM-NEU-002 | Existing per-product LightGBM | 1.382 | 23.86 | 1.34 |
| SIM-NEU-002 | Shared nonseasonal LightGBM | 1.440 | 24.87 | -5.56 |
| SIM-NEU-002 | Shared seasonal LightGBM | 1.462 | 25.24 | -5.87 |
| SIM-NEU-003 | Mean28 | 1.024 | 34.79 | -0.13 |
| SIM-NEU-003 | Existing per-product LightGBM | 1.030 | 34.97 | 0.35 |
| SIM-NEU-003 | Shared nonseasonal LightGBM | 0.996 | 33.82 | 2.39 |
| SIM-NEU-003 | Shared seasonal LightGBM | 0.995 | 33.80 | 2.48 |
| SIM-NEU-004 | Mean28 | 0.597 | 126.88 | -5.06 |
| SIM-NEU-004 | Existing per-product LightGBM | 0.498 | 105.88 | -81.91 |
| SIM-NEU-004 | Shared nonseasonal LightGBM | 0.533 | 113.43 | -54.75 |
| SIM-NEU-004 | Shared seasonal LightGBM | 0.527 | 112.04 | -59.88 |
| SIM-NEU-005 | Mean28 | 1.286 | 28.48 | -2.72 |
| SIM-NEU-005 | Existing per-product LightGBM | 1.229 | 27.21 | -2.06 |
| SIM-NEU-005 | Shared nonseasonal LightGBM | 1.282 | 28.40 | -7.60 |
| SIM-NEU-005 | Shared seasonal LightGBM | 1.280 | 28.34 | -7.78 |
| SIM-NEU-006 | Mean28 | 1.181 | 29.03 | -2.93 |
| SIM-NEU-006 | Existing per-product LightGBM | 1.145 | 28.13 | -0.42 |
| SIM-NEU-006 | Shared nonseasonal LightGBM | 1.154 | 28.36 | -5.35 |
| SIM-NEU-006 | Shared seasonal LightGBM | 1.160 | 28.50 | -5.54 |
| SIM-NEU-007 | Mean28 | 0.787 | 87.16 | 0.88 |
| SIM-NEU-007 | Existing per-product LightGBM | 0.793 | 87.89 | -14.88 |
| SIM-NEU-007 | Shared nonseasonal LightGBM | 0.779 | 86.25 | 16.26 |
| SIM-NEU-007 | Shared seasonal LightGBM | 0.777 | 86.05 | 16.23 |
| SIM-NEU-008 | Mean28 | 0.000 | n/a | n/a |
| SIM-NEU-008 | Existing per-product LightGBM | 0.000 | n/a | n/a |
| SIM-NEU-008 | Shared nonseasonal LightGBM | 0.194 | n/a | n/a |
| SIM-NEU-008 | Shared seasonal LightGBM | 0.205 | n/a | n/a |
| SIM-RAIN-001 | Mean28 | 1.043 | 29.85 | -3.18 |
| SIM-RAIN-001 | Existing per-product LightGBM | 1.063 | 30.44 | -0.56 |
| SIM-RAIN-001 | Shared nonseasonal LightGBM | 1.063 | 30.43 | -4.12 |
| SIM-RAIN-001 | Shared seasonal LightGBM | 1.053 | 30.13 | -6.11 |
| SIM-RAIN-002 | Mean28 | 0.708 | 80.01 | 3.59 |
| SIM-RAIN-002 | Existing per-product LightGBM | 0.712 | 80.41 | -4.64 |
| SIM-RAIN-002 | Shared nonseasonal LightGBM | 0.691 | 78.07 | 18.58 |
| SIM-RAIN-002 | Shared seasonal LightGBM | 0.695 | 78.54 | 13.05 |
| SIM-RAIN-003 | Mean28 | 0.978 | 77.42 | 3.30 |
| SIM-RAIN-003 | Existing per-product LightGBM | 0.996 | 78.84 | 0.38 |
| SIM-RAIN-003 | Shared nonseasonal LightGBM | 0.967 | 76.53 | -6.67 |
| SIM-RAIN-003 | Shared seasonal LightGBM | 0.977 | 77.33 | 2.03 |
| SIM-RAIN-004 | Mean28 | 1.189 | 47.91 | -1.20 |
| SIM-RAIN-004 | Existing per-product LightGBM | 1.184 | 47.69 | 9.07 |
| SIM-RAIN-004 | Shared nonseasonal LightGBM | 1.168 | 47.05 | 1.50 |
| SIM-RAIN-004 | Shared seasonal LightGBM | 1.171 | 47.19 | 1.37 |
| SIM-RAIN-005 | Mean28 | 0.850 | 45.94 | -3.32 |
| SIM-RAIN-005 | Existing per-product LightGBM | 0.830 | 44.86 | -1.86 |
| SIM-RAIN-005 | Shared nonseasonal LightGBM | 0.829 | 44.77 | 5.67 |
| SIM-RAIN-005 | Shared seasonal LightGBM | 0.826 | 44.64 | 5.05 |
| SIM-RAIN-006 | Mean28 | 1.271 | 36.12 | -0.73 |
| SIM-RAIN-006 | Existing per-product LightGBM | 1.230 | 34.94 | 3.65 |
| SIM-RAIN-006 | Shared nonseasonal LightGBM | 1.250 | 35.51 | -1.31 |
| SIM-RAIN-006 | Shared seasonal LightGBM | 1.242 | 35.30 | -2.25 |
| SIM-RAIN-007 | Mean28 | 0.190 | 171.05 | -12.50 |
| SIM-RAIN-007 | Existing per-product LightGBM | 0.111 | 100.00 | -100.00 |
| SIM-RAIN-007 | Shared nonseasonal LightGBM | 0.268 | 241.22 | 74.39 |
| SIM-RAIN-007 | Shared seasonal LightGBM | 0.276 | 248.66 | 82.76 |
| SIM-RAIN-008 | Mean28 | 1.059 | 82.51 | 0.46 |
| SIM-RAIN-008 | Existing per-product LightGBM | 1.085 | 84.53 | -4.26 |
| SIM-RAIN-008 | Shared nonseasonal LightGBM | 1.071 | 83.45 | 15.98 |
| SIM-RAIN-008 | Shared seasonal LightGBM | 1.080 | 84.13 | 17.23 |
| SIM-SUM-001 | Mean28 | 2.294 | 15.98 | 0.88 |
| SIM-SUM-001 | Existing per-product LightGBM | 2.088 | 14.55 | -0.92 |
| SIM-SUM-001 | Shared nonseasonal LightGBM | 2.699 | 18.80 | -11.66 |
| SIM-SUM-001 | Shared seasonal LightGBM | 2.479 | 17.27 | -11.15 |
| SIM-SUM-002 | Mean28 | 1.939 | 19.36 | 1.33 |
| SIM-SUM-002 | Existing per-product LightGBM | 1.808 | 18.05 | -4.57 |
| SIM-SUM-002 | Shared nonseasonal LightGBM | 1.883 | 18.79 | -7.83 |
| SIM-SUM-002 | Shared seasonal LightGBM | 1.885 | 18.82 | -8.26 |
| SIM-SUM-003 | Mean28 | 0.896 | 63.64 | -3.94 |
| SIM-SUM-003 | Existing per-product LightGBM | 0.915 | 64.95 | 0.06 |
| SIM-SUM-003 | Shared nonseasonal LightGBM | 0.888 | 63.05 | 8.75 |
| SIM-SUM-003 | Shared seasonal LightGBM | 0.877 | 62.23 | 10.13 |
| SIM-SUM-004 | Mean28 | 0.810 | 70.11 | -5.32 |
| SIM-SUM-004 | Existing per-product LightGBM | 0.818 | 70.81 | -8.77 |
| SIM-SUM-004 | Shared nonseasonal LightGBM | 0.822 | 71.09 | 4.36 |
| SIM-SUM-004 | Shared seasonal LightGBM | 0.817 | 70.72 | 8.36 |
| SIM-SUM-005 | Mean28 | 1.917 | 27.20 | -1.10 |
| SIM-SUM-005 | Existing per-product LightGBM | 1.850 | 26.25 | 1.35 |
| SIM-SUM-005 | Shared nonseasonal LightGBM | 1.935 | 27.46 | -5.40 |
| SIM-SUM-005 | Shared seasonal LightGBM | 1.956 | 27.76 | -5.62 |
| SIM-SUM-006 | Mean28 | 1.134 | 44.32 | -1.47 |
| SIM-SUM-006 | Existing per-product LightGBM | 1.082 | 42.28 | 0.28 |
| SIM-SUM-006 | Shared nonseasonal LightGBM | 1.122 | 43.85 | -2.08 |
| SIM-SUM-006 | Shared seasonal LightGBM | 1.113 | 43.48 | -1.38 |
| SIM-SUM-007 | Mean28 | 1.446 | 33.25 | -2.37 |
| SIM-SUM-007 | Existing per-product LightGBM | 1.400 | 32.19 | -0.84 |
| SIM-SUM-007 | Shared nonseasonal LightGBM | 1.456 | 33.48 | -6.85 |
| SIM-SUM-007 | Shared seasonal LightGBM | 1.448 | 33.30 | -6.16 |
| SIM-SUM-008 | Mean28 | 1.341 | 38.40 | 1.36 |
| SIM-SUM-008 | Existing per-product LightGBM | 1.360 | 38.95 | 2.84 |
| SIM-SUM-008 | Shared nonseasonal LightGBM | 1.335 | 38.24 | 1.57 |
| SIM-SUM-008 | Shared seasonal LightGBM | 1.345 | 38.52 | 1.45 |

## Pre-transition forecast examples

The JSON artifact contains every daily actual and prediction for these cases.

| Origin | Product | Group | Recent 28 actual | Target actual | Mean28 | Existing LGBM | Shared ablation | Shared seasonal | Seasonal - ablation |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 2026-02-15 | Roof Waterproofing Sealant | RAINY | 73.0 | 73.0 | 73.0 | 79.9 | 62.8 | 63.0 | 0.2 |
| 2026-04-30 | Heavy-Duty Tarpaulin 4x6m | RAINY | 79.0 | 94.0 | 79.0 | 96.7 | 84.2 | 85.9 | 1.7 |
| 2026-10-12 | Exterior Masonry Paint 4L | SUMMER | 38.0 | 48.0 | 38.0 | 42.1 | 43.2 | 42.8 | -0.4 |
| 2026-04-30 | Combination Pliers 8-inch | NEUTRAL | 62.0 | 75.0 | 62.0 | 74.7 | 61.3 | 62.1 | 0.8 |

### Daily predicted-versus-actual samples

The first seven target days from each example are shown below; all 28 days and every model are retained in JSON.

| Origin | SKU | Date | Actual | Shared seasonal prediction |
|---|---|---|---:|---:|
| 2026-02-15 | SIM-RAIN-001 | 2026-02-16 | 3.00 | 2.32 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-17 | 2.00 | 2.31 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-18 | 1.00 | 2.30 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-19 | 3.00 | 2.30 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-20 | 2.00 | 2.30 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-21 | 2.00 | 2.58 |
| 2026-02-15 | SIM-RAIN-001 | 2026-02-22 | 2.00 | 2.57 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-01 | 3.00 | 3.11 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-02 | 3.00 | 3.23 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-03 | 4.00 | 3.18 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-04 | 1.00 | 3.10 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-05 | 4.00 | 3.10 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-06 | 3.00 | 3.10 |
| 2026-04-30 | SIM-RAIN-006 | 2026-05-07 | 4.00 | 3.07 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-13 | 1.00 | 1.49 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-14 | 2.00 | 1.46 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-15 | 0.00 | 1.49 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-16 | 2.00 | 1.46 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-17 | 2.00 | 1.49 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-18 | 2.00 | 1.51 |
| 2026-10-12 | SIM-SUM-006 | 2026-10-19 | 2.00 | 1.51 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-01 | 2.00 | 2.23 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-02 | 1.00 | 2.24 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-03 | 2.00 | 2.26 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-04 | 2.00 | 2.25 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-05 | 0.00 | 2.24 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-06 | 5.00 | 2.21 |
| 2026-04-30 | SIM-NEU-001 | 2026-05-07 | 3.00 | 2.24 |

## Acceptance checks

- Overall WAPE gain versus ablation: 0.21 percentage points.
- SUMMER and RAINY groups both improve: False.
- Both calendar transitions improve: False.
- Neutral regression within one percentage point: True.
- No-sales false-positive guard passed: False.

## Supabase import assessment

Import is **not recommended yet**. A guarded proposal SQL file is supplied for review, but it defaults to refusing execution. It uses new products and deterministic tagged orders, builds item snapshots, and creates a monthly receipt/daily checkout ledger that ends at each product's catalog quantity. Rollback targets only the tagged batch and new product IDs.

Before any later manual import, create a Supabase branch or downloadable database backup and export the target location's products, orders, order_history and transaction_history. The proposal is additive and its rollback is batch-tagged, but a platform backup remains the recovery boundary for trigger or schema drift.

No seasonal-label column or new table is proposed. The labels remain an offline research manifest, preventing provisional assumptions from becoming permanent operational truth.

## Evidence boundary and limitations

- SUMMER, RAINY and NEUTRAL are frozen simulation hypotheses, not observed Philippine retail effects.
- PAGASA climatology supplies future-known dates, not actual or forecast rainfall observations.
- PIDS evidence supports a general outdoor-work mechanism, not any product coefficient.
- The same deterministic generator cannot substitute for evaluation on independent real stores.
- Compatible-unit and product-level results are decision-safe; mixed-unit totals are diagnostic only.
- Product intended uses come from the controlled Inventory Plus taxonomy and the manifest descriptions. Seasonal magnitudes remain synthetic.
- The generator uses no invented weather observations or future weather data.
