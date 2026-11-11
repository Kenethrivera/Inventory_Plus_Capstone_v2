# Stage 2.3 Product-Specific Seasonal LightGBM

Status: offline experiment only. Production forecasting remains unchanged.

## Recommendation

**ACCEPT**. The candidate passed every acceptance check.

Validation selected **1095 days** with the **conservative** hyperparameter set. Final-test labels were not accessed until that choice was frozen.

- Final WAPE contribution from seasonal features: 0.11 pp.
- Final WAPE gain versus existing LightGBM: 0.28 pp.
- Never-sold false-positive check: True.

## Experiment contract

- Population: 24 expanded offline products; original operational products are excluded.
- Validation: 2024-11-10 through 2025-11-09.
- Untouched final test: 2025-11-10 through 2026-11-09.
- Each LightGBM is trained from one product's sales history only.
- The ablation calls the production LightGBM feature function directly.
- Added inputs are target-date PAGASA calendar context, transition state, month, transition proximity, and product-knowledge alignment indicators.
- These values are features, not demand multipliers; every numerical effect is learned from historical targets.

## Validation-only model and history selection

| Window | Hyperparameters | Seasonal WAPE | Ablation gain | Existing-LGBM gain | Neutral gain | Eligible |
|---:|---|---:|---:|---:|---:|---|
| 365 | production_parity | 33.49% | 0.18 pp | 0.18 pp | 0.01 pp | True |
| 365 | conservative | 33.43% | 0.14 pp | 0.24 pp | -0.12 pp | True |
| 730 | production_parity | 32.92% | 0.13 pp | 0.13 pp | -0.04 pp | True |
| 730 | conservative | 32.76% | -0.01 pp | 0.29 pp | -0.16 pp | True |
| 1095 | production_parity | 32.62% | 0.11 pp | 0.11 pp | 0.33 pp | True |
| 1095 | conservative | 32.48% | 0.01 pp | 0.25 pp | 0.18 pp | True |

Observed training lengths were not padded. The 1,095-day setting uses only 731-1,068 available days across validation origins.

## Final-test overall accuracy

| Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---:|---:|---:|---:|---:|
| Existing product-specific LightGBM | 1.070 | 31.92% | -1.08% | 40532.5 | 40095.8 |
| Nonseasonal ablation (conservative) | 1.064 | 31.75% | -1.63% | 40532.5 | 39870.3 |
| Product seasonal (conservative) | 1.060 | 31.63% | -2.07% | 40532.5 | 39692.2 |

Mixed-unit totals above are diagnostic. Product and compatible-unit results below are the decision-safe comparisons.

## Product-level outcome summary

| Baseline | Comparable | Improved | Regressed | Tied |
|---|---:|---:|---:|---:|
| Existing product-specific LightGBM | 23 | 17 | 5 | 1 |
| Nonseasonal ablation (conservative) | 23 | 15 | 7 | 1 |

Largest WAPE regressions versus each baseline are retained below. A negative gain means the seasonal candidate was worse.

| Baseline | SKU | Seasonal WAPE | Baseline WAPE | Gain |
|---|---|---:|---:|---:|
| Existing product-specific LightGBM | SIM-SUM-004 | 71.66% | 70.81% | -0.85 pp |
| Existing product-specific LightGBM | SIM-RAIN-004 | 48.48% | 47.69% | -0.79 pp |
| Existing product-specific LightGBM | SIM-RAIN-008 | 84.92% | 84.53% | -0.39 pp |
| Existing product-specific LightGBM | SIM-NEU-005 | 27.42% | 27.21% | -0.21 pp |
| Existing product-specific LightGBM | SIM-SUM-002 | 18.06% | 18.05% | -0.01 pp |
| Nonseasonal ablation (conservative) | SIM-RAIN-002 | 79.25% | 77.96% | -1.29 pp |
| Nonseasonal ablation (conservative) | SIM-SUM-004 | 71.66% | 70.64% | -1.02 pp |
| Nonseasonal ablation (conservative) | SIM-RAIN-008 | 84.92% | 84.17% | -0.75 pp |
| Nonseasonal ablation (conservative) | SIM-NEU-005 | 27.42% | 27.14% | -0.28 pp |
| Nonseasonal ablation (conservative) | SIM-SUM-005 | 25.97% | 25.79% | -0.19 pp |

## Final-test results by seasonal group

| Group | Model | MAE | WAPE | Bias |
|---|---|---:|---:|---:|
| SUMMER | Existing product-specific LightGBM | 1.415 | 25.51% | -1.18% |
| SUMMER | Nonseasonal ablation (conservative) | 1.412 | 25.45% | -1.58% |
| SUMMER | Product seasonal (conservative) | 1.404 | 25.30% | -1.56% |
| RAINY | Existing product-specific LightGBM | 0.901 | 48.43% | 0.66% |
| RAINY | Nonseasonal ablation (conservative) | 0.900 | 48.35% | -0.71% |
| RAINY | Product seasonal (conservative) | 0.896 | 48.14% | -1.69% |
| NEUTRAL | Existing product-specific LightGBM | 0.892 | 33.74% | -2.08% |
| NEUTRAL | Nonseasonal ablation (conservative) | 0.879 | 33.27% | -2.39% |
| NEUTRAL | Product seasonal (conservative) | 0.881 | 33.32% | -3.43% |

## Final-test results by compatible inventory unit

| Unit | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| bag | Existing product-specific LightGBM | 1.523 | 25.58% | -2.21% | 9002.0 | 8803.0 |
| bag | Nonseasonal ablation (conservative) | 1.528 | 25.66% | -2.59% | 9002.0 | 8768.7 |
| bag | Product seasonal (conservative) | 1.517 | 25.48% | -2.35% | 9002.0 | 8790.7 |
| box | Existing product-specific LightGBM | 1.263 | 25.62% | 0.61% | 4970.0 | 5000.5 |
| box | Nonseasonal ablation (conservative) | 1.250 | 25.36% | 0.81% | 4970.0 | 5010.1 |
| box | Product seasonal (conservative) | 1.249 | 25.34% | -0.22% | 4970.0 | 4959.0 |
| cu.m. | Existing product-specific LightGBM | 0.867 | 67.59% | -3.92% | 1292.5 | 1241.8 |
| cu.m. | Nonseasonal ablation (conservative) | 0.859 | 67.02% | -2.38% | 1292.5 | 1261.8 |
| cu.m. | Product seasonal (conservative) | 0.863 | 67.28% | -2.93% | 1292.5 | 1254.7 |
| pail | Existing product-specific LightGBM | 1.082 | 42.28% | 0.28% | 1290.0 | 1293.6 |
| pail | Nonseasonal ablation (conservative) | 1.092 | 42.65% | -0.76% | 1290.0 | 1280.2 |
| pail | Product seasonal (conservative) | 1.061 | 41.46% | 0.29% | 1290.0 | 1293.8 |
| pcs | Existing product-specific LightGBM | 1.017 | 28.53% | 0.42% | 17974.0 | 18049.5 |
| pcs | Nonseasonal ablation (conservative) | 1.014 | 28.42% | -0.04% | 17974.0 | 17966.1 |
| pcs | Product seasonal (conservative) | 1.009 | 28.29% | -0.46% | 17974.0 | 17892.0 |
| roll | Existing product-specific LightGBM | 1.009 | 45.26% | -2.82% | 3369.0 | 3273.9 |
| roll | Nonseasonal ablation (conservative) | 0.999 | 44.82% | -3.28% | 3369.0 | 3258.4 |
| roll | Product seasonal (conservative) | 1.010 | 45.32% | -5.57% | 3369.0 | 3181.4 |
| set | Existing product-specific LightGBM | 0.498 | 105.88% | -81.91% | 237.0 | 42.9 |
| set | Nonseasonal ablation (conservative) | 0.474 | 100.70% | -97.58% | 237.0 | 5.7 |
| set | Product seasonal (conservative) | 0.474 | 100.80% | -94.54% | 237.0 | 12.9 |
| sheet | Existing product-specific LightGBM | 0.996 | 78.84% | 0.38% | 637.0 | 639.4 |
| sheet | Nonseasonal ablation (conservative) | 0.997 | 78.87% | -2.48% | 637.0 | 621.2 |
| sheet | Product seasonal (conservative) | 0.984 | 77.89% | -2.26% | 637.0 | 622.6 |
| tube | Existing product-specific LightGBM | 1.063 | 30.44% | -0.56% | 1761.0 | 1751.2 |
| tube | Nonseasonal ablation (conservative) | 1.036 | 29.64% | -3.57% | 1761.0 | 1698.2 |
| tube | Product seasonal (conservative) | 1.028 | 29.42% | -4.31% | 1761.0 | 1685.2 |

## Final-test results by demand pattern

| Pattern | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| intermittent | Existing product-specific LightGBM | 0.887 | 77.10% | -4.72% | 3477.5 | 3313.3 |
| intermittent | Nonseasonal ablation (conservative) | 0.878 | 76.38% | -4.86% | 3477.5 | 3308.4 |
| intermittent | Product seasonal (conservative) | 0.881 | 76.59% | -5.76% | 3477.5 | 3277.2 |
| intermittent_low | Existing product-specific LightGBM | 0.305 | 104.76% | -85.37% | 293.0 | 42.9 |
| intermittent_low | Nonseasonal ablation (conservative) | 0.292 | 100.56% | -98.04% | 293.0 | 5.7 |
| intermittent_low | Product seasonal (conservative) | 0.293 | 100.65% | -95.58% | 293.0 | 12.9 |
| neutral | Existing product-specific LightGBM | 1.169 | 29.56% | 0.41% | 9964.0 | 10004.4 |
| neutral | Nonseasonal ablation (conservative) | 1.156 | 29.23% | 0.63% | 9964.0 | 10026.9 |
| neutral | Product seasonal (conservative) | 1.157 | 29.27% | -0.65% | 9964.0 | 9898.8 |
| no_sales | Existing product-specific LightGBM | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Nonseasonal ablation (conservative) | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Product seasonal (conservative) | 0.000 | n/a | n/a | 0.0 | 0.0 |
| rainy | Existing product-specific LightGBM | 1.077 | 37.96% | 2.64% | 5719.0 | 5870.0 |
| rainy | Nonseasonal ablation (conservative) | 1.080 | 38.09% | 0.96% | 5719.0 | 5773.6 |
| rainy | Product seasonal (conservative) | 1.070 | 37.73% | 0.28% | 5719.0 | 5734.9 |
| summer | Existing product-specific LightGBM | 1.598 | 22.93% | -1.01% | 21079.0 | 20865.2 |
| summer | Nonseasonal ablation (conservative) | 1.596 | 22.90% | -1.53% | 21079.0 | 20755.6 |
| summer | Product seasonal (conservative) | 1.584 | 22.72% | -1.47% | 21079.0 | 20768.3 |

## All final-test seasonal-transition targets

| Transition | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| to_dry | Existing product-specific LightGBM | 1.050 | 36.16% | 1.32% | 2647.0 | 2682.0 |
| to_dry | Nonseasonal ablation (conservative) | 1.047 | 36.06% | 1.29% | 2647.0 | 2681.2 |
| to_dry | Product seasonal (conservative) | 1.044 | 35.97% | -0.83% | 2647.0 | 2625.1 |
| to_rainy | Existing product-specific LightGBM | 1.097 | 29.70% | -0.42% | 7800.5 | 7767.5 |
| to_rainy | Nonseasonal ablation (conservative) | 1.102 | 29.84% | -1.83% | 7800.5 | 7657.7 |
| to_rainy | Product seasonal (conservative) | 1.099 | 29.76% | -2.21% | 7800.5 | 7628.0 |

## Pre-transition anticipation targets

| Upcoming transition | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| to_dry | Existing product-specific LightGBM | 1.067 | 35.54% | 0.38% | 1224.5 | 1229.1 |
| to_dry | Nonseasonal ablation (conservative) | 1.073 | 35.74% | -0.14% | 1224.5 | 1222.8 |
| to_dry | Product seasonal (conservative) | 1.067 | 35.55% | -3.21% | 1224.5 | 1185.2 |
| to_rainy | Existing product-specific LightGBM | 1.106 | 29.75% | -0.90% | 5800.0 | 5748.1 |
| to_rainy | Nonseasonal ablation (conservative) | 1.115 | 29.98% | -2.36% | 5800.0 | 5663.1 |
| to_rainy | Product seasonal (conservative) | 1.110 | 29.85% | -2.61% | 5800.0 | 5648.8 |

The pre-transition table includes only forecasts issued in April for May transition dates and in October for November transition dates. It therefore tests target-date anticipation before transition-period sales enter recent lags.

## Final-test per-product accuracy

| SKU | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| SIM-NEU-001 | Existing product-specific LightGBM | 1.058 | 43.22% | 4.17% | 1234.0 | 1285.4 |
| SIM-NEU-001 | Nonseasonal ablation (conservative) | 1.044 | 42.63% | 6.26% | 1234.0 | 1311.3 |
| SIM-NEU-001 | Product seasonal (conservative) | 1.046 | 42.73% | 4.25% | 1234.0 | 1286.4 |
| SIM-NEU-002 | Existing product-specific LightGBM | 1.382 | 23.86% | 1.34% | 2919.0 | 2958.1 |
| SIM-NEU-002 | Nonseasonal ablation (conservative) | 1.377 | 23.77% | 1.31% | 2919.0 | 2957.3 |
| SIM-NEU-002 | Product seasonal (conservative) | 1.376 | 23.77% | 0.12% | 2919.0 | 2922.4 |
| SIM-NEU-003 | Existing product-specific LightGBM | 1.030 | 34.97% | 0.35% | 1484.0 | 1489.3 |
| SIM-NEU-003 | Nonseasonal ablation (conservative) | 1.008 | 34.22% | 1.37% | 1484.0 | 1504.4 |
| SIM-NEU-003 | Product seasonal (conservative) | 1.005 | 34.12% | 0.60% | 1484.0 | 1492.9 |
| SIM-NEU-004 | Existing product-specific LightGBM | 0.498 | 105.88% | -81.91% | 237.0 | 42.9 |
| SIM-NEU-004 | Nonseasonal ablation (conservative) | 0.474 | 100.70% | -97.58% | 237.0 | 5.7 |
| SIM-NEU-004 | Product seasonal (conservative) | 0.474 | 100.80% | -94.54% | 237.0 | 12.9 |
| SIM-NEU-005 | Existing product-specific LightGBM | 1.229 | 27.21% | -2.06% | 2276.0 | 2229.2 |
| SIM-NEU-005 | Nonseasonal ablation (conservative) | 1.225 | 27.14% | -3.29% | 2276.0 | 2201.2 |
| SIM-NEU-005 | Product seasonal (conservative) | 1.238 | 27.42% | -5.07% | 2276.0 | 2160.5 |
| SIM-NEU-006 | Existing product-specific LightGBM | 1.145 | 28.13% | -0.42% | 2051.0 | 2042.4 |
| SIM-NEU-006 | Nonseasonal ablation (conservative) | 1.124 | 27.63% | 0.09% | 2051.0 | 2052.8 |
| SIM-NEU-006 | Product seasonal (conservative) | 1.122 | 27.57% | -0.70% | 2051.0 | 2036.6 |
| SIM-NEU-007 | Existing product-specific LightGBM | 0.793 | 87.89% | -14.88% | 455.0 | 387.3 |
| SIM-NEU-007 | Nonseasonal ablation (conservative) | 0.784 | 86.81% | -19.07% | 455.0 | 368.2 |
| SIM-NEU-007 | Product seasonal (conservative) | 0.783 | 86.78% | -16.70% | 455.0 | 379.0 |
| SIM-NEU-008 | Existing product-specific LightGBM | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-NEU-008 | Nonseasonal ablation (conservative) | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-NEU-008 | Product seasonal (conservative) | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-RAIN-001 | Existing product-specific LightGBM | 1.063 | 30.44% | -0.56% | 1761.0 | 1751.2 |
| SIM-RAIN-001 | Nonseasonal ablation (conservative) | 1.036 | 29.64% | -3.57% | 1761.0 | 1698.2 |
| SIM-RAIN-001 | Product seasonal (conservative) | 1.028 | 29.42% | -4.31% | 1761.0 | 1685.2 |
| SIM-RAIN-002 | Existing product-specific LightGBM | 0.712 | 80.41% | -4.64% | 446.0 | 425.3 |
| SIM-RAIN-002 | Nonseasonal ablation (conservative) | 0.690 | 77.96% | 2.14% | 446.0 | 455.6 |
| SIM-RAIN-002 | Product seasonal (conservative) | 0.701 | 79.25% | 1.40% | 446.0 | 452.2 |
| SIM-RAIN-003 | Existing product-specific LightGBM | 0.996 | 78.84% | 0.38% | 637.0 | 639.4 |
| SIM-RAIN-003 | Nonseasonal ablation (conservative) | 0.997 | 78.87% | -2.48% | 637.0 | 621.2 |
| SIM-RAIN-003 | Product seasonal (conservative) | 0.984 | 77.89% | -2.26% | 637.0 | 622.6 |
| SIM-RAIN-004 | Existing product-specific LightGBM | 1.184 | 47.69% | 9.07% | 1251.0 | 1364.5 |
| SIM-RAIN-004 | Nonseasonal ablation (conservative) | 1.214 | 48.92% | 4.52% | 1251.0 | 1307.5 |
| SIM-RAIN-004 | Product seasonal (conservative) | 1.203 | 48.48% | 4.56% | 1251.0 | 1308.0 |
| SIM-RAIN-005 | Existing product-specific LightGBM | 0.830 | 44.86% | -1.86% | 933.0 | 915.6 |
| SIM-RAIN-005 | Nonseasonal ablation (conservative) | 0.838 | 45.26% | 1.96% | 933.0 | 951.3 |
| SIM-RAIN-005 | Product seasonal (conservative) | 0.830 | 44.81% | -1.35% | 933.0 | 920.4 |
| SIM-RAIN-006 | Existing product-specific LightGBM | 1.230 | 34.94% | 3.65% | 1774.0 | 1838.7 |
| SIM-RAIN-006 | Nonseasonal ablation (conservative) | 1.234 | 35.06% | 2.41% | 1774.0 | 1816.7 |
| SIM-RAIN-006 | Product seasonal (conservative) | 1.220 | 34.66% | 2.67% | 1774.0 | 1821.4 |
| SIM-RAIN-007 | Existing product-specific LightGBM | 0.111 | 100.00% | -100.00% | 56.0 | 0.0 |
| SIM-RAIN-007 | Nonseasonal ablation (conservative) | 0.111 | 100.00% | -100.00% | 56.0 | 0.0 |
| SIM-RAIN-007 | Product seasonal (conservative) | 0.111 | 100.00% | -100.00% | 56.0 | 0.0 |
| SIM-RAIN-008 | Existing product-specific LightGBM | 1.085 | 84.53% | -4.26% | 647.0 | 619.4 |
| SIM-RAIN-008 | Nonseasonal ablation (conservative) | 1.081 | 84.17% | -7.01% | 647.0 | 601.6 |
| SIM-RAIN-008 | Product seasonal (conservative) | 1.090 | 84.92% | -12.11% | 647.0 | 568.7 |
| SIM-SUM-001 | Existing product-specific LightGBM | 2.088 | 14.55% | -0.92% | 7235.0 | 7168.7 |
| SIM-SUM-001 | Nonseasonal ablation (conservative) | 2.086 | 14.53% | -1.54% | 7235.0 | 7123.9 |
| SIM-SUM-001 | Product seasonal (conservative) | 2.060 | 14.35% | -1.75% | 7235.0 | 7108.5 |
| SIM-SUM-002 | Existing product-specific LightGBM | 1.808 | 18.05% | -4.57% | 5050.0 | 4819.5 |
| SIM-SUM-002 | Nonseasonal ablation (conservative) | 1.813 | 18.10% | -5.15% | 5050.0 | 4789.9 |
| SIM-SUM-002 | Product seasonal (conservative) | 1.809 | 18.06% | -5.19% | 5050.0 | 4787.7 |
| SIM-SUM-003 | Existing product-specific LightGBM | 0.915 | 64.95% | 0.06% | 710.0 | 710.4 |
| SIM-SUM-003 | Nonseasonal ablation (conservative) | 0.902 | 64.06% | 1.93% | 710.0 | 723.7 |
| SIM-SUM-003 | Product seasonal (conservative) | 0.897 | 63.69% | 1.33% | 710.0 | 719.4 |
| SIM-SUM-004 | Existing product-specific LightGBM | 0.818 | 70.81% | -8.77% | 582.5 | 531.4 |
| SIM-SUM-004 | Nonseasonal ablation (conservative) | 0.816 | 70.64% | -7.62% | 582.5 | 538.1 |
| SIM-SUM-004 | Product seasonal (conservative) | 0.828 | 71.66% | -8.11% | 582.5 | 535.2 |
| SIM-SUM-005 | Existing product-specific LightGBM | 1.850 | 26.25% | 1.35% | 3552.0 | 3600.0 |
| SIM-SUM-005 | Nonseasonal ablation (conservative) | 1.817 | 25.79% | 0.87% | 3552.0 | 3582.8 |
| SIM-SUM-005 | Product seasonal (conservative) | 1.830 | 25.97% | 0.66% | 3552.0 | 3575.3 |
| SIM-SUM-006 | Existing product-specific LightGBM | 1.082 | 42.28% | 0.28% | 1290.0 | 1293.6 |
| SIM-SUM-006 | Nonseasonal ablation (conservative) | 1.092 | 42.65% | -0.76% | 1290.0 | 1280.2 |
| SIM-SUM-006 | Product seasonal (conservative) | 1.061 | 41.46% | 0.29% | 1290.0 | 1293.8 |
| SIM-SUM-007 | Existing product-specific LightGBM | 1.400 | 32.19% | -0.84% | 2192.0 | 2173.6 |
| SIM-SUM-007 | Nonseasonal ablation (conservative) | 1.416 | 32.56% | -1.22% | 2192.0 | 2165.3 |
| SIM-SUM-007 | Product seasonal (conservative) | 1.397 | 32.11% | -1.12% | 2192.0 | 2167.5 |
| SIM-SUM-008 | Existing product-specific LightGBM | 1.360 | 38.95% | 2.84% | 1760.0 | 1810.0 |
| SIM-SUM-008 | Nonseasonal ablation (conservative) | 1.354 | 38.78% | 3.04% | 1760.0 | 1813.5 |
| SIM-SUM-008 | Product seasonal (conservative) | 1.346 | 38.55% | 4.29% | 1760.0 | 1835.5 |

The no-sales control has undefined WAPE; zero MAE and zero predicted total are its acceptance criteria. Intermittent products are evaluated normally.

## Transition examples

| Origin | SKU | Group | Recent actual | Target actual | Existing | Ablation | Seasonal | Seasonal - ablation |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 2026-04-15 | SIM-SUM-001 | SUMMER | 485.0 | 503.0 | 463.9 | 460.2 | 464.2 | 4.0 |
| 2026-04-15 | SIM-RAIN-001 | RAINY | 78.0 | 94.0 | 89.9 | 85.9 | 86.2 | 0.3 |

## Unchanged boundaries

- production LightGBM implementation unchanged
- active FastAPI model selection unchanged
- no Supabase schema or data changes
- no Flutter, replenishment or authentication changes
- expanded dataset remains offline and unimported
- Seasonal classifications remain simulation hypotheses, not verified retail demand effects.
- No forecast was altered by a manually assigned percentage or coefficient.
