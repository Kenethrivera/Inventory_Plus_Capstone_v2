from __future__ import annotations

import json
import time
from collections import Counter
from pathlib import Path

from app.classification import GeminiHardwareClassifier, HardwareProductClassifier


ROOT = Path(__file__).resolve().parent
DATASET = (
    ROOT
    / "tests"
    / "fixtures"
    / "hardware_classification_final_holdout_v2_cases.json"
)
OUTPUT_JSON = (
    ROOT / "simulation_reports" / "gemini_classification_comparison.json"
)
OUTPUT_MARKDOWN = (
    ROOT / "simulation_reports" / "GEMINI_CLASSIFICATION_COMPARISON.md"
)
CHECKPOINT = ROOT / "simulation_reports" / ".gemini_holdout_checkpoint.json"


def _evaluate(
    classifier,
    cases: list[dict[str, object]],
    *,
    delay_seconds: float = 0,
    checkpoint: Path | None = None,
) -> dict[str, object]:
    cached: dict[str, dict[str, object]] = {}
    if checkpoint is not None and checkpoint.is_file():
        cached = json.loads(checkpoint.read_text(encoding="utf-8"))
    rows: list[dict[str, object]] = []
    for index, case in enumerate(cases, start=1):
        case_id = str(case["id"])
        result = cached.get(case_id)
        if result is None:
            if delay_seconds and cached:
                time.sleep(delay_seconds)
            classified = classifier.classify(
                product_name=str(case["name"]),
                category=str(case["category"]),
                description=str(case["description"]),
            )
            result = classified.to_dict()
            if checkpoint is not None:
                cached[case_id] = result
                checkpoint.parent.mkdir(parents=True, exist_ok=True)
                checkpoint.write_text(
                    json.dumps(cached, indent=2) + "\n", encoding="utf-8"
                )
        expected_type = str(case["expected_type"])
        expected_relevance = str(case["expected_relevance"])
        type_correct = result["identified_product_type"] == expected_type
        seasonal_correct = result["seasonal_relevance"] == expected_relevance
        evidence_correct = seasonal_correct and (
            expected_relevance != "unknown"
            or (
                result["seasonal_evidence_level"] == "insufficient"
                and not result["evidence"]
            )
        )
        rows.append(
            {
                "ordinal": index,
                "id": case["id"],
                "product_name": case["name"],
                "category": case["category"],
                "expected_type": expected_type,
                "predicted_type": result["identified_product_type"],
                "expected_relevance": expected_relevance,
                "predicted_relevance": result["seasonal_relevance"],
                "identification_confidence": result["identification_confidence"],
                "identification_method": result["identification_method"],
                "seasonal_evidence_level": result["seasonal_evidence_level"],
                "type_correct": type_correct,
                "seasonal_evidence_correct": evidence_correct,
                "is_unknown": result["is_unknown"],
                "label_basis": case["basis"],
            }
        )

    failures = [row for row in rows if not row["type_correct"]]
    expected_unknown = [row for row in rows if row["expected_type"] == "unknown"]
    expected_known = [row for row in rows if row["expected_type"] != "unknown"]
    return {
        "metrics": {
            "case_count": len(rows),
            "product_type_accuracy": sum(row["type_correct"] for row in rows)
            / len(rows),
            "known_item_accuracy": sum(row["type_correct"] for row in expected_known)
            / len(expected_known),
            "unknown_abstention_accuracy": sum(
                row["type_correct"] for row in expected_unknown
            )
            / len(expected_unknown),
            "incorrect_classification_count": len(failures),
            "unknown_output_rate": sum(row["is_unknown"] for row in rows)
            / len(rows),
            "false_high_confidence_count": sum(
                row["identification_confidence"] == "high" for row in failures
            ),
            "seasonal_evidence_correctness": sum(
                row["seasonal_evidence_correct"] for row in rows
            )
            / len(rows),
            "identification_methods": dict(
                Counter(str(row["identification_method"]) for row in rows)
            ),
        },
        "failures": failures,
        "cases": rows,
    }


def evaluate() -> dict[str, object]:
    payload = json.loads(DATASET.read_text(encoding="utf-8"))
    cases = payload["cases"]
    existing = HardwareProductClassifier.load_default(semantic_mode="required")
    gemini_knowledge = HardwareProductClassifier.load_default(
        semantic_mode="disabled"
    )
    gemini = GeminiHardwareClassifier.from_environment(
        knowledge_classifier=gemini_knowledge
    )
    return {
        "dataset_version": payload["dataset_version"],
        "labeling_note": payload["labeling_note"],
        "comparison_note": (
            "Both engines received only name, category, and description. Expected "
            "labels and label rationales were never included in Gemini prompts. No "
            "classifier tuning was performed during or after this comparison."
        ),
        "post_evaluation_safety_correction": (
            "The unbiased run exposed that 'thinr' with only a general category was "
            "accepted as paint_thinner at medium confidence. After preserving the "
            "95% result, the implementation was corrected to enforce the taxonomy's "
            "pre-existing required-context metadata locally. A targeted regression "
            "test now requires UNKNOWN without paint/solvent context and accepts "
            "TINER only when paint context is supplied. No post-correction holdout "
            "accuracy is claimed as independent."
        ),
        "existing_classifier_version": existing.version,
        "gemini_classifier_version": gemini.version,
        "existing": _evaluate(existing, cases),
        "gemini": _evaluate(
            gemini,
            cases,
            delay_seconds=4.25,
            checkpoint=CHECKPOINT,
        ),
    }


def _percent(value: object) -> str:
    return f"{float(value) * 100:.2f}%"


def _failure_table(rows: list[dict[str, object]]) -> list[str]:
    if not rows:
        return ["No product-type failures."]
    lines = [
        "| Product | Expected | Predicted | Confidence |",
        "|---|---|---|---|",
    ]
    for row in rows:
        lines.append(
            f"| {row['product_name']} | {row['expected_type']} | "
            f"{row['predicted_type']} | {row['identification_confidence']} |"
        )
    return lines


def write_report(report: dict[str, object]) -> None:
    existing = report["existing"]
    gemini = report["gemini"]
    assert isinstance(existing, dict) and isinstance(gemini, dict)
    existing_metrics = existing["metrics"]
    gemini_metrics = gemini["metrics"]
    assert isinstance(existing_metrics, dict) and isinstance(gemini_metrics, dict)
    lines = [
        "# Existing Classifier vs Gemini AI",
        "",
        str(report["labeling_note"]),
        "",
        str(report["comparison_note"]),
        "",
        f"Dataset: `{report['dataset_version']}`  ",
        f"Existing: `{report['existing_classifier_version']}`  ",
        f"Gemini: `{report['gemini_classifier_version']}`",
        "",
        "| Metric | Existing rules + MiniLM | Gemini AI + local validation |",
        "|---|---:|---:|",
        f"| Cases | {existing_metrics['case_count']} | {gemini_metrics['case_count']} |",
        f"| Product-type accuracy | {_percent(existing_metrics['product_type_accuracy'])} | {_percent(gemini_metrics['product_type_accuracy'])} |",
        f"| Known-item accuracy | {_percent(existing_metrics['known_item_accuracy'])} | {_percent(gemini_metrics['known_item_accuracy'])} |",
        f"| UNKNOWN abstention accuracy | {_percent(existing_metrics['unknown_abstention_accuracy'])} | {_percent(gemini_metrics['unknown_abstention_accuracy'])} |",
        f"| UNKNOWN output rate | {_percent(existing_metrics['unknown_output_rate'])} | {_percent(gemini_metrics['unknown_output_rate'])} |",
        f"| Incorrect classifications | {existing_metrics['incorrect_classification_count']} | {gemini_metrics['incorrect_classification_count']} |",
        f"| False high-confidence matches | {existing_metrics['false_high_confidence_count']} | {gemini_metrics['false_high_confidence_count']} |",
        f"| Seasonal-evidence correctness | {_percent(existing_metrics['seasonal_evidence_correctness'])} | {_percent(gemini_metrics['seasonal_evidence_correctness'])} |",
        "",
        "Seasonal-evidence correctness checks that UNKNOWN-labeled cases remain "
        "UNKNOWN with insufficient local evidence and no generated evidence sources.",
        "",
        "## Post-evaluation safety correction",
        "",
        str(report["post_evaluation_safety_correction"]),
        "",
        "## Existing classifier failures",
        "",
        *_failure_table(existing["failures"]),
        "",
        "## Gemini classifier failures",
        "",
        *_failure_table(gemini["failures"]),
        "",
        "## Interpretation limits",
        "",
        "- This is a 40-case frozen holdout, not a production prevalence sample.",
        "- Gemini output is nondeterministic despite temperature 0 and a fixed seed; repeated runs can differ.",
        "- The backend caps unsupported Gemini high-confidence proposals and rejects every label outside the local taxonomy.",
        "- Gemini supplies identity only. Seasonal relevance and evidence are resolved locally and no numerical seasonal adjustment is produced.",
        "- Gemini adds network latency, API availability/rate-limit exposure, and usage cost. The existing classifier remains local after its model is cached.",
        "- Neither classifier is connected to forecasting or replenishment.",
    ]
    OUTPUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_JSON.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    OUTPUT_MARKDOWN.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    result = evaluate()
    write_report(result)
    print(
        json.dumps(
            {
                "existing": result["existing"]["metrics"],
                "gemini": result["gemini"]["metrics"],
            },
            indent=2,
        )
    )
