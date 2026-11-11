# Hardware Classification Evaluation

Classifier: `hardware-seasonal-knowledge-v1+inventory-plus-hardware-taxonomy-v2`  
Embedding model: `sentence-transformers/all-MiniLM-L6-v2`  
Generalization: local ONNX pretrained embeddings plus typo-tolerant lexical similarity over a closed hardware taxonomy.

## Unseen holdout

This second final holdout was manually labeled after all rule, threshold, and ambiguity-guard changes were frozen. Its phrases are not copied from taxonomy aliases or prototypes, and no classifier tuning followed its execution.

| Metric | Result |
|---|---:|
| Cases | 40 |
| Product-type accuracy | 90.00% |
| Product-type macro precision | 86.18% |
| Product-type macro recall | 87.10% |
| Known-item accuracy | 86.67% |
| UNKNOWN abstention accuracy | 100.00% |
| UNKNOWN output rate | 35.00% |
| False high-confidence matches | 0 |
| False accepted UNKNOWN cases | 0 |
| False abstentions on known items | 4 |
| Total failures | 4 |

### Specific unseen failures

| Product | Category | Expected | Predicted | Confidence | Method | Outcome |
|---|---|---|---|---|---|---|
| fuzzy wall applicator cylinder | decorating | paint_roller | unknown | unknown | semantic_taxonomy | FAIL |
| flat bristled coating implement | decorating | paint_brush | unknown | unknown | semantic_taxonomy | FAIL |
| black iron plumbing tube | adhesives | steel_pipe | unknown | unknown | semantic_taxonomy | FAIL |
| rotating disc power grinder | powered machines | angle_grinder | unknown | unknown | semantic_taxonomy | FAIL |

### All unseen holdout results

| Product | Category | Expected | Predicted | Confidence | Method | Outcome |
|---|---|---|---|---|---|---|
| decorative emulsion for house interior | finishes | architectural_paint | architectural_paint | medium | semantic_taxonomy | CORRECT |
| fuzzy wall applicator cylinder | decorating | paint_roller | unknown | unknown | semantic_taxonomy | FAIL |
| flat bristled coating implement | decorating | paint_brush | unknown | unknown | semantic_taxonomy | FAIL |
| lacquer cleaning solvent | coating chemicals | paint_thinner | paint_thinner | medium | semantic_taxonomy | CORRECT |
| zinc protected iron raw stock | fabrication | galvanized_steel_material | galvanized_steel_material | medium | semantic_taxonomy | CORRECT |
| 16mm concrete reinforcement steel | structural | rebar | rebar | medium | semantic_taxonomy | CORRECT |
| ninety degree structural section | metal stock | steel_angle | steel_angle | medium | semantic_taxonomy | CORRECT |
| black iron plumbing tube | adhesives | steel_pipe | unknown | unknown | semantic_taxonomy | FAIL |
| multi layer wood sheet | boards | plywood | plywood | medium | semantic_taxonomy | CORRECT |
| kiln dried framing board | timber | lumber | lumber | medium | semantic_taxonomy | CORRECT |
| cement masonry cavity block | wall materials | concrete_hollow_block | concrete_hollow_block | medium | semantic_taxonomy | CORRECT |
| washed fine grains for render | aggregates | sand_aggregate | sand_aggregate | medium | semantic_taxonomy | CORRECT |
| 20mm crushed rocks | aggregates | gravel_aggregate | gravel_aggregate | medium | semantic_taxonomy | CORRECT |
| glazed wall finish piece | room finishes | ceramic_tile | ceramic_tile | medium | semantic_taxonomy | CORRECT |
| ceramic setting mortar | installation | tile_adhesive | tile_adhesive | medium | semantic_taxonomy | CORRECT |
| colored joint compound for ceramics | installation | tile_grout | tile_grout | medium | semantic_taxonomy | CORRECT |
| P180 abrasive paper | surface prep | sandpaper | sandpaper | medium | semantic_taxonomy | CORRECT |
| 4 inch thin grinder wheel | machine parts | cutting_disc | cutting_disc | medium | semantic_taxonomy | CORRECT |
| masonry boring tip 6mm | machine parts | drill_bit | drill_bit | medium | semantic_taxonomy | CORRECT |
| rotating disc power grinder | powered machines | angle_grinder | unknown | unknown | semantic_taxonomy | FAIL |
| motorized blade saw for plywood | powered machines | circular_saw | circular_saw | medium | semantic_taxonomy | CORRECT |
| 6011 arc electrode sticks | metal work | welding_electrode | welding_electrode | medium | semantic_taxonomy | CORRECT |
| single core insulated conductor | electrical | electrical_wire | electrical_wire | medium | semantic_taxonomy | CORRECT |
| resettable overcurrent protector | panel hardware | circuit_breaker | circuit_breaker | low | semantic_taxonomy | CORRECT |
| three gang plug receptacle | wiring | switch_or_outlet | switch_or_outlet | medium | semantic_taxonomy | CORRECT |
| luminous LED replacement lamp | lighting | light_bulb | light_bulb | medium | semantic_taxonomy | CORRECT |
| portable socket power lead | electrical | extension_cord | extension_cord | medium | semantic_taxonomy | CORRECT |
| plastic 45 elbow water connector | plumbing | pvc_fitting | pvc_fitting | medium | semantic_taxonomy | CORRECT |
| sink tap mixer spout | sanitary | faucet | faucet | medium | semantic_taxonomy | CORRECT |
| inline gate flow control | plumbing | plumbing_valve | plumbing_valve | medium | semantic_taxonomy | CORRECT |
| material | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| chemical | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| connector | hardware | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| tool | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| GI | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| roll | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| thinr | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| seal | hardware | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| NOVA-7 | general | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |
| Tablet Stand | Electronics | unknown | unknown | unknown | semantic_taxonomy | UNKNOWN |

## Safety-validation set

This earlier unseen set exposed an unsafe generic `cement` exact alias and ambiguous one-word matches. Those safety issues were corrected before the final holdout was authored; this set is therefore reported as validation, not as the final independent estimate.

| Metric | Result |
|---|---:|
| Cases | 66 |
| Product-type accuracy | 90.91% |
| Product-type macro precision | 91.16% |
| Product-type macro recall | 90.82% |
| Known-item accuracy | 88.89% |
| UNKNOWN abstention accuracy | 100.00% |
| UNKNOWN output rate | 27.27% |
| False high-confidence matches | 0 |
| False accepted UNKNOWN cases | 0 |
| False abstentions on known items | 6 |
| Total failures | 6 |

A second safety-validation set found additional ambiguous generic nouns (`fitting`, `cutter`, `reducer`, and zinc-coating text without a material). Context guards were tightened before the final holdout.

| Metric | Result |
|---|---:|
| Cases | 55 |
| Product-type accuracy | 81.82% |
| Product-type macro precision | 77.17% |
| Product-type macro recall | 78.26% |
| Known-item accuracy | 77.78% |
| UNKNOWN abstention accuracy | 100.00% |
| UNKNOWN output rate | 36.36% |
| False high-confidence matches | 0 |
| False accepted UNKNOWN cases | 0 |
| False abstentions on known items | 10 |
| Total failures | 10 |

## Original regression set

Labels were authored from ordinary hardware function and the cited Philippine climate/work mechanisms before classifier evaluation. They are not classifier-generated ground truth. Seasonal labels are potential relevance classes, not demand effects.

| Metric | Result |
|---|---:|
| Cases | 26 |
| Product-type accuracy | 100.00% |
| Product-type macro precision | 100.00% |
| Product-type macro recall | 100.00% |
| Known-item accuracy | 100.00% |
| UNKNOWN abstention accuracy | 100.00% |
| UNKNOWN output rate | 23.08% |
| False high-confidence matches | 0 |
| False accepted UNKNOWN cases | 0 |
| False abstentions on known items | 0 |
| Total failures | 0 |

## Runtime, cost, and operational limits

- `fastembed==0.9.1` runs `sentence-transformers/all-MiniLM-L6-v2` locally through ONNX Runtime. There is no per-request API charge and no product text is sent to an AI service.
- The model is approximately 90 MB. Its first generalized classification downloads and caches model files from Hugging Face; later classifications use the local cache.
- Exact deterministic rules run first and do not load the model. Generalized results are capped at medium confidence; only deterministic matches can be high confidence.
- If the model cannot load, `auto` runtime mode falls back to the same closed taxonomy with lexical typo matching. The result exposes which method was used.
- Embedding similarity is not proof of product identity. Close candidates, missing required context, and low scores return UNKNOWN with a clarification request.
- The taxonomy bounds every output type. Adding a genuinely new product family requires a reviewed taxonomy update; the model cannot invent labels.
- Generalized product matches always return seasonal relevance UNKNOWN and insufficient seasonal evidence. No generated text or similarity score becomes a demand multiplier.
- English hardware terminology and short catalog text are the current scope. Filipino-language, brand-only, and highly specialized industrial items require additional independently labeled evaluation.
- This classifier remains disconnected from forecasting and replenishment.

## Manual acceptance expectations

| Input | Expected behavior |
|---|---|
| `paint` | `architectural_paint`; medium identity confidence; seasonal UNKNOWN. |
| `paint roller` | `paint_roller`; medium identity confidence; seasonal UNKNOWN. |
| `galvanize steel` | `galvanized_steel_material`; does not assume sheet, pipe, or roofing; seasonal UNKNOWN. |
| `TINER`, category `paint` | `paint_thinner`; medium identity confidence; seasonal UNKNOWN. |
| `TINER` without paint/solvent context | UNKNOWN and request clarification. |
| `Unknown Product XYZ` | UNKNOWN and request clarification. |
