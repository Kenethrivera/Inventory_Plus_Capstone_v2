# Stage 2.7 Sales-Based Seasonal Learning

**Decision: REVISE**

## Verified input

- Live export comparison: **PASS**.
- Dense rows: 35064.
- Date range: 2022-11-10 through 2026-11-09.
- Discovery received only dates and quantities. Frozen labels, SKUs, taxonomy, product names, and generator amplitudes were excluded from model inputs.

## Method

- Linear trend is the nonseasonal model; one annual sine/cosine pair is the candidate seasonal model.
- A seasonal direction requires delta BIC >= 6, a 95% effect interval excluding zero, at least two consistent significant annual blocks, and positive chronological holdout MAE gain whose 95% moving-block-bootstrap interval excludes zero.
- NEUTRAL requires the trend-only model to be preferred, an effect interval spanning zero, no significant annual block, and no holdout gain.
- Otherwise the result is UNKNOWN. Stock availability is not observed, so these remain sales-pattern classifications.

## Final 36-month classification

| Method | Accuracy | Coverage | Covered accuracy | UNKNOWN | Seasonal precision | False seasonal |
|---|---:|---:|---:|---:|---:|---:|
| Evidence-gated discovery | 62.50% | 62.50% | 100.00% | 37.50% | 100.00% | 0 |
| Simple raw-season baseline | 91.67% | 95.83% | 95.65% | 4.17% | 100.00% | 0 |

### Performance by frozen hypothesis group

| Actual group | Correct | Products | Recall |
|---|---:|---:|---:|
| SUMMER | 3 | 8 | 37.50% |
| RAINY | 6 | 8 | 75.00% |
| NEUTRAL | 6 | 8 | 75.00% |

## Chronological learning

| Window | Accuracy | Coverage | UNKNOWN | False seasonal |
|---:|---:|---:|---:|---:|
| 6 months | 0.00% | 0.00% | 100.00% | 0 |
| 12 months | 0.00% | 0.00% | 100.00% | 0 |
| 24 months | 54.17% | 54.17% | 45.83% | 0 |
| 36 months | 62.50% | 62.50% | 37.50% | 0 |

## Untouched fourth-year confirmation

- Seasonal classifications tested: 9.
- Direction confirmed at p < 0.05: 8.
- Confirmation rate: 88.89%.
- NEUTRAL/UNKNOWN outputs are not treated as proven by a nonsignificant future-year test.

## Acceptance assessment

- PASS: live Stage 2.6 history exactly matches frozen fixture.
- PASS: 6- and 12-month windows abstain because fewer than two cycles exist.
- PASS: never-sold control remains UNKNOWN.
- FAIL: final accuracy is at least 70 percent.
- PASS: coverage is at least 50 percent.
- PASS: seasonal precision is at least 80 percent.
- PASS: no more than one neutral product is falsely seasonal.
- FAIL: method accuracy is no worse than simple baseline.
- PASS: at least 75 percent of seasonal assignments confirm in untouched year.

## Limitations

- Frozen labels are simulation hypotheses, not verified Philippine hardware retail relationships.
- Sales alone cannot distinguish lost demand from stockouts because historical stock availability is unknown.
- A NEUTRAL result means the configured evidence gates favored no annual pattern; it does not prove demand can never be seasonal.
- UNKNOWN is intentional for inadequate, sparse, conflicting, or unstable evidence.
- The experiment does not modify existing classifications, forecasts, replenishment, Supabase, or Flutter.

## Frontend recommendation

Keep this offline until real sales and stock-availability data are available. A future UI should show the learned label, UNKNOWN state, evidence gates, history window, last evaluation date, and direct-vs-prior knowledge separately; it must never silently overwrite the existing classification.
