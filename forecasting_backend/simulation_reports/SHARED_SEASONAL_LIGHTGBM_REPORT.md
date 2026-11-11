# Shared Philippine Seasonal LightGBM Evaluation

Status: experimental; not connected to the normal forecasting API or replenishment.

## Decision

**REJECT** for application integration.

The decision is determined by the frozen acceptance rules in the runner. It is not a deployment switch; `activation_allowed` remains false.

## Evaluation contract

- Dataset: SQL 02 deterministic 676-day full-inventory fixture
- History: 2025-01-01 through 2026-11-07 (676 calendar days)
- Products: 13
- Rolling origins: 29
- Horizon: 28 days at every origin
- Maximum training history: 365 days
- Product context: `shared-product-context-v1+hardware-seasonal-knowledge-v2+inventory-plus-hardware-taxonomy-v3+inventory-plus-binan-catalog-v1`

All six models use the same origins and target dates. Demand-pattern labels are used only after prediction for reporting. Future-known calendar features are allowed; future sales are not.

## Overall comparison

The overall row mixes inventory units and is therefore diagnostic. Product-level and compatible-unit tables are the decision-safe views.

| Model | MAE | WAPE (%) | Bias (%) | Macro product WAPE (%) |
|---|---:|---:|---:|---:|
| Mean28 | 0.834 | 22.65 | -1.82 | 60.29 |
| Existing LightGBM | 0.623 | 16.93 | -6.55 | 35.01 |
| Calibrated blend | 0.746 | 20.27 | 0.45 | 54.50 |
| Previous seasonal LightGBM | 0.624 | 16.95 | -6.57 | 35.03 |
| Shared seasonal LightGBM | 0.709 | 19.26 | -8.66 | 78.45 |
| Shared model without seasonal features | 0.703 | 19.11 | -9.18 | 72.62 |

## Seasonal-feature ablation

Shared seasonal minus shared nonseasonal WAPE: **0.15 percentage points**.

| Transition | Shared seasonal WAPE | Ablation WAPE | Difference |
|---|---:|---:|---:|
| to_dry | 26.95 | 26.37 | 0.59 |
| to_rainy | 16.07 | 15.69 | 0.38 |

## Regression summary

| Comparator | Products better | Products worse | Tied |
|---|---:|---:|---:|
| Existing LightGBM | 7 | 5 | 0 |
| Previous seasonal LightGBM | 7 | 5 | 0 |
| Shared model without seasonal features | 5 | 7 | 0 |

Notable failures are visible rather than suppressed: the shared seasonal model's intermittent-low WAPE is 213.79, and it predicts 163.1 units across backtest points for the zero-sales product. These are unacceptable production regressions even though seven comparable products beat the existing per-product LightGBM.

## Results by compatible inventory unit

| Model | Unit | MAE | WAPE (%) | Bias (%) | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| Mean28 | kl | 1.344 | 33.12 | -2.70 | 6590.0 | 6412.0 |
| Mean28 | pcs | 0.651 | 22.00 | -2.21 | 24042.0 | 23510.0 |
| Mean28 | roll | 1.635 | 16.14 | 0.05 | 8222.0 | 8226.0 |
| Existing LightGBM | kl | 0.816 | 20.10 | -6.98 | 6590.0 | 6130.3 |
| Existing LightGBM | pcs | 0.593 | 20.02 | -8.63 | 24042.0 | 21967.8 |
| Existing LightGBM | roll | 0.542 | 5.35 | -0.12 | 8222.0 | 8212.0 |
| Calibrated blend | kl | 1.158 | 28.53 | 1.56 | 6590.0 | 6692.7 |
| Calibrated blend | pcs | 0.626 | 21.14 | 0.07 | 24042.0 | 24058.6 |
| Calibrated blend | roll | 1.123 | 11.09 | 0.68 | 8222.0 | 8277.5 |
| Previous seasonal LightGBM | kl | 0.818 | 20.16 | -7.03 | 6590.0 | 6126.7 |
| Previous seasonal LightGBM | pcs | 0.593 | 20.04 | -8.65 | 24042.0 | 21961.2 |
| Previous seasonal LightGBM | roll | 0.542 | 5.35 | -0.12 | 8222.0 | 8212.0 |
| Shared seasonal LightGBM | kl | 1.024 | 25.24 | -11.79 | 6590.0 | 5813.2 |
| Shared seasonal LightGBM | pcs | 0.518 | 17.50 | -4.31 | 24042.0 | 23004.6 |
| Shared seasonal LightGBM | roll | 1.987 | 19.62 | -18.85 | 8222.0 | 6672.0 |
| Shared model without seasonal features | kl | 1.040 | 25.64 | -12.96 | 6590.0 | 5736.2 |
| Shared model without seasonal features | pcs | 0.512 | 17.28 | -4.98 | 24042.0 | 22845.5 |
| Shared model without seasonal features | roll | 1.945 | 19.21 | -18.44 | 8222.0 | 6705.5 |

## Results by Philippine season

| Model | Season | MAE | WAPE (%) | Bias (%) | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| Mean28 | dry | 0.797 | 22.08 | 1.27 | 8777.0 | 8888.4 |
| Mean28 | rainy | 0.835 | 22.81 | 0.31 | 17473.0 | 17527.2 |
| Mean28 | transition | 0.858 | 22.82 | -6.92 | 12604.0 | 11732.4 |
| Existing LightGBM | dry | 0.579 | 16.05 | -2.54 | 8777.0 | 8554.3 |
| Existing LightGBM | rainy | 0.624 | 17.05 | -6.01 | 17473.0 | 16423.5 |
| Existing LightGBM | transition | 0.653 | 17.38 | -10.09 | 12604.0 | 11332.3 |
| Calibrated blend | dry | 0.701 | 19.41 | 4.56 | 8777.0 | 9177.4 |
| Calibrated blend | rainy | 0.764 | 20.85 | 1.64 | 17473.0 | 17759.4 |
| Calibrated blend | transition | 0.754 | 20.05 | -4.06 | 12604.0 | 12092.0 |
| Previous seasonal LightGBM | dry | 0.580 | 16.06 | -2.51 | 8777.0 | 8557.1 |
| Previous seasonal LightGBM | rainy | 0.624 | 17.03 | -6.03 | 17473.0 | 16420.2 |
| Previous seasonal LightGBM | transition | 0.656 | 17.47 | -10.17 | 12604.0 | 11322.7 |
| Shared seasonal LightGBM | dry | 0.704 | 19.49 | -5.98 | 8777.0 | 8251.8 |
| Shared seasonal LightGBM | rainy | 0.669 | 18.28 | -7.22 | 17473.0 | 16211.2 |
| Shared seasonal LightGBM | transition | 0.769 | 20.46 | -12.51 | 12604.0 | 11026.9 |
| Shared model without seasonal features | dry | 0.690 | 19.10 | -6.74 | 8777.0 | 8185.2 |
| Shared model without seasonal features | rainy | 0.677 | 18.47 | -7.91 | 17473.0 | 16090.9 |
| Shared model without seasonal features | transition | 0.751 | 19.99 | -12.64 | 12604.0 | 11011.2 |

## Results by demand pattern

| Model | Pattern | MAE | WAPE (%) | Bias (%) | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| Mean28 | dead_stock | 0.100 | 197.91 | 12.20 | 41.0 | 46.0 |
| Mean28 | decreasing | 0.646 | 12.33 | 5.36 | 4251.0 | 4479.0 |
| Mean28 | decreasing_slow | 0.555 | 17.27 | 6.97 | 2610.0 | 2792.0 |
| Mean28 | growing_seasonal | 1.091 | 23.44 | -6.85 | 3780.0 | 3521.0 |
| Mean28 | high_seasonal | 1.872 | 24.64 | -2.50 | 6168.0 | 6014.0 |
| Mean28 | high_stable | 1.635 | 16.14 | 0.05 | 8222.0 | 8226.0 |
| Mean28 | increasing | 0.629 | 14.00 | -5.73 | 3649.0 | 3440.0 |
| Mean28 | increasing_high | 1.135 | 21.84 | -4.50 | 4221.0 | 4031.0 |
| Mean28 | intermittent_low | 0.264 | 178.69 | 0.83 | 120.0 | 121.0 |
| Mean28 | intermittent_seasonal | 0.816 | 157.09 | -5.69 | 422.0 | 398.0 |
| Mean28 | no_sales | 0.000 | n/a | n/a | 0.0 | 0.0 |
| Mean28 | seasonal_medium | 1.509 | 37.49 | -8.81 | 3268.0 | 2980.0 |
| Mean28 | stable_medium | 0.585 | 22.59 | -0.10 | 2102.0 | 2100.0 |
| Existing LightGBM | dead_stock | 0.037 | 72.98 | -38.54 | 41.0 | 25.2 |
| Existing LightGBM | decreasing | 0.622 | 11.88 | 9.12 | 4251.0 | 4638.6 |
| Existing LightGBM | decreasing_slow | 0.587 | 18.28 | 14.78 | 2610.0 | 2995.8 |
| Existing LightGBM | growing_seasonal | 1.076 | 23.11 | -18.25 | 3780.0 | 3090.2 |
| Existing LightGBM | high_seasonal | 1.211 | 15.94 | -6.05 | 6168.0 | 5794.7 |
| Existing LightGBM | high_stable | 0.542 | 5.35 | -0.12 | 8222.0 | 8212.0 |
| Existing LightGBM | increasing | 0.897 | 19.96 | -19.95 | 3649.0 | 2921.1 |
| Existing LightGBM | increasing_high | 0.949 | 18.26 | -14.96 | 4221.0 | 3589.7 |
| Existing LightGBM | intermittent_low | 0.161 | 108.91 | -89.64 | 120.0 | 12.4 |
| Existing LightGBM | intermittent_seasonal | 0.420 | 80.83 | -20.48 | 422.0 | 335.6 |
| Existing LightGBM | no_sales | 0.000 | n/a | n/a | 0.0 | 0.0 |
| Existing LightGBM | seasonal_medium | 1.243 | 30.88 | -18.76 | 3268.0 | 2655.1 |
| Existing LightGBM | stable_medium | 0.355 | 13.72 | -2.96 | 2102.0 | 2039.7 |
| Calibrated blend | dead_stock | 0.086 | 169.34 | 68.46 | 41.0 | 69.1 |
| Calibrated blend | decreasing | 0.545 | 10.40 | 0.63 | 4251.0 | 4278.0 |
| Calibrated blend | decreasing_slow | 0.545 | 16.96 | 8.49 | 2610.0 | 2831.6 |
| Calibrated blend | growing_seasonal | 1.134 | 24.35 | -5.77 | 3780.0 | 3561.9 |
| Calibrated blend | high_seasonal | 1.651 | 21.74 | 0.26 | 6168.0 | 6183.9 |
| Calibrated blend | high_stable | 1.123 | 11.09 | 0.68 | 8222.0 | 8277.5 |
| Calibrated blend | increasing | 0.745 | 16.58 | 6.45 | 3649.0 | 3884.4 |
| Calibrated blend | increasing_high | 0.997 | 19.18 | -1.13 | 4221.0 | 4173.4 |
| Calibrated blend | intermittent_low | 0.269 | 181.78 | 3.78 | 120.0 | 124.5 |
| Calibrated blend | intermittent_seasonal | 0.664 | 127.78 | 20.58 | 422.0 | 508.8 |
| Calibrated blend | no_sales | 0.000 | n/a | n/a | 0.0 | 0.0 |
| Calibrated blend | seasonal_medium | 1.465 | 36.41 | -8.71 | 3268.0 | 2983.3 |
| Calibrated blend | stable_medium | 0.475 | 18.35 | 2.40 | 2102.0 | 2152.4 |
| Previous seasonal LightGBM | dead_stock | 0.037 | 72.98 | -38.54 | 41.0 | 25.2 |
| Previous seasonal LightGBM | decreasing | 0.623 | 11.90 | 9.13 | 4251.0 | 4639.0 |
| Previous seasonal LightGBM | decreasing_slow | 0.587 | 18.28 | 14.78 | 2610.0 | 2995.8 |
| Previous seasonal LightGBM | growing_seasonal | 1.084 | 23.29 | -18.43 | 3780.0 | 3083.4 |
| Previous seasonal LightGBM | high_seasonal | 1.216 | 16.01 | -6.11 | 6168.0 | 5791.2 |
| Previous seasonal LightGBM | high_stable | 0.542 | 5.35 | -0.12 | 8222.0 | 8212.0 |
| Previous seasonal LightGBM | increasing | 0.897 | 19.96 | -19.95 | 3649.0 | 2921.1 |
| Previous seasonal LightGBM | increasing_high | 0.948 | 18.23 | -15.01 | 4221.0 | 3587.4 |
| Previous seasonal LightGBM | intermittent_low | 0.161 | 108.91 | -89.64 | 120.0 | 12.4 |
| Previous seasonal LightGBM | intermittent_seasonal | 0.420 | 80.83 | -20.48 | 422.0 | 335.6 |
| Previous seasonal LightGBM | no_sales | 0.000 | n/a | n/a | 0.0 | 0.0 |
| Previous seasonal LightGBM | seasonal_medium | 1.243 | 30.88 | -18.76 | 3268.0 | 2655.1 |
| Previous seasonal LightGBM | stable_medium | 0.355 | 13.70 | -2.86 | 2102.0 | 2041.8 |
| Shared seasonal LightGBM | dead_stock | 0.226 | 446.65 | 324.15 | 41.0 | 173.9 |
| Shared seasonal LightGBM | decreasing | 0.436 | 8.32 | -1.42 | 4251.0 | 4190.4 |
| Shared seasonal LightGBM | decreasing_slow | 0.524 | 16.32 | 3.51 | 2610.0 | 2701.5 |
| Shared seasonal LightGBM | growing_seasonal | 0.828 | 17.79 | -10.38 | 3780.0 | 3387.7 |
| Shared seasonal LightGBM | high_seasonal | 1.337 | 17.60 | -10.57 | 6168.0 | 5515.8 |
| Shared seasonal LightGBM | high_stable | 1.987 | 19.62 | -18.85 | 8222.0 | 6672.0 |
| Shared seasonal LightGBM | increasing | 0.437 | 9.71 | -6.53 | 3649.0 | 3410.6 |
| Shared seasonal LightGBM | increasing_high | 0.837 | 16.11 | -8.32 | 4221.0 | 3870.0 |
| Shared seasonal LightGBM | intermittent_low | 0.316 | 213.79 | 45.97 | 120.0 | 175.2 |
| Shared seasonal LightGBM | intermittent_seasonal | 0.711 | 136.80 | -29.52 | 422.0 | 297.4 |
| Shared seasonal LightGBM | no_sales | 0.201 | n/a | n/a | 0.0 | 163.1 |
| Shared seasonal LightGBM | seasonal_medium | 1.046 | 25.98 | -11.50 | 3268.0 | 2892.1 |
| Shared seasonal LightGBM | stable_medium | 0.330 | 12.75 | -2.94 | 2102.0 | 2040.2 |
| Shared model without seasonal features | dead_stock | 0.201 | 397.14 | 262.47 | 41.0 | 148.6 |
| Shared model without seasonal features | decreasing | 0.446 | 8.51 | -2.39 | 4251.0 | 4149.4 |
| Shared model without seasonal features | decreasing_slow | 0.540 | 16.81 | 3.70 | 2610.0 | 2706.5 |
| Shared model without seasonal features | growing_seasonal | 0.824 | 17.70 | -11.35 | 3780.0 | 3351.1 |
| Shared model without seasonal features | high_seasonal | 1.400 | 18.44 | -11.22 | 6168.0 | 5475.8 |
| Shared model without seasonal features | high_stable | 1.945 | 19.21 | -18.44 | 8222.0 | 6705.5 |
| Shared model without seasonal features | increasing | 0.440 | 9.78 | -7.13 | 3649.0 | 3388.8 |
| Shared model without seasonal features | increasing_high | 0.798 | 15.36 | -8.49 | 4221.0 | 3862.6 |
| Shared model without seasonal features | intermittent_low | 0.293 | 198.24 | 25.22 | 120.0 | 150.3 |
| Shared model without seasonal features | intermittent_seasonal | 0.681 | 130.95 | -38.31 | 422.0 | 260.4 |
| Shared model without seasonal features | no_sales | 0.174 | n/a | n/a | 0.0 | 141.4 |
| Shared model without seasonal features | seasonal_medium | 1.076 | 26.73 | -10.81 | 3268.0 | 2914.7 |
| Shared model without seasonal features | stable_medium | 0.325 | 12.57 | -3.32 | 2102.0 | 2032.2 |

## Season-transition results

| Model | Transition | MAE | WAPE (%) | Bias (%) | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| Mean28 | to_dry | 1.186 | 28.85 | -15.94 | 5077.0 | 4267.8 |
| Mean28 | to_rainy | 0.666 | 18.75 | -0.83 | 7527.0 | 7464.6 |
| Existing LightGBM | to_dry | 1.047 | 25.48 | -16.16 | 5077.0 | 4256.6 |
| Existing LightGBM | to_rainy | 0.423 | 11.92 | -6.00 | 7527.0 | 7075.7 |
| Calibrated blend | to_dry | 1.007 | 24.49 | -11.35 | 5077.0 | 4500.7 |
| Calibrated blend | to_rainy | 0.606 | 17.06 | 0.85 | 7527.0 | 7591.2 |
| Previous seasonal LightGBM | to_dry | 1.053 | 25.61 | -16.29 | 5077.0 | 4249.9 |
| Previous seasonal LightGBM | to_rainy | 0.425 | 11.97 | -6.03 | 7527.0 | 7072.8 |
| Shared seasonal LightGBM | to_dry | 1.108 | 26.95 | -19.72 | 5077.0 | 4075.7 |
| Shared seasonal LightGBM | to_rainy | 0.571 | 16.07 | -7.65 | 7527.0 | 6951.2 |
| Shared model without seasonal features | to_dry | 1.084 | 26.37 | -19.86 | 5077.0 | 4068.6 |
| Shared model without seasonal features | to_rainy | 0.557 | 15.69 | -7.76 | 7527.0 | 6942.6 |

## Product-level accuracy

| SKU | Model | MAE | WAPE (%) | Bias (%) |
|---|---|---:|---:|---:|
| SKU-001 | Mean28 | 0.629 | 14.00 | -5.73 |
| SKU-001 | Existing LightGBM | 0.897 | 19.96 | -19.95 |
| SKU-001 | Calibrated blend | 0.745 | 16.58 | 6.45 |
| SKU-001 | Previous seasonal LightGBM | 0.897 | 19.96 | -19.95 |
| SKU-001 | Shared seasonal LightGBM | 0.437 | 9.71 | -6.53 |
| SKU-001 | Shared model without seasonal features | 0.440 | 9.78 | -7.13 |
| SKU-002 | Mean28 | 1.872 | 24.64 | -2.50 |
| SKU-002 | Existing LightGBM | 1.211 | 15.94 | -6.05 |
| SKU-002 | Calibrated blend | 1.651 | 21.74 | 0.26 |
| SKU-002 | Previous seasonal LightGBM | 1.216 | 16.01 | -6.11 |
| SKU-002 | Shared seasonal LightGBM | 1.337 | 17.60 | -10.57 |
| SKU-002 | Shared model without seasonal features | 1.400 | 18.44 | -11.22 |
| SKU-1004 | Mean28 | 0.585 | 22.59 | -0.10 |
| SKU-1004 | Existing LightGBM | 0.355 | 13.72 | -2.96 |
| SKU-1004 | Calibrated blend | 0.475 | 18.35 | 2.40 |
| SKU-1004 | Previous seasonal LightGBM | 0.355 | 13.70 | -2.86 |
| SKU-1004 | Shared seasonal LightGBM | 0.330 | 12.75 | -2.94 |
| SKU-1004 | Shared model without seasonal features | 0.325 | 12.57 | -3.32 |
| SKU-1005 | Mean28 | 1.135 | 21.84 | -4.50 |
| SKU-1005 | Existing LightGBM | 0.949 | 18.26 | -14.96 |
| SKU-1005 | Calibrated blend | 0.997 | 19.18 | -1.13 |
| SKU-1005 | Previous seasonal LightGBM | 0.948 | 18.23 | -15.01 |
| SKU-1005 | Shared seasonal LightGBM | 0.837 | 16.11 | -8.32 |
| SKU-1005 | Shared model without seasonal features | 0.798 | 15.36 | -8.49 |
| SKU-1006 | Mean28 | 1.509 | 37.49 | -8.81 |
| SKU-1006 | Existing LightGBM | 1.243 | 30.88 | -18.76 |
| SKU-1006 | Calibrated blend | 1.465 | 36.41 | -8.71 |
| SKU-1006 | Previous seasonal LightGBM | 1.243 | 30.88 | -18.76 |
| SKU-1006 | Shared seasonal LightGBM | 1.046 | 25.98 | -11.50 |
| SKU-1006 | Shared model without seasonal features | 1.076 | 26.73 | -10.81 |
| SKU-1007 | Mean28 | 0.264 | 178.69 | 0.83 |
| SKU-1007 | Existing LightGBM | 0.161 | 108.91 | -89.64 |
| SKU-1007 | Calibrated blend | 0.269 | 181.78 | 3.78 |
| SKU-1007 | Previous seasonal LightGBM | 0.161 | 108.91 | -89.64 |
| SKU-1007 | Shared seasonal LightGBM | 0.316 | 213.79 | 45.97 |
| SKU-1007 | Shared model without seasonal features | 0.293 | 198.24 | 25.22 |
| SKU-1008 | Mean28 | 0.646 | 12.33 | 5.36 |
| SKU-1008 | Existing LightGBM | 0.622 | 11.88 | 9.12 |
| SKU-1008 | Calibrated blend | 0.545 | 10.40 | 0.63 |
| SKU-1008 | Previous seasonal LightGBM | 0.623 | 11.90 | 9.13 |
| SKU-1008 | Shared seasonal LightGBM | 0.436 | 8.32 | -1.42 |
| SKU-1008 | Shared model without seasonal features | 0.446 | 8.51 | -2.39 |
| SKU-1009 | Mean28 | 1.635 | 16.14 | 0.05 |
| SKU-1009 | Existing LightGBM | 0.542 | 5.35 | -0.12 |
| SKU-1009 | Calibrated blend | 1.123 | 11.09 | 0.68 |
| SKU-1009 | Previous seasonal LightGBM | 0.542 | 5.35 | -0.12 |
| SKU-1009 | Shared seasonal LightGBM | 1.987 | 19.62 | -18.85 |
| SKU-1009 | Shared model without seasonal features | 1.945 | 19.21 | -18.44 |
| SKU-1010 | Mean28 | 1.091 | 23.44 | -6.85 |
| SKU-1010 | Existing LightGBM | 1.076 | 23.11 | -18.25 |
| SKU-1010 | Calibrated blend | 1.134 | 24.35 | -5.77 |
| SKU-1010 | Previous seasonal LightGBM | 1.084 | 23.29 | -18.43 |
| SKU-1010 | Shared seasonal LightGBM | 0.828 | 17.79 | -10.38 |
| SKU-1010 | Shared model without seasonal features | 0.824 | 17.70 | -11.35 |
| SKU-3UWPD0GN | Mean28 | 0.555 | 17.27 | 6.97 |
| SKU-3UWPD0GN | Existing LightGBM | 0.587 | 18.28 | 14.78 |
| SKU-3UWPD0GN | Calibrated blend | 0.545 | 16.96 | 8.49 |
| SKU-3UWPD0GN | Previous seasonal LightGBM | 0.587 | 18.28 | 14.78 |
| SKU-3UWPD0GN | Shared seasonal LightGBM | 0.524 | 16.32 | 3.51 |
| SKU-3UWPD0GN | Shared model without seasonal features | 0.540 | 16.81 | 3.70 |
| SKU-4W6D3LVI | Mean28 | 0.100 | 197.91 | 12.20 |
| SKU-4W6D3LVI | Existing LightGBM | 0.037 | 72.98 | -38.54 |
| SKU-4W6D3LVI | Calibrated blend | 0.086 | 169.34 | 68.46 |
| SKU-4W6D3LVI | Previous seasonal LightGBM | 0.037 | 72.98 | -38.54 |
| SKU-4W6D3LVI | Shared seasonal LightGBM | 0.226 | 446.65 | 324.15 |
| SKU-4W6D3LVI | Shared model without seasonal features | 0.201 | 397.14 | 262.47 |
| SKU-69QAUJ4Z | Mean28 | 0.000 | n/a | n/a |
| SKU-69QAUJ4Z | Existing LightGBM | 0.000 | n/a | n/a |
| SKU-69QAUJ4Z | Calibrated blend | 0.000 | n/a | n/a |
| SKU-69QAUJ4Z | Previous seasonal LightGBM | 0.000 | n/a | n/a |
| SKU-69QAUJ4Z | Shared seasonal LightGBM | 0.201 | n/a | n/a |
| SKU-69QAUJ4Z | Shared model without seasonal features | 0.174 | n/a | n/a |
| SKU-K1CB7XQV | Mean28 | 0.816 | 157.09 | -5.69 |
| SKU-K1CB7XQV | Existing LightGBM | 0.420 | 80.83 | -20.48 |
| SKU-K1CB7XQV | Calibrated blend | 0.664 | 127.78 | 20.58 |
| SKU-K1CB7XQV | Previous seasonal LightGBM | 0.420 | 80.83 | -20.48 |
| SKU-K1CB7XQV | Shared seasonal LightGBM | 0.711 | 136.80 | -29.52 |
| SKU-K1CB7XQV | Shared model without seasonal features | 0.681 | 130.95 | -38.31 |

## Transition anticipation examples

These windows start after their forecast origin and cross into the seasonal boundary. The seasonal-minus-ablation value is the numeric attribution; no Gemini explanation or multiplier is used.

| Origin | Product | Target | Recent 28 actual | Target actual | Shared seasonal | Ablation | Difference |
|---|---|---|---:|---:|---:|---:|---:|
| 2025-05-15 | Tape Measure | 2025-06-01 to 2025-06-07 | 69.0 | 45.0 | 15.9 | 15.9 | -0.0 |
| 2025-10-15 | Concrete Nails 2-inch | 2025-11-01 to 2025-11-07 | 176.0 | 71.0 | 42.5 | 40.1 | 2.3 |
| 2025-10-15 | Safety Goggles | 2025-11-01 to 2025-11-07 | 95.0 | 38.0 | 22.4 | 22.5 | -0.1 |
| 2026-10-10 | Concrete Nails 1-inch | 2026-11-01 to 2026-11-07 | 10.0 | 8.0 | 2.2 | 1.5 | 0.7 |

## Next 28-day experimental forecasts

The complete daily series for every product is in the JSON artifact.
Material influence requires both a product-level backtest WAPE gain of at least 0.5 percentage point and a 28-day difference of at least 5% versus ablation. This reporting threshold does not alter any forecast.

| SKU | Product | Unit | 7-day total | 28-day total | Ablation total | Seasonal influence supported? | Evidence |
|---|---|---|---:|---:|---:|---|---|
| SKU-001 | Heavy Duty Staple Gun | pcs | 52.4 | 207.5 | 206.5 | no | insufficient; insufficient |
| SKU-002 | Concrete Nails 2-inch | kl | 51.5 | 170.5 | 184.5 | yes | product_specific; provisional_general_mechanism |
| SKU-1004 | Claw Hammer | pcs | 17.5 | 70.8 | 70.4 | no | insufficient; insufficient |
| SKU-1005 | Phillips Screwdriver | pcs | 47.7 | 189.3 | 190.7 | no | insufficient; insufficient |
| SKU-1006 | Tape Measure | pcs | 37.8 | 149.3 | 123.1 | yes | insufficient; insufficient |
| SKU-1007 | Cordless Drill | pcs | 1.0 | 6.1 | 4.4 | no | insufficient; insufficient |
| SKU-1008 | PVC Pipe | pcs | 17.4 | 69.4 | 67.9 | no | product_specific; provisional_conflicting_mechanisms |
| SKU-1009 | Teflon Tape | roll | 63.1 | 198.6 | 223.0 | no | insufficient; insufficient |
| SKU-1010 | Safety Goggles | pcs | 37.9 | 132.2 | 134.0 | no | insufficient; insufficient |
| SKU-3UWPD0GN | Adjustable wrench | pcs | 10.4 | 45.0 | 45.2 | no | insufficient; insufficient |
| SKU-4W6D3LVI | realtime_test2 | pcs | 0.9 | 5.8 | 4.3 | no | insufficient; insufficient |
| SKU-69QAUJ4Z | test item | pcs | 0.9 | 5.8 | 4.3 | no | insufficient; insufficient |
| SKU-K1CB7XQV | Concrete Nails 1-inch | kl | 1.2 | 7.2 | 5.9 | no | product_specific; provisional_general_mechanism |

## Acceptance checks

- Seasonal model beats pooled nonseasonal ablation overall: False
- Maintains/improves both transitions: False
- Product regression balance versus existing LightGBM acceptable: True
- No-sales false-positive guard passed: False
- Normal API/model selection/replenishment changed: False

## Limitations

- Synthetic month effects are programmed test assumptions, not verified Philippine hardware demand effects.
- The model uses climatological calendar context, not archived as-of weather forecasts or realized future rainfall.
- Mixed-unit overall totals are diagnostic only; model selection emphasizes per-product and compatible-unit metrics.
- The classification registry contains qualitative evidence classes and no demand multiplier.
- One 676-day simulation is insufficient to authorize production activation.
