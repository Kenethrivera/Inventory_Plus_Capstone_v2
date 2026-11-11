# Stage 2.7B Seasonal Discovery Refinement

**Decision: REVISE**

## Refinement boundary

- Original Stage 2.7 code and results remain unchanged.
- Three ablations were declared: remove only the cycle-significance gate, remove only the bootstrap-significance gate, or remove both redundant significance gates.
- BIC >= 6, a 95% effect interval excluding zero, positive chronological MAE gain, reversal protection, sparse/no-sales abstention, and calendar-only inputs remain mandatory.
- Candidate selection used the 24-month classification and months 25-36 confirmation without frozen labels. The fourth year remained untouched until final evaluation.
- Selected refinement: **nonredundant_combined**.

## Original UNKNOWN failure causes

| Cause | Products |
|---|---:|
| insufficient_power_from_overlapping_significance_gates | 6 |
| weak_or_overlapping_seasonal_effect | 2 |
| no_sales_control | 1 |

## Final 36-month comparison

| Method | Accuracy | Coverage | Covered accuracy | UNKNOWN | Seasonal precision | False seasonal | Fourth-year confirmation |
|---|---:|---:|---:|---:|---:|---:|---:|
| original_evidence_gated | 62.50% | 62.50% | 100.00% | 37.50% | 100.00% | 0 | 88.89% |
| simple_baseline | 91.67% | 95.83% | 95.65% | 4.17% | 100.00% | 0 | 66.67% |
| refined | 87.50% | 87.50% | 100.00% | 12.50% | 100.00% | 0 | 66.67% |

## Class-level refined confusion matrix

| Actual | SUMMER | RAINY | NEUTRAL | UNKNOWN |
|---|---:|---:|---:|---:|
| SUMMER | 8 | 0 | 0 | 0 |
| RAINY | 0 | 7 | 0 | 1 |
| NEUTRAL | 0 | 0 | 6 | 2 |

## Baseline audit

- Substantive classification errors: 1.
- Intentional no-sales abstentions counted as benchmark errors: 1.
- The raw-season baseline does not detrend, does not require repeatability, and has no internal chronological generalization gate; it is therefore more exposed to trend/partial-cycle confounding and reversals despite its higher synthetic accuracy.
- Constructed monotonic-trend diagnostic: baseline returned RAINY at p=0.0095, while original and refined returned UNKNOWN.
- Constructed reversal diagnostic: baseline returned NEUTRAL; original and refined preserved UNKNOWN for the direction reversal.

## Conclusion

The refinement improves the conservative method's coverage, but it is not genuinely better than the simple baseline on this synthetic benchmark. Retain the original conservative method for advisory use, or retain the baseline only as a transparent comparison; do not activate automatic labels.

## Limitations

- The benchmark labels encode frozen simulation hypotheses, not validated real-store seasonal relationships.
- Stock availability is unknown, so observed zero sales cannot be proven to represent zero demand.
- The small 24-product benchmark yields wide uncertainty for error-rate comparisons.
- The refined policy was selected without labels, but all final comparisons remain synthetic evidence only.
- No existing classification, forecast, replenishment result, Supabase record, or Flutter screen is changed.
