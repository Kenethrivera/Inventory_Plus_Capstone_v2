# Inventory Plus Stage 6A synthetic simulation report

Generated 2026-11-04. These are controlled synthetic results, not evidence of
accuracy or stockout reduction at the client's hardware store.

## Configuration

- Seed: `2606`
- Provenance: `synthetic_stage6a`
- Products: 100
- Locations: 2
- Product/location series: 200
- New-product product/location series: 19 (launches from 2024-02-06 through
  2024-06-16)
- Period: 2024-01-01 through 2025-12-31 (731 days)
- Forecast horizon: 28 days
- Evaluation: 3 chronological origins per series, 600 origins and 16,800 daily
  forecast points per candidate
- Inventory evaluation: final 180 days, 7-day review period
- Machine-readable result: `stage6a_100p_2l_24m_seed2606.json`

The Python configuration in the JSON records all demand, seasonality, launch,
lead-time, delivery-delay, return, cancellation, stock, MOQ, pack-size,
capacity, safety-stock, backorder, and cost assumptions.

## Forecast results

The daily metrics score each forecast date against future underlying net
customer demand. The total metrics score complete 28-day forecast totals.
WAPE and signed bias are ratios; MAE is in units.

| Candidate | Daily WAPE | Daily signed bias | Daily MAE | 28-day-total WAPE | 28-day-total MAE |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mean28 | 49.994% | -1.253% | 1.429 | 14.074% | 11.267 |
| LightGBM | 46.792% | +1.429% | 1.338 | 13.128% | 10.510 |
| Calibrated 50/50 blend | 48.528% | -0.105% | 1.387 | 12.927% | 10.349 |

All 600 evaluated origins used the requested model for each candidate. There
were no insufficient-history holdout origins because the configured evaluation
origins occurred long after the latest synthetic launch; cold-start behavior
was evaluated separately.

### Daily results by demand category

| Candidate | Category | WAPE | Signed bias | MAE |
| --- | --- | ---: | ---: | ---: |
| Mean28 | Fast | 42.334% | -1.567% | 2.665 |
| Mean28 | Medium | 61.570% | -0.433% | 1.307 |
| Mean28 | Slow | 145.618% | -0.292% | 0.350 |
| LightGBM | Fast | 40.063% | +3.018% | 2.522 |
| LightGBM | Medium | 59.698% | +5.889% | 1.267 |
| LightGBM | Slow | 107.300% | -77.314% | 0.258 |
| Calibrated blend | Fast | 40.875% | -0.236% | 2.573 |
| Calibrated blend | Medium | 60.481% | +1.425% | 1.284 |
| Calibrated blend | Slow | 140.743% | -9.899% | 0.338 |

LightGBM had the lowest daily WAPE, while the blend had the lowest WAPE for
28-day totals. The blend therefore did not universally outperform LightGBM.
Intermittent slow-demand series were the largest failure category, especially
LightGBM's negative signed bias.

## Inventory-policy comparison

Both strategies received the same 102,964 units of underlying demand and the
same supplier-delay scenario.

| Outcome | Stage 5C + Mean28 | Moving-average baseline |
| --- | ---: | ---: |
| Immediately fulfilled units | 101,142 | 101,039 |
| Immediately unmet units | 1,822 | 1,925 |
| Stockout days | 394 | 414 |
| Immediately fulfilled percentage | 98.230% | 98.130% |
| Average inventory | 29.236 | 28.766 |
| Excess inventory unit-days | 28,443.704 | 28,434.878 |
| Orders placed | 3,526 | 3,519 |
| Units ordered | 103,826 | 103,657 |
| Synthetic holding cost | 21,049.88 | 20,711.66 |
| Synthetic ordering cost | 42,312.00 | 42,228.00 |
| Ending backorders | 22 | 22 |

The Stage 5C strategy had 103 fewer immediately unmet units and 20 fewer
stockout days in this scenario, with slightly higher inventory, order count,
and assumed costs. This is a synthetic tradeoff, not an operational claim.

## Cold-start lifecycle

- Registration state: `no_history`; the technical zero remained explicitly
  unknown demand.
- A configured staff manual daily-demand estimate was used.
- Initial recommendation: `needs_review`.
- First insufficient-history review: 2024-01-01.
- First LightGBM-eligible review: 2024-03-25.
- First calibrated-blend-eligible review: 2024-05-20.
- Eligibility was recorded only when the requested candidate returned its own
  validated model name instead of Mean28 fallback. No model was selected merely
  because an arbitrary number of days elapsed.

## Verification

- New Stage 6A exact-answer tests: 9 passed.
- Complete Stage 5A–6A Python suite: 89 passed.
- Exact checks cover seeded reproducibility, configurable generation, latent
  demand versus fulfilled sales, chronology, inventory depletion, stockouts,
  backorders, supplier timing, metric arithmetic, and identical scenarios for
  candidate/baseline comparison.
- Existing Stage 5C tests cover inventory position, inbound orders, reservation
  double-count prevention, exact reorder quantities, MOQ/pack rounding,
  capacity conflicts, unit conversion, and cold-start review behavior.
- The full target run was executed twice with the same seed; its reported key
  metrics matched.

## Limitations and blockers

- All records, suppliers, policies, costs, and outcomes are synthetic.
- Historical sales are generated from a synthetic reference replenishment path.
- Slow/intermittent demand remains difficult and has high percentage error.
- Supplier and safety-stock assumptions are not canonical client records.
- Stage 5A live Supabase RPC behavioral verification remains pending until an
  isolated database is available.
- The unrelated GCash `payment_reference` history regression was not modified.
- No production credentials, Supabase rows, POS behavior, inventory mutation,
  purchase order, Flutter screen, or business workflow is used or changed by
  this simulation.

The isolated simulator is ready for further Stage 6 experimentation, but these
results do not establish production readiness or actual hardware-store
forecasting accuracy.
