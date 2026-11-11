# Inventory Plus Stage 6A.2 robustness report

Generated 2026-11-05. All observations, supplier policies, costs, and outcomes
are synthetic. Nothing in this report establishes accuracy or stockout
reduction at the client's hardware store.

## Reproducibility

- Source HEAD: `d9970456a7a65a846be318b139300c685ffdbd6d`
- Fixed full-run seeds: `2606`, `4107`, `9917`
- Full seed configuration: 100 products, 2 locations, 731 days, 3 origins
  per product/location
- Reference artifact SHA-256 remained
  `94811DCFF930F8BA51B3CE24E3A4CB3638E044B0008227BF022A12C593B4977F`
- Stage 6A.2 full JSON SHA-256:
  `A5A02D4C2759D2ED9586D1C687879E268F33DF46DCF2412372756190FA03E503`
- Machine-readable reports: `stage6a2_small.json` and `stage6a2_full.json`

The repository contained uncommitted Stage 5 and Stage 6 work, so HEAD is
recorded as the base revision and the JSON contains the complete effective
simulation and model configurations needed to reproduce these runs.

## Forecast robustness across full-size seeds

WAPE and signed bias are ratios. Daily MAE is units per product/location/day;
28-day MAE is units per product/location/origin total.

| Candidate | Mean daily WAPE (range) | Daily bias range | Mean daily MAE | Mean 28-day WAPE (range) | 28-day bias range | Mean 28-day MAE |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Mean28 | 47.950% (46.660–49.994%) | -1.253–-0.576% | 1.386 | 14.441% (14.074–14.891%) | -1.253–-0.576% | 11.692 |
| LightGBM | 44.648% (43.563–46.792%) | +0.816–+1.708% | 1.290 | 13.198% (13.107–13.360%) | +0.816–+1.708% | 10.682 |
| Calibrated blend | 46.507% (45.395–48.528%) | -0.493–+0.650% | 1.344 | 13.090% (12.927–13.236%) | -0.493–+0.650% | 10.596 |
| Experimental intermittent guardrail | 45.696% (44.598–47.867%) | +2.945–+3.622% | 1.321 | 12.105% (11.966–12.251%) | +2.945–+3.622% | 9.799 |

Seed 2606 reproduced the original 28-day WAPE values exactly: Mean28
14.074%, LightGBM 13.128%, and blend 12.927%. No seed was omitted.

### Demand-frequency categories

Across the three seeds:

| Candidate | Fast WAPE range | Medium WAPE range | Slow WAPE range | Slow signed-bias range |
| --- | ---: | ---: | ---: | ---: |
| Mean28 | 37.574–42.334% | 59.815–62.639% | 139.156–145.804% | -2.392–+1.618% |
| LightGBM | 35.382–40.063% | 57.156–60.764% | 105.414–107.300% | -77.351–-77.314% |
| Calibrated blend | 36.099–40.875% | 58.562–62.124% | 136.991–144.043% | -9.899–+0.357% |
| Intermittent guardrail | 35.382–40.063% | 57.483–60.773% | 138.672–145.710% | -4.466–+0.540% |

Raw LightGBM's approximately -77.3% slow-demand bias reproduced in every full
seed. Its L1 objective is trained on sparse daily targets where zero is often
the conditional median. Recursive forecasting then feeds low predictions into
later lag features. Stockout-censored targets are correctly excluded, but that
further reduces usable examples for already sparse series. Percentage errors
are also magnified by the slow segment's small demand denominator.

The guardrail uses Mean28 when the recent nonzero share is at or below 50%. It
substantially reduced negative bias but increased slow-demand WAPE. It is an
underforecast/service-risk safeguard, not a universal accuracy improvement and
must remain a separately validated candidate.

Other full-seed segments are retained in the JSON. Notable patterns include:

- LightGBM demand-spike bias remained negative, approximately -5.8% to -7.5%.
- LightGBM stockout-censored-history WAPE ranged from 38.4% to 42.3%, with
  modest positive bias.
- New-product and high-seasonality results varied by seed; neither was
  consistently improved by the guardrail.

## Cold-start and launch-time evaluation

Configuration: seed 6152, 30 products, 2 locations, 40% configured late-launch
probability, launches between days 560 and 690. Launch-relative origins were
added at launch-1, launch+6, launch+27, and launch+83 when within bounds.

The 253 evaluated product/location decisions contained:

- 43 `no_history` origins.
- 37 `insufficient_history` origins.
- 80 provisional manual-estimate decisions.
- 36 Mean28-routed decisions.
- 22 LightGBM-routed decisions.
- 115 calibrated-blend-routed decisions.

The manual estimates prevented technical zero from being treated as confirmed
zero demand, but they were not automatically accurate:

| Segment | Manual-estimate WAPE | Signed bias | MAE |
| --- | ---: | ---: | ---: |
| `no_history` | 148.223% | +129.152% | 2.595 units/day |
| `insufficient_history` | 53.379% | +36.806% | 1.672 units/day |

This supports keeping manual values provisional, documented, and subject to
staff review. They are forecast metadata only and never become fabricated
historical transactions.

## Replenishment-policy comparison

Configuration: seed 6205, 12 products, 2 locations, 500 days, final 70-day
evaluation, 7-day review cadence. Every strategy received the same 5,790 units
of latent demand and the same supplier conditions.

No stockout penalty was introduced. Total assumed cost is holding cost plus
fixed ordering cost only.

| Strategy | Unmet units | Stockout days | Fulfilled | Avg inventory | Excess unit-days | Orders | Holding cost | Ordering cost | Total cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline moving-average order-up-to | 265 | 55 | 95.423% | 25.686 | 860.990 | 188 | 849.18 | 2,256.00 | 3,105.18 |
| Stage 5C + Mean28 | 255 | 51 | 95.596% | 27.157 | 895.713 | 189 | 897.82 | 2,268.00 | 3,165.82 |
| Stage 5C + LightGBM | 261 | 66 | 95.492% | 28.315 | 798.417 | 182 | 936.10 | 2,184.00 | 3,120.10 |
| Stage 5C + calibrated blend | 251 | 56 | 95.665% | 27.642 | 1,015.782 | 183 | 913.84 | 2,196.00 | 3,109.84 |

The blend had the fewest unmet units but not the fewest stockout days or lowest
cost. Category outcomes explain the conflict:

- Slow: LightGBM had 12 unmet units and 11 stockout days; Mean28 and blend had
  zero.
- Medium: blend had 88 unmet units versus baseline 80 and Mean28 74.
- Fast: blend had 163 unmet units versus baseline 184, Mean28 181, and
  LightGBM 166.

Seven early review dates fell back from LightGBM/blend to Mean28. The JSON
records every actual forecast model count and every category metric.

## Sensitivity and stress results

| Stress | Key result |
| --- | --- |
| Short lead, stable demand, 3-day review | All policies fulfilled 100%; costs ranged 781.96–788.70. Forecast choice had no availability effect. |
| Long/variable lead, low safety, 14-day review | Every policy had 92 unmet units, 18 stockout days, and a 5-day maximum run. Supply protection dominated forecast choice. |
| High safety stock | Every policy fulfilled 100%; higher average inventory and costs absorbed forecast differences. |
| Large MOQ/pack, constrained capacity | Every policy had 77 unmet units, 35 stockout days, and a 6-day maximum run. All models had -100% slow-demand bias in this realization. |
| Demand spike/variability stress | Mean28 had 52 unmet units, baseline 63, blend 64, and LightGBM 74. Better normal-run LightGBM WAPE did not transfer to this inventory outcome. |
| Extended supplier delays | Every policy had 10 unmet units and 2 stockout days. Lead-time/delay constraints dominated model choice. |

The JSON saves the exact lead-time ranges, delivery probabilities, maximum
delays, review periods, safety-stock days, MOQ/pack options, variability,
spike probability, opening-stock coverage, per-policy costs, and category
outcomes for every stress.

## Recommended safeguards and selection rules

1. Never select a model using aggregate WAPE alone. Require rolling-origin
   validation for the same product/location and its demand-frequency segment.
2. Disqualify raw LightGBM for intermittent series when adequately sized
   historical validation shows material negative bias; use validated blend or
   Mean28 instead.
3. Treat the 50% nonzero-share guardrail as experimental until its positive
   aggregate bias and higher intermittent WAPE are acceptable for the chosen
   service objective.
4. Keep Mean28 fallback whenever ML training or calibration is unavailable.
5. Keep manual estimates provisional with rationale, unit, source, timestamp,
   and human approval. Never convert them into sales history.
6. Evaluate replenishment policy with supplier constraints and service/cost
   outcomes; forecasting rank alone must not choose the ordering policy.
7. Return `NEEDS_REVIEW` when canonical lead time, safety stock, inbound,
   backorder, capacity, or conversion inputs are absent.

## Verification and limitations

- New Stage 6A.2 tests: 4 passed.
- Complete Python regression suite: 93 passed.
- Small profile completed before the full profile.
- Full report contains all three seeds, 60 cold-start product/location series,
  24 policy-comparison series, and six stress configurations.
- Stage 5A live Supabase behavioral verification remains pending.
- Canonical production supplier, replenishment, availability, and safety-stock
  data remain unavailable.
- No Flutter, POS, production Supabase, inventory mutation, or purchase-order
  behavior was changed.

Stage 6A.2 is sufficient to proceed to a read-only, isolated Stage 6B
integration exercise. It is not evidence of production readiness, actual store
accuracy, or operational stockout reduction.
