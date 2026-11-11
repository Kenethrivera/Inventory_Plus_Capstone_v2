# Stage 2.2 Revised Shared Seasonal Forecasting

Status: offline experiment only. The active forecasting API and application model selection remain unchanged.

## Recommendation

**REVISE**. Activation remains disabled.

Validation selected **Related-activity seasonal** with a **1095-day** maximum history window. The final test was not used for selection.

- Final WAPE gain versus matched ablation: 0.43 pp.
- Final WAPE gain versus existing product-specific LightGBM: -0.72 pp.
- Never-sold false-positive check: True.

## Evaluation population

This evaluation contains exactly **24 expanded synthetic products**: eight SUMMER, eight RAINY, and eight NEUTRAL. It does not include the original 13 products.

The expanded fixture contains exactly 24 new products; the original 13-product fixture remains a separate frozen 676-day benchmark and cannot support 730/1095-day comparisons without fabricating history.

The frozen original 13-product/676-day benchmark is retained by reference; it was not rerun or combined with the expanded population.

## Stage 2.1 reference result

The previous 1,095-day unrestricted pool produced the following frozen final-test comparison. Stage 2.2 does not overwrite it.

| Group | Stage 2.1 ablation WAPE | Stage 2.1 seasonal WAPE | Seasonal gain |
|---|---:|---:|---:|
| SUMMER | 27.35% | 26.86% | 0.49 pp |
| RAINY | 49.07% | 49.17% | -0.09 pp |
| NEUTRAL | 35.30% | 35.46% | -0.16 pp |

Stage 2.1 improved SUMMER but regressed RAINY and NEUTRAL. The controlled pool test below checks whether cross-activity transfer was responsible.

## History-window audit

All models used the same 18 validation origins and 18 final-test origins per window. Each target horizon is 28 days and every training series ends at the origin.

| Window | Split | Observed history min-max | Model | WAPE | MAE | Bias |
|---:|---|---|---|---:|---:|---:|
| 365 | validation | 365-365 | Mean28 | 33.62% | 1.098 | -0.58% |
| 365 | validation | 365-365 | Existing product-specific LightGBM | 33.67% | 1.100 | -0.94% |
| 365 | validation | 365-365 | Unrestricted nonseasonal ablation | 34.59% | 1.130 | -4.92% |
| 365 | validation | 365-365 | Unrestricted seasonal | 34.63% | 1.131 | -4.89% |
| 365 | validation | 365-365 | Related-activity nonseasonal ablation | 34.47% | 1.126 | -1.82% |
| 365 | validation | 365-365 | Related-activity seasonal | 34.38% | 1.123 | -1.52% |
| 365 | final_test | 365-365 | Mean28 | 32.88% | 1.102 | -0.63% |
| 365 | final_test | 365-365 | Existing product-specific LightGBM | 32.41% | 1.086 | -0.66% |
| 365 | final_test | 365-365 | Unrestricted nonseasonal ablation | 33.87% | 1.135 | -4.08% |
| 365 | final_test | 365-365 | Unrestricted seasonal | 33.89% | 1.136 | -3.94% |
| 365 | final_test | 365-365 | Related-activity nonseasonal ablation | 33.62% | 1.126 | -1.83% |
| 365 | final_test | 365-365 | Related-activity seasonal | 33.51% | 1.123 | -1.91% |
| 730 | validation | 730-730 | Mean28 | 33.62% | 1.098 | -0.58% |
| 730 | validation | 730-730 | Existing product-specific LightGBM | 33.05% | 1.079 | -0.64% |
| 730 | validation | 730-730 | Unrestricted nonseasonal ablation | 34.06% | 1.112 | -5.24% |
| 730 | validation | 730-730 | Unrestricted seasonal | 33.86% | 1.106 | -4.80% |
| 730 | validation | 730-730 | Related-activity nonseasonal ablation | 33.59% | 1.097 | -2.78% |
| 730 | validation | 730-730 | Related-activity seasonal | 33.24% | 1.086 | -2.25% |
| 730 | final_test | 730-730 | Mean28 | 32.88% | 1.102 | -0.63% |
| 730 | final_test | 730-730 | Existing product-specific LightGBM | 32.26% | 1.081 | -0.91% |
| 730 | final_test | 730-730 | Unrestricted nonseasonal ablation | 33.46% | 1.121 | -4.36% |
| 730 | final_test | 730-730 | Unrestricted seasonal | 33.35% | 1.117 | -4.54% |
| 730 | final_test | 730-730 | Related-activity nonseasonal ablation | 33.64% | 1.127 | -1.55% |
| 730 | final_test | 730-730 | Related-activity seasonal | 33.50% | 1.123 | -1.30% |
| 1095 | validation | 731-1068 | Mean28 | 33.62% | 1.098 | -0.58% |
| 1095 | validation | 731-1068 | Existing product-specific LightGBM | 32.72% | 1.069 | -0.54% |
| 1095 | validation | 731-1068 | Unrestricted nonseasonal ablation | 33.78% | 1.103 | -5.45% |
| 1095 | validation | 731-1068 | Unrestricted seasonal | 33.59% | 1.097 | -4.60% |
| 1095 | validation | 731-1068 | Related-activity nonseasonal ablation | 33.57% | 1.096 | -3.22% |
| 1095 | validation | 731-1068 | Related-activity seasonal | 33.07% | 1.080 | -2.41% |
| 1095 | final_test | 1095-1095 | Mean28 | 32.88% | 1.102 | -0.63% |
| 1095 | final_test | 1095-1095 | Existing product-specific LightGBM | 31.92% | 1.070 | -1.08% |
| 1095 | final_test | 1095-1095 | Unrestricted nonseasonal ablation | 33.22% | 1.113 | -4.70% |
| 1095 | final_test | 1095-1095 | Unrestricted seasonal | 32.99% | 1.106 | -4.74% |
| 1095 | final_test | 1095-1095 | Related-activity nonseasonal ablation | 33.07% | 1.108 | -2.05% |
| 1095 | final_test | 1095-1095 | Related-activity seasonal | 32.63% | 1.094 | -2.17% |

The 1,095-day setting is a maximum, not fabricated history. Early validation origins use only the history that chronologically exists; final-test origins have enough history to reach the cap.

## Why unrestricted seasonality behaved unevenly

- unrestricted L1 pooling weights high-volume products more heavily and can transfer their calendar response into unrelated products
- RAINY contains intermittent and deliberately overlapping-use products, so one group-level relationship is less uniform than SUMMER
- NEUTRAL products have no designed annual direction; extra seasonal interactions add variance without a stable signal
- related-activity pooling isolates transfer by pre-existing use context while its matched ablation keeps that comparison fair
- existing LightGBM is the product-specific alternative and already includes annual sine/cosine context

The controlled related-activity candidate changes only the training pool. Its feature set, parameters, origins, targets, and no-sales gate are identical to its matched ablation, so this does not strengthen the generator signal.

## Selected final-test results by seasonal group

| Group | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| SUMMER | Mean28 | 1.472 | 26.54% | -0.06% | 22371.5 | 22357.5 |
| SUMMER | Existing product-specific LightGBM | 1.415 | 25.51% | -1.18% | 22371.5 | 22107.1 |
| SUMMER | Related-activity nonseasonal ablation | 1.480 | 26.68% | -3.06% | 22371.5 | 21687.0 |
| SUMMER | Related-activity seasonal | 1.448 | 26.10% | -3.11% | 22371.5 | 21676.5 |
| RAINY | Mean28 | 0.911 | 48.95% | -1.09% | 7505.0 | 7423.0 |
| RAINY | Existing product-specific LightGBM | 0.901 | 48.43% | 0.66% | 7505.0 | 7554.2 |
| RAINY | Related-activity nonseasonal ablation | 0.933 | 50.11% | 2.64% | 7505.0 | 7702.8 |
| RAINY | Related-activity seasonal | 0.922 | 49.52% | 1.97% | 7505.0 | 7652.7 |
| NEUTRAL | Mean28 | 0.922 | 34.89% | -1.48% | 10656.0 | 10498.0 |
| NEUTRAL | Existing product-specific LightGBM | 0.892 | 33.74% | -2.08% | 10656.0 | 10434.6 |
| NEUTRAL | Related-activity nonseasonal ablation | 0.911 | 34.48% | -3.21% | 10656.0 | 10313.6 |
| NEUTRAL | Related-activity seasonal | 0.911 | 34.46% | -3.11% | 10656.0 | 10324.7 |

## Selected final-test results by compatible inventory unit

| Unit | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| bag | Mean28 | 1.575 | 26.46% | 0.43% | 9002.0 | 9041.0 |
| bag | Existing product-specific LightGBM | 1.523 | 25.58% | -2.21% | 9002.0 | 8803.0 |
| bag | Related-activity nonseasonal ablation | 1.560 | 26.19% | -1.75% | 9002.0 | 8844.2 |
| bag | Related-activity seasonal | 1.548 | 26.01% | -2.44% | 9002.0 | 8782.0 |
| box | Mean28 | 1.300 | 26.38% | -1.21% | 4970.0 | 4910.0 |
| box | Existing product-specific LightGBM | 1.263 | 25.62% | 0.61% | 4970.0 | 5000.5 |
| box | Related-activity nonseasonal ablation | 1.285 | 26.06% | -5.09% | 4970.0 | 4716.9 |
| box | Related-activity seasonal | 1.276 | 25.88% | -5.37% | 4970.0 | 4703.2 |
| cu.m. | Mean28 | 0.853 | 66.55% | -4.56% | 1292.5 | 1233.5 |
| cu.m. | Existing product-specific LightGBM | 0.867 | 67.59% | -3.92% | 1292.5 | 1241.8 |
| cu.m. | Related-activity nonseasonal ablation | 0.854 | 66.62% | 10.43% | 1292.5 | 1427.3 |
| cu.m. | Related-activity seasonal | 0.844 | 65.79% | 12.21% | 1292.5 | 1450.4 |
| pail | Mean28 | 1.134 | 44.32% | -1.47% | 1290.0 | 1271.0 |
| pail | Existing product-specific LightGBM | 1.082 | 42.28% | 0.28% | 1290.0 | 1293.6 |
| pail | Related-activity nonseasonal ablation | 1.125 | 43.96% | 5.50% | 1290.0 | 1360.9 |
| pail | Related-activity seasonal | 1.103 | 43.09% | 7.06% | 1290.0 | 1381.1 |
| pcs | Mean28 | 1.060 | 29.74% | -0.36% | 17974.0 | 17909.0 |
| pcs | Existing product-specific LightGBM | 1.017 | 28.53% | 0.42% | 17974.0 | 18049.5 |
| pcs | Related-activity nonseasonal ablation | 1.075 | 30.15% | -2.46% | 17974.0 | 17532.3 |
| pcs | Related-activity seasonal | 1.055 | 29.58% | -2.50% | 17974.0 | 17524.3 |
| roll | Mean28 | 1.018 | 45.68% | -1.28% | 3369.0 | 3326.0 |
| roll | Existing product-specific LightGBM | 1.009 | 45.26% | -2.82% | 3369.0 | 3273.9 |
| roll | Related-activity nonseasonal ablation | 1.036 | 46.49% | 0.31% | 3369.0 | 3379.4 |
| roll | Related-activity seasonal | 1.040 | 46.65% | 0.40% | 3369.0 | 3382.5 |
| set | Mean28 | 0.597 | 126.88% | -5.06% | 237.0 | 225.0 |
| set | Existing product-specific LightGBM | 0.498 | 105.88% | -81.91% | 237.0 | 42.9 |
| set | Related-activity nonseasonal ablation | 0.581 | 123.59% | -22.17% | 237.0 | 184.4 |
| set | Related-activity seasonal | 0.576 | 122.43% | -24.31% | 237.0 | 179.4 |
| sheet | Mean28 | 0.978 | 77.42% | 3.30% | 637.0 | 658.0 |
| sheet | Existing product-specific LightGBM | 0.996 | 78.84% | 0.38% | 637.0 | 639.4 |
| sheet | Related-activity nonseasonal ablation | 0.973 | 77.02% | 2.59% | 637.0 | 653.5 |
| sheet | Related-activity seasonal | 0.971 | 76.80% | 1.55% | 637.0 | 646.9 |
| tube | Mean28 | 1.043 | 29.85% | -3.18% | 1761.0 | 1705.0 |
| tube | Existing product-specific LightGBM | 1.063 | 30.44% | -0.56% | 1761.0 | 1751.2 |
| tube | Related-activity nonseasonal ablation | 1.096 | 31.37% | -8.88% | 1761.0 | 1604.6 |
| tube | Related-activity seasonal | 1.043 | 29.85% | -8.91% | 1761.0 | 1604.1 |

## Selected final-test results by demand pattern

| Pattern | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| intermittent | Mean28 | 0.873 | 75.94% | -0.43% | 3477.5 | 3462.5 |
| intermittent | Existing product-specific LightGBM | 0.887 | 77.10% | -4.72% | 3477.5 | 3313.3 |
| intermittent | Related-activity nonseasonal ablation | 0.885 | 76.98% | 14.70% | 3477.5 | 3988.6 |
| intermittent | Related-activity seasonal | 0.887 | 77.11% | 15.66% | 3477.5 | 4022.2 |
| intermittent_low | Mean28 | 0.393 | 135.32% | -6.48% | 293.0 | 274.0 |
| intermittent_low | Existing product-specific LightGBM | 0.305 | 104.76% | -85.37% | 293.0 | 42.9 |
| intermittent_low | Related-activity nonseasonal ablation | 0.431 | 148.30% | -0.90% | 293.0 | 290.4 |
| intermittent_low | Related-activity seasonal | 0.426 | 146.54% | -4.28% | 293.0 | 280.4 |
| neutral | Mean28 | 1.198 | 30.31% | -1.51% | 9964.0 | 9814.0 |
| neutral | Existing product-specific LightGBM | 1.169 | 29.56% | 0.41% | 9964.0 | 10004.4 |
| neutral | Related-activity nonseasonal ablation | 1.179 | 29.83% | -4.02% | 9964.0 | 9563.8 |
| neutral | Related-activity seasonal | 1.176 | 29.74% | -4.09% | 9964.0 | 9556.4 |
| no_sales | Mean28 | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Existing product-specific LightGBM | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Related-activity nonseasonal ablation | 0.000 | n/a | n/a | 0.0 | 0.0 |
| no_sales | Related-activity seasonal | 0.000 | n/a | n/a | 0.0 | 0.0 |
| rainy | Mean28 | 1.089 | 38.37% | -2.01% | 5719.0 | 5604.0 |
| rainy | Existing product-specific LightGBM | 1.077 | 37.96% | 2.64% | 5719.0 | 5870.0 |
| rainy | Related-activity nonseasonal ablation | 1.097 | 38.69% | -2.06% | 5719.0 | 5600.9 |
| rainy | Related-activity seasonal | 1.074 | 37.86% | -2.63% | 5719.0 | 5568.7 |
| summer | Mean28 | 1.679 | 24.08% | 0.21% | 21079.0 | 21124.0 |
| summer | Existing product-specific LightGBM | 1.598 | 22.93% | -1.01% | 21079.0 | 20865.2 |
| summer | Related-activity nonseasonal ablation | 1.689 | 24.23% | -3.89% | 21079.0 | 20259.8 |
| summer | Related-activity seasonal | 1.649 | 23.66% | -4.05% | 21079.0 | 20226.1 |

## Selected final-test seasonal transitions

| Transition | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| to_dry | Mean28 | 1.047 | 36.06% | 0.71% | 2647.0 | 2665.7 |
| to_dry | Existing product-specific LightGBM | 1.050 | 36.16% | 1.32% | 2647.0 | 2682.0 |
| to_dry | Related-activity nonseasonal ablation | 1.039 | 35.80% | 2.84% | 2647.0 | 2722.3 |
| to_dry | Related-activity seasonal | 1.057 | 36.43% | 0.36% | 2647.0 | 2656.6 |
| to_rainy | Mean28 | 1.123 | 30.39% | -0.45% | 7800.5 | 7765.5 |
| to_rainy | Existing product-specific LightGBM | 1.097 | 29.70% | -0.42% | 7800.5 | 7767.5 |
| to_rainy | Related-activity nonseasonal ablation | 1.151 | 31.18% | -3.00% | 7800.5 | 7566.5 |
| to_rainy | Related-activity seasonal | 1.146 | 31.04% | -2.32% | 7800.5 | 7619.2 |

## Selected final-test per-product accuracy

| SKU | Model | MAE | WAPE | Bias | Actual | Predicted |
|---|---|---:|---:|---:|---:|---:|
| SIM-NEU-001 | Mean28 | 1.081 | 44.14% | -2.11% | 1234.0 | 1208.0 |
| SIM-NEU-001 | Existing product-specific LightGBM | 1.058 | 43.22% | 4.17% | 1234.0 | 1285.4 |
| SIM-NEU-001 | Related-activity nonseasonal ablation | 1.036 | 42.33% | 6.84% | 1234.0 | 1318.5 |
| SIM-NEU-001 | Related-activity seasonal | 1.037 | 42.35% | 6.49% | 1234.0 | 1314.1 |
| SIM-NEU-002 | Mean28 | 1.420 | 24.51% | -0.00% | 2919.0 | 2919.0 |
| SIM-NEU-002 | Existing product-specific LightGBM | 1.382 | 23.86% | 1.34% | 2919.0 | 2958.1 |
| SIM-NEU-002 | Related-activity nonseasonal ablation | 1.427 | 24.65% | -6.43% | 2919.0 | 2731.3 |
| SIM-NEU-002 | Related-activity seasonal | 1.408 | 24.32% | -6.36% | 2919.0 | 2733.4 |
| SIM-NEU-003 | Mean28 | 1.024 | 34.79% | -0.13% | 1484.0 | 1482.0 |
| SIM-NEU-003 | Existing product-specific LightGBM | 1.030 | 34.97% | 0.35% | 1484.0 | 1489.3 |
| SIM-NEU-003 | Related-activity nonseasonal ablation | 1.001 | 33.98% | 0.52% | 1484.0 | 1491.7 |
| SIM-NEU-003 | Related-activity seasonal | 1.003 | 34.05% | 0.59% | 1484.0 | 1492.7 |
| SIM-NEU-004 | Mean28 | 0.597 | 126.88% | -5.06% | 237.0 | 225.0 |
| SIM-NEU-004 | Existing product-specific LightGBM | 0.498 | 105.88% | -81.91% | 237.0 | 42.9 |
| SIM-NEU-004 | Related-activity nonseasonal ablation | 0.581 | 123.59% | -22.17% | 237.0 | 184.4 |
| SIM-NEU-004 | Related-activity seasonal | 0.576 | 122.43% | -24.31% | 237.0 | 179.4 |
| SIM-NEU-005 | Mean28 | 1.286 | 28.48% | -2.72% | 2276.0 | 2214.0 |
| SIM-NEU-005 | Existing product-specific LightGBM | 1.229 | 27.21% | -2.06% | 2276.0 | 2229.2 |
| SIM-NEU-005 | Related-activity nonseasonal ablation | 1.290 | 28.57% | -10.51% | 2276.0 | 2036.9 |
| SIM-NEU-005 | Related-activity seasonal | 1.287 | 28.51% | -10.09% | 2276.0 | 2046.5 |
| SIM-NEU-006 | Mean28 | 1.181 | 29.03% | -2.93% | 2051.0 | 1991.0 |
| SIM-NEU-006 | Existing product-specific LightGBM | 1.145 | 28.13% | -0.42% | 2051.0 | 2042.4 |
| SIM-NEU-006 | Related-activity nonseasonal ablation | 1.142 | 28.07% | -3.19% | 2051.0 | 1985.5 |
| SIM-NEU-006 | Related-activity seasonal | 1.144 | 28.10% | -3.96% | 2051.0 | 1969.7 |
| SIM-NEU-007 | Mean28 | 0.787 | 87.16% | 0.88% | 455.0 | 459.0 |
| SIM-NEU-007 | Existing product-specific LightGBM | 0.793 | 87.89% | -14.88% | 455.0 | 387.3 |
| SIM-NEU-007 | Related-activity nonseasonal ablation | 0.812 | 89.93% | 24.24% | 455.0 | 565.3 |
| SIM-NEU-007 | Related-activity seasonal | 0.831 | 92.06% | 29.43% | 455.0 | 588.9 |
| SIM-NEU-008 | Mean28 | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-NEU-008 | Existing product-specific LightGBM | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-NEU-008 | Related-activity nonseasonal ablation | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-NEU-008 | Related-activity seasonal | 0.000 | n/a | n/a | 0.0 | 0.0 |
| SIM-RAIN-001 | Mean28 | 1.043 | 29.85% | -3.18% | 1761.0 | 1705.0 |
| SIM-RAIN-001 | Existing product-specific LightGBM | 1.063 | 30.44% | -0.56% | 1761.0 | 1751.2 |
| SIM-RAIN-001 | Related-activity nonseasonal ablation | 1.096 | 31.37% | -8.88% | 1761.0 | 1604.6 |
| SIM-RAIN-001 | Related-activity seasonal | 1.043 | 29.85% | -8.91% | 1761.0 | 1604.1 |
| SIM-RAIN-002 | Mean28 | 0.708 | 80.01% | 3.59% | 446.0 | 462.0 |
| SIM-RAIN-002 | Existing product-specific LightGBM | 0.712 | 80.41% | -4.64% | 446.0 | 425.3 |
| SIM-RAIN-002 | Related-activity nonseasonal ablation | 0.702 | 79.29% | 20.62% | 446.0 | 538.0 |
| SIM-RAIN-002 | Related-activity seasonal | 0.723 | 81.75% | 15.98% | 446.0 | 517.3 |
| SIM-RAIN-003 | Mean28 | 0.978 | 77.42% | 3.30% | 637.0 | 658.0 |
| SIM-RAIN-003 | Existing product-specific LightGBM | 0.996 | 78.84% | 0.38% | 637.0 | 639.4 |
| SIM-RAIN-003 | Related-activity nonseasonal ablation | 0.973 | 77.02% | 2.59% | 637.0 | 653.5 |
| SIM-RAIN-003 | Related-activity seasonal | 0.971 | 76.80% | 1.55% | 637.0 | 646.9 |
| SIM-RAIN-004 | Mean28 | 1.189 | 47.91% | -1.20% | 1251.0 | 1236.0 |
| SIM-RAIN-004 | Existing product-specific LightGBM | 1.184 | 47.69% | 9.07% | 1251.0 | 1364.5 |
| SIM-RAIN-004 | Related-activity nonseasonal ablation | 1.171 | 47.17% | 2.90% | 1251.0 | 1287.3 |
| SIM-RAIN-004 | Related-activity seasonal | 1.173 | 47.26% | -0.64% | 1251.0 | 1242.9 |
| SIM-RAIN-005 | Mean28 | 0.850 | 45.94% | -3.32% | 933.0 | 902.0 |
| SIM-RAIN-005 | Existing product-specific LightGBM | 0.830 | 44.86% | -1.86% | 933.0 | 915.6 |
| SIM-RAIN-005 | Related-activity nonseasonal ablation | 0.839 | 45.32% | 10.72% | 933.0 | 1033.0 |
| SIM-RAIN-005 | Related-activity seasonal | 0.832 | 44.94% | 9.02% | 933.0 | 1017.2 |
| SIM-RAIN-006 | Mean28 | 1.271 | 36.12% | -0.73% | 1774.0 | 1761.0 |
| SIM-RAIN-006 | Existing product-specific LightGBM | 1.230 | 34.94% | 3.65% | 1774.0 | 1838.7 |
| SIM-RAIN-006 | Related-activity nonseasonal ablation | 1.284 | 36.48% | -5.52% | 1774.0 | 1676.0 |
| SIM-RAIN-006 | Related-activity seasonal | 1.248 | 35.47% | -3.92% | 1774.0 | 1704.5 |
| SIM-RAIN-007 | Mean28 | 0.190 | 171.05% | -12.50% | 56.0 | 49.0 |
| SIM-RAIN-007 | Existing product-specific LightGBM | 0.111 | 100.00% | -100.00% | 56.0 | 0.0 |
| SIM-RAIN-007 | Related-activity nonseasonal ablation | 0.281 | 252.87% | 89.13% | 56.0 | 105.9 |
| SIM-RAIN-007 | Related-activity seasonal | 0.276 | 248.55% | 80.49% | 56.0 | 101.1 |
| SIM-RAIN-008 | Mean28 | 1.059 | 82.51% | 0.46% | 647.0 | 650.0 |
| SIM-RAIN-008 | Existing product-specific LightGBM | 1.085 | 84.53% | -4.26% | 647.0 | 619.4 |
| SIM-RAIN-008 | Related-activity nonseasonal ablation | 1.116 | 86.95% | 24.35% | 647.0 | 804.5 |
| SIM-RAIN-008 | Related-activity seasonal | 1.108 | 86.29% | 26.56% | 647.0 | 818.8 |
| SIM-SUM-001 | Mean28 | 2.294 | 15.98% | 0.88% | 7235.0 | 7299.0 |
| SIM-SUM-001 | Existing product-specific LightGBM | 2.088 | 14.55% | -0.92% | 7235.0 | 7168.7 |
| SIM-SUM-001 | Related-activity nonseasonal ablation | 2.442 | 17.01% | -8.95% | 7235.0 | 6587.8 |
| SIM-SUM-001 | Related-activity seasonal | 2.285 | 15.92% | -8.79% | 7235.0 | 6599.0 |
| SIM-SUM-002 | Mean28 | 1.939 | 19.36% | 1.33% | 5050.0 | 5117.0 |
| SIM-SUM-002 | Existing product-specific LightGBM | 1.808 | 18.05% | -4.57% | 5050.0 | 4819.5 |
| SIM-SUM-002 | Related-activity nonseasonal ablation | 1.863 | 18.59% | -4.64% | 5050.0 | 4815.7 |
| SIM-SUM-002 | Related-activity seasonal | 1.850 | 18.46% | -5.83% | 5050.0 | 4755.7 |
| SIM-SUM-003 | Mean28 | 0.896 | 63.64% | -3.94% | 710.0 | 682.0 |
| SIM-SUM-003 | Existing product-specific LightGBM | 0.915 | 64.95% | 0.06% | 710.0 | 710.4 |
| SIM-SUM-003 | Related-activity nonseasonal ablation | 0.892 | 63.31% | 8.36% | 710.0 | 769.3 |
| SIM-SUM-003 | Related-activity seasonal | 0.879 | 62.37% | 10.66% | 710.0 | 785.7 |
| SIM-SUM-004 | Mean28 | 0.810 | 70.11% | -5.32% | 582.5 | 551.5 |
| SIM-SUM-004 | Existing product-specific LightGBM | 0.818 | 70.81% | -8.77% | 582.5 | 531.4 |
| SIM-SUM-004 | Related-activity nonseasonal ablation | 0.816 | 70.64% | 12.96% | 582.5 | 658.0 |
| SIM-SUM-004 | Related-activity seasonal | 0.809 | 69.96% | 14.11% | 582.5 | 664.7 |
| SIM-SUM-005 | Mean28 | 1.917 | 27.20% | -1.10% | 3552.0 | 3513.0 |
| SIM-SUM-005 | Existing product-specific LightGBM | 1.850 | 26.25% | 1.35% | 3552.0 | 3600.0 |
| SIM-SUM-005 | Related-activity nonseasonal ablation | 1.888 | 26.78% | -2.39% | 3552.0 | 3466.9 |
| SIM-SUM-005 | Related-activity seasonal | 1.863 | 26.43% | -2.48% | 3552.0 | 3464.0 |
| SIM-SUM-006 | Mean28 | 1.134 | 44.32% | -1.47% | 1290.0 | 1271.0 |
| SIM-SUM-006 | Existing product-specific LightGBM | 1.082 | 42.28% | 0.28% | 1290.0 | 1293.6 |
| SIM-SUM-006 | Related-activity nonseasonal ablation | 1.125 | 43.96% | 5.50% | 1290.0 | 1360.9 |
| SIM-SUM-006 | Related-activity seasonal | 1.103 | 43.09% | 7.06% | 1290.0 | 1381.1 |
| SIM-SUM-007 | Mean28 | 1.446 | 33.25% | -2.37% | 2192.0 | 2140.0 |
| SIM-SUM-007 | Existing product-specific LightGBM | 1.400 | 32.19% | -0.84% | 2192.0 | 2173.6 |
| SIM-SUM-007 | Related-activity nonseasonal ablation | 1.439 | 33.09% | -3.61% | 2192.0 | 2112.9 |
| SIM-SUM-007 | Related-activity seasonal | 1.417 | 32.58% | -4.45% | 2192.0 | 2094.4 |
| SIM-SUM-008 | Mean28 | 1.341 | 38.40% | 1.36% | 1760.0 | 1784.0 |
| SIM-SUM-008 | Existing product-specific LightGBM | 1.360 | 38.95% | 2.84% | 1760.0 | 1810.0 |
| SIM-SUM-008 | Related-activity nonseasonal ablation | 1.376 | 39.41% | 8.84% | 1760.0 | 1915.5 |
| SIM-SUM-008 | Related-activity seasonal | 1.379 | 39.48% | 9.77% | 1760.0 | 1931.9 |

A zero-actual no-sales control has undefined WAPE by design; its MAE and predicted total are the relevant false-positive checks. Genuine intermittent products retain their observed nonzero history and are not gated.

## Pre-transition examples

| Origin | SKU | Group | Actual next 28d | Mean28 | Existing LGBM | Selected seasonal |
|---|---|---|---:|---:|---:|---:|
| 2026-02-15 | SIM-SUM-001 | SUMMER | 443.0 | 465.0 | 460.8 | 415.2 |
| 2026-04-30 | SIM-RAIN-001 | RAINY | 109.0 | 84.0 | 87.6 | 91.3 |
| 2026-04-30 | SIM-NEU-001 | NEUTRAL | 75.0 | 62.0 | 74.7 | 75.0 |

## Boundaries and interpretation

- no Supabase schema or data changes
- no expanded-dataset import
- no Flutter, authentication or replenishment changes
- no active forecasting API or model-selection changes
- no synthetic seasonal effects were strengthened
- SUMMER/RAINY/NEUTRAL remain synthetic hypotheses, not verified hardware retail effects.
- Mixed-unit overall totals are diagnostic only; product and compatible-unit metrics are the decision-safe comparisons.
- No PAGASA calendar feature is itself a demand multiplier; numerical effects are learned only from past training targets.
