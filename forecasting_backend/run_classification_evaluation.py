from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Iterable

from app.classification import HardwareProductClassifier


ROOT = Path(__file__).resolve().parent
REGRESSION_DATASET = (
    ROOT / "tests" / "fixtures" / "hardware_classification_cases.json"
)
SAFETY_VALIDATION_DATASET = (
    ROOT / "tests" / "fixtures" / "hardware_classification_holdout_cases.json"
)
FINAL_HOLDOUT_DATASET = (
    ROOT
    / "tests"
    / "fixtures"
    / "hardware_classification_final_holdout_v2_cases.json"
)
SECONDARY_SAFETY_VALIDATION_DATASET = (
    ROOT
    / "tests"
    / "fixtures"
    / "hardware_classification_final_holdout_cases.json"
)
OUTPUT_JSON = ROOT / "simulation_reports" / "hardware_classification_accuracy.json"
OUTPUT_MARKDOWN = ROOT / "simulation_reports" / "HARDWARE_CLASSIFICATION_REPORT.md"


def _macro_precision_recall(
    expected: Iterable[str], predicted: Iterable[str]
) -> tuple[float, float]:
    expected_values = list(expected)
    predicted_values = list(predicted)
    labels = sorted(set(expected_values) | set(predicted_values))
    precision: list[float] = []
    recall: list[float] = []
    for label in labels:
        true_positive = sum(
            actual == label and guess == label
            for actual, guess in zip(expected_values, predicted_values)
        )
        false_positive = sum(
            actual != label and guess == label
            for actual, guess in zip(expected_values, predicted_values)
        )
        false_negative = sum(
            actual == label and guess != label
            for actual, guess in zip(expected_values, predicted_values)
        )
        precision.append(
            true_positive / (true_positive + false_positive)
            if true_positive + false_positive
            else 0.0
        )
        recall.append(
            true_positive / (true_positive + false_negative)
            if true_positive + false_negative
            else 0.0
        )
    return sum(precision) / len(precision), sum(recall) / len(recall)


def _evaluate_dataset(
    *, classifier: HardwareProductClassifier, path: Path
) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows: list[dict[str, object]] = []
    for case in payload["cases"]:
        result = classifier.classify(
            product_name=case["name"],
            category=case["category"],
            description=case["description"],
        )
        type_correct = result.identified_product_type == case["expected_type"]
        seasonal_correct = (
            result.seasonal_relevance.value == case["expected_relevance"]
        )
        rows.append(
            {
                "id": case["id"],
                "product_name": case["name"],
                "category": case["category"],
                "expected_type": case["expected_type"],
                "predicted_type": result.identified_product_type,
                "expected_relevance": case["expected_relevance"],
                "predicted_relevance": result.seasonal_relevance.value,
                "identification_confidence": result.identification_confidence.value,
                "identification_method": result.identification_method,
                "seasonal_evidence_level": result.seasonal_evidence_level.value,
                "type_correct": type_correct,
                "seasonal_correct": seasonal_correct,
                "abstained": result.is_unknown,
                "clarification_needed": result.clarification_needed,
                "label_basis": case["basis"],
            }
        )

    count = len(rows)
    type_precision, type_recall = _macro_precision_recall(
        (str(row["expected_type"]) for row in rows),
        (str(row["predicted_type"]) for row in rows),
    )
    expected_known = [row for row in rows if row["expected_type"] != "unknown"]
    expected_unknown = [row for row in rows if row["expected_type"] == "unknown"]
    failures = [row for row in rows if not row["type_correct"]]
    false_high_confidence = [
        row
        for row in failures
        if row["identification_confidence"] == "high"
    ]
    false_accepted_unknowns = [
        row for row in expected_unknown if row["predicted_type"] != "unknown"
    ]
    false_abstentions = [
        row for row in expected_known if row["predicted_type"] == "unknown"
    ]
    metrics = {
        "case_count": count,
        "expected_known_count": len(expected_known),
        "expected_unknown_count": len(expected_unknown),
        "product_type_accuracy": sum(bool(row["type_correct"]) for row in rows)
        / count,
        "product_type_macro_precision": type_precision,
        "product_type_macro_recall": type_recall,
        "known_item_accuracy": (
            sum(bool(row["type_correct"]) for row in expected_known)
            / len(expected_known)
            if expected_known
            else 0.0
        ),
        "unknown_abstention_accuracy": (
            sum(bool(row["type_correct"]) for row in expected_unknown)
            / len(expected_unknown)
            if expected_unknown
            else 0.0
        ),
        "unknown_output_rate": sum(bool(row["abstained"]) for row in rows)
        / count,
        "false_high_confidence_count": len(false_high_confidence),
        "false_accepted_unknown_count": len(false_accepted_unknowns),
        "false_abstention_count": len(false_abstentions),
        "failure_count": len(failures),
        "identification_methods": dict(
            Counter(str(row["identification_method"]) for row in rows)
        ),
    }
    return {
        "dataset_version": payload["dataset_version"],
        "labeling_note": payload["labeling_note"],
        "metrics": metrics,
        "failures": failures,
        "cases": rows,
    }


def evaluate() -> dict[str, object]:
    classifier = HardwareProductClassifier.load_default(semantic_mode="required")
    return {
        "classifier_version": classifier.version,
        "embedding_model": "sentence-transformers/all-MiniLM-L6-v2",
        "regression": _evaluate_dataset(
            classifier=classifier,
            path=REGRESSION_DATASET,
        ),
        "safety_validation": _evaluate_dataset(
            classifier=classifier,
            path=SAFETY_VALIDATION_DATASET,
        ),
        "secondary_safety_validation": _evaluate_dataset(
            classifier=classifier,
            path=SECONDARY_SAFETY_VALIDATION_DATASET,
        ),
        "unseen_holdout": _evaluate_dataset(
            classifier=classifier,
            path=FINAL_HOLDOUT_DATASET,
        ),
    }


def _percent(value: object) -> str:
    return f"{float(value) * 100:.2f}%"


def _metrics_table(metrics: dict[str, object]) -> list[str]:
    return [
        "| Metric | Result |",
        "|---|---:|",
        f"| Cases | {metrics['case_count']} |",
        f"| Product-type accuracy | {_percent(metrics['product_type_accuracy'])} |",
        f"| Product-type macro precision | {_percent(metrics['product_type_macro_precision'])} |",
        f"| Product-type macro recall | {_percent(metrics['product_type_macro_recall'])} |",
        f"| Known-item accuracy | {_percent(metrics['known_item_accuracy'])} |",
        f"| UNKNOWN abstention accuracy | {_percent(metrics['unknown_abstention_accuracy'])} |",
        f"| UNKNOWN output rate | {_percent(metrics['unknown_output_rate'])} |",
        f"| False high-confidence matches | {metrics['false_high_confidence_count']} |",
        f"| False accepted UNKNOWN cases | {metrics['false_accepted_unknown_count']} |",
        f"| False abstentions on known items | {metrics['false_abstention_count']} |",
        f"| Total failures | {metrics['failure_count']} |",
    ]


def _case_table(rows: list[dict[str, object]]) -> list[str]:
    lines = [
        "| Product | Category | Expected | Predicted | Confidence | Method | Outcome |",
        "|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        outcome = (
            "UNKNOWN"
            if row["abstained"] and row["type_correct"]
            else "CORRECT"
            if row["type_correct"]
            else "FAIL"
        )
        lines.append(
            f"| {row['product_name']} | {row['category'] or '-'} | "
            f"{row['expected_type']} | {row['predicted_type']} | "
            f"{row['identification_confidence']} | {row['identification_method']} | "
            f"{outcome} |"
        )
    return lines


def write_report(report: dict[str, object]) -> None:
    regression = report["regression"]
    safety_validation = report["safety_validation"]
    secondary_safety_validation = report["secondary_safety_validation"]
    holdout = report["unseen_holdout"]
    assert isinstance(regression, dict)
    assert isinstance(safety_validation, dict)
    assert isinstance(secondary_safety_validation, dict)
    assert isinstance(holdout, dict)
    regression_metrics = regression["metrics"]
    safety_metrics = safety_validation["metrics"]
    secondary_safety_metrics = secondary_safety_validation["metrics"]
    holdout_metrics = holdout["metrics"]
    assert isinstance(regression_metrics, dict)
    assert isinstance(safety_metrics, dict)
    assert isinstance(secondary_safety_metrics, dict)
    assert isinstance(holdout_metrics, dict)
    holdout_cases = holdout["cases"]
    failures = holdout["failures"]
    assert isinstance(holdout_cases, list)
    assert isinstance(failures, list)

    lines = [
        "# Hardware Classification Evaluation",
        "",
        f"Classifier: `{report['classifier_version']}`  ",
        f"Embedding model: `{report['embedding_model']}`  ",
        "Generalization: local ONNX pretrained embeddings plus typo-tolerant lexical similarity over a closed hardware taxonomy.",
        "",
        "## Unseen holdout",
        "",
        str(holdout["labeling_note"]),
        "",
        *_metrics_table(holdout_metrics),
        "",
        "### Specific unseen failures",
        "",
    ]
    if failures:
        lines.extend(_case_table(failures))
    else:
        lines.append("No holdout product-type failures were observed.")
    lines.extend(
        [
            "",
            "### All unseen holdout results",
            "",
            *_case_table(holdout_cases),
            "",
            "## Safety-validation set",
            "",
            "This earlier unseen set exposed an unsafe generic `cement` exact alias and ambiguous one-word matches. Those safety issues were corrected before the final holdout was authored; this set is therefore reported as validation, not as the final independent estimate.",
            "",
            *_metrics_table(safety_metrics),
            "",
            "A second safety-validation set found additional ambiguous generic nouns (`fitting`, `cutter`, `reducer`, and zinc-coating text without a material). Context guards were tightened before the final holdout.",
            "",
            *_metrics_table(secondary_safety_metrics),
            "",
            "## Original regression set",
            "",
            str(regression["labeling_note"]),
            "",
            *_metrics_table(regression_metrics),
            "",
            "## Runtime, cost, and operational limits",
            "",
            "- `fastembed==0.9.1` runs `sentence-transformers/all-MiniLM-L6-v2` locally through ONNX Runtime. There is no per-request API charge and no product text is sent to an AI service.",
            "- The model is approximately 90 MB. Its first generalized classification downloads and caches model files from Hugging Face; later classifications use the local cache.",
            "- Exact deterministic rules run first and do not load the model. Generalized results are capped at medium confidence; only deterministic matches can be high confidence.",
            "- If the model cannot load, `auto` runtime mode falls back to the same closed taxonomy with lexical typo matching. The result exposes which method was used.",
            "- Embedding similarity is not proof of product identity. Close candidates, missing required context, and low scores return UNKNOWN with a clarification request.",
            "- The taxonomy bounds every output type. Adding a genuinely new product family requires a reviewed taxonomy update; the model cannot invent labels.",
            "- Generalized product matches always return seasonal relevance UNKNOWN and insufficient seasonal evidence. No generated text or similarity score becomes a demand multiplier.",
            "- English hardware terminology and short catalog text are the current scope. Filipino-language, brand-only, and highly specialized industrial items require additional independently labeled evaluation.",
            "- This classifier remains disconnected from forecasting and replenishment.",
            "",
            "## Manual acceptance expectations",
            "",
            "| Input | Expected behavior |",
            "|---|---|",
            "| `paint` | `architectural_paint`; medium identity confidence; seasonal UNKNOWN. |",
            "| `paint roller` | `paint_roller`; medium identity confidence; seasonal UNKNOWN. |",
            "| `galvanize steel` | `galvanized_steel_material`; does not assume sheet, pipe, or roofing; seasonal UNKNOWN. |",
            "| `TINER`, category `paint` | `paint_thinner`; medium identity confidence; seasonal UNKNOWN. |",
            "| `TINER` without paint/solvent context | UNKNOWN and request clarification. |",
            "| `Unknown Product XYZ` | UNKNOWN and request clarification. |",
        ]
    )
    OUTPUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_JSON.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    OUTPUT_MARKDOWN.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    result = evaluate()
    write_report(result)
    holdout_result = result["unseen_holdout"]
    assert isinstance(holdout_result, dict)
    print(json.dumps(holdout_result["metrics"], indent=2))
