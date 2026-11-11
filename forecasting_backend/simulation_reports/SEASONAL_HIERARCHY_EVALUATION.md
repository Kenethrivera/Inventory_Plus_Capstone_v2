# Hierarchical Seasonal Knowledge Evaluation

Acceptance labels were manually defined from the requested hierarchy and the cited PAGASA/PIDS evidence boundaries. They validate implementation behavior and are not an independent estimate of Philippine retail-demand accuracy.

Classifier: `hardware-seasonal-knowledge-v2+inventory-plus-hardware-taxonomy-v3`

| Metric | Result |
|---|---:|
| Cases | 12 |
| Product-identification accuracy | 91.67% |
| Seasonal-classification accuracy | 100.00% |
| Evidence-basis accuracy | 100.00% |
| Directional evidence coverage | 100.00% |
| Overall documented-evidence coverage | 58.33% |
| Incorrect seasonal inheritance | 0 |
| Seasonal UNKNOWN rate | 50.00% |
| Product UNKNOWN rate | 16.67% |
| Gemini/local resolver consistency | 100.00% |

Directional evidence coverage requires every dry/rainy result to carry at least one local cited source. It does not measure retail-demand accuracy.

## Case results and supporting relationships

| Product | Type | Relevance | Basis | Evidence | Outcome |
|---|---|---|---|---|---|
| Concrete Hollow Blocks | concrete_hollow_block | dry | inherited_industry_activity | PAGASA Climate of the Philippines; PIDS: Routine rainfall cuts Filipino work hours | PASS |
| Portland Cement | portland_cement | dry | product_specific | PAGASA Climate of the Philippines; PIDS: When Rain Falls, Work Slows | PASS |
| Metal roofing sheet | roofing_sheet | dry | product_specific | PAGASA Climate of the Philippines; PIDS: When Rain Falls, Work Slows | PASS |
| Waterproofing sealant | waterproofing_sealant | rainy | product_specific | PAGASA Climate of the Philippines | PASS |
| Chicken wire | poultry_netting | unknown | insufficient | None | PASS |
| General screwdriver | screwdriver | unknown | insufficient | None | PASS |
| Unknown Product XYZ | unknown | unknown | insufficient | None | PASS |
| 16mm deformed reinforcing bar | rebar | dry | inherited_industry_activity | PAGASA Climate of the Philippines; PIDS: Routine rainfall cuts Filipino work hours | PASS |
| Washed construction sand | sand_aggregate | dry | inherited_industry_activity | PAGASA Climate of the Philippines; PIDS: Routine rainfall cuts Filipino work hours | PASS |
| Paint roller | paint_roller | unknown | insufficient | None | PASS |
| THHN electrical wire | unknown | unknown | insufficient | None | FAIL |
| PVC Pipe | pvc_pipe | unknown | product_specific | PAGASA Climate of the Philippines; PIDS: When Rain Falls, Work Slows | PASS |

## Evidence boundaries

- Product-specific relationships take priority over inherited activity groups.
- The construction relationship inherits from Philippine climatology plus rainfall-related disruption to outdoor construction work; it is not proof that a specific SKU sells more.
- Provisional leak-repair relationships remain product-specific domain assumptions, not verified demand effects.
- General tools, poultry netting, and products without a supported relationship remain UNKNOWN.
- No multiplier, percentage, forecast, replenishment value, or database write is produced.
- Classification is recomputed from the loaded knowledge-base version and is not persisted on a product. A deployed knowledge-base update is used after the backend reloads.
