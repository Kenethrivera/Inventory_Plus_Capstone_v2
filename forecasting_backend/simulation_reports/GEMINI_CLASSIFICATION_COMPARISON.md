# Existing Classifier vs Gemini AI

This second final holdout was manually labeled after all rule, threshold, and ambiguity-guard changes were frozen. Its phrases are not copied from taxonomy aliases or prototypes, and no classifier tuning followed its execution.

Both engines received only name, category, and description. Expected labels and label rationales were never included in Gemini prompts. No classifier tuning was performed during or after this comparison.

Dataset: `unseen-hardware-final-holdout-v2`  
Existing: `hardware-seasonal-knowledge-v1+inventory-plus-hardware-taxonomy-v3`  
Gemini: `gemini-validated-v1+gemini-3.5-flash-lite+hardware-seasonal-knowledge-v1+inventory-plus-hardware-taxonomy-v3`

| Metric | Existing rules + MiniLM | Gemini AI + local validation |
|---|---:|---:|
| Cases | 40 | 40 |
| Product-type accuracy | 90.00% | 95.00% |
| Known-item accuracy | 86.67% | 96.67% |
| UNKNOWN abstention accuracy | 100.00% | 90.00% |
| UNKNOWN output rate | 35.00% | 25.00% |
| Incorrect classifications | 4 | 2 |
| False high-confidence matches | 0 | 0 |
| Seasonal-evidence correctness | 100.00% | 100.00% |

Seasonal-evidence correctness checks that UNKNOWN-labeled cases remain UNKNOWN with insufficient local evidence and no generated evidence sources.

## Post-evaluation safety correction

The unbiased run exposed that 'thinr' with only a general category was accepted as paint_thinner at medium confidence. After preserving the 95% result, the implementation was corrected to enforce the taxonomy's pre-existing required-context metadata locally. A targeted regression test now requires UNKNOWN without paint/solvent context and accepts TINER only when paint context is supplied. No post-correction holdout accuracy is claimed as independent.

## Existing classifier failures

| Product | Expected | Predicted | Confidence |
|---|---|---|---|
| fuzzy wall applicator cylinder | paint_roller | unknown | unknown |
| flat bristled coating implement | paint_brush | unknown | unknown |
| black iron plumbing tube | steel_pipe | unknown | unknown |
| rotating disc power grinder | angle_grinder | unknown | unknown |

## Gemini classifier failures

| Product | Expected | Predicted | Confidence |
|---|---|---|---|
| black iron plumbing tube | steel_pipe | unknown | unknown |
| thinr | unknown | paint_thinner | medium |

## Interpretation limits

- This is a 40-case frozen holdout, not a production prevalence sample.
- Gemini output is nondeterministic despite temperature 0 and a fixed seed; repeated runs can differ.
- The backend caps unsupported Gemini high-confidence proposals and rejects every label outside the local taxonomy.
- Gemini supplies identity only. Seasonal relevance and evidence are resolved locally and no numerical seasonal adjustment is produced.
- Gemini adds network latency, API availability/rate-limit exposure, and usage cost. The existing classifier remains local after its model is cached.
- Neither classifier is connected to forecasting or replenishment.
