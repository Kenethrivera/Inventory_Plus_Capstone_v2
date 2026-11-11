from __future__ import annotations

import json
from pathlib import Path

from app.classification import ClassificationConfidence, HardwareProductClassifier


ROOT = Path(__file__).resolve().parent
DATASET = ROOT / "tests" / "fixtures" / "hardware_seasonal_hierarchy_cases.json"
OUTPUT_JSON = ROOT / "simulation_reports" / "seasonal_hierarchy_evaluation.json"
OUTPUT_MARKDOWN = ROOT / "simulation_reports" / "SEASONAL_HIERARCHY_EVALUATION.md"


def evaluate() -> dict[str, object]:
    dataset = json.loads(DATASET.read_text(encoding="utf-8"))
    classifier = HardwareProductClassifier.load_default(semantic_mode="disabled")
    rows: list[dict[str, object]] = []
    for case in dataset["cases"]:
        result = classifier.classify(
            product_name=case["name"],
            category=case["category"],
            description=case["description"],
        )
        type_correct = result.identified_product_type == case["expected_type"]
        seasonal_correct = (
            result.seasonal_relevance.value == case["expected_relevance"]
        )
        match_type_correct = (
            result.seasonal_match_type.value == case["expected_match_type"]
        )

        gemini_resolver_consistent: bool | None = None
        if case["expected_type"] != "unknown":
            validated = classifier.result_from_validated_taxonomy_identity(
                product_name=case["name"],
                product_type=case["expected_type"],
                confidence=ClassificationConfidence.MEDIUM,
                identification_explanation="Test validated identity.",
                method="gemini_ai_taxonomy_validated",
            )
            gemini_resolver_consistent = (
                validated.seasonal_relevance == result.seasonal_relevance
                and validated.seasonal_match_type == result.seasonal_match_type
                and validated.seasonal_evidence_level
                == result.seasonal_evidence_level
                and validated.evidence == result.evidence
            )

        rows.append(
            {
                "id": case["id"],
                "product_name": case["name"],
                "expected_type": case["expected_type"],
                "predicted_type": result.identified_product_type,
                "expected_relevance": case["expected_relevance"],
                "predicted_relevance": result.seasonal_relevance.value,
                "expected_match_type": case["expected_match_type"],
                "predicted_match_type": result.seasonal_match_type.value,
                "seasonal_evidence_level": result.seasonal_evidence_level.value,
                "seasonal_hierarchy": list(result.seasonal_hierarchy),
                "supporting_evidence": [
                    {
                        "title": source.title,
                        "url": source.url,
                        "scope": source.scope,
                    }
                    for source in result.evidence
                ],
                "type_correct": type_correct,
                "seasonal_correct": seasonal_correct,
                "match_type_correct": match_type_correct,
                "gemini_resolver_consistent": gemini_resolver_consistent,
                "incorrect_inheritance": (
                    result.seasonal_match_type.value
                    == "inherited_industry_activity"
                    and (
                        case["expected_match_type"]
                        != "inherited_industry_activity"
                        or not seasonal_correct
                    )
                ),
                "basis": case["basis"],
            }
        )

    directional = [
        row for row in rows if row["predicted_relevance"] in {"dry", "rainy"}
    ]
    metrics = {
        "case_count": len(rows),
        "product_identification_accuracy": sum(
            row["type_correct"] for row in rows
        )
        / len(rows),
        "seasonal_classification_accuracy": sum(
            row["seasonal_correct"] for row in rows
        )
        / len(rows),
        "evidence_basis_accuracy": sum(
            row["match_type_correct"] for row in rows
        )
        / len(rows),
        "directional_evidence_coverage": (
            sum(bool(row["supporting_evidence"]) for row in directional)
            / len(directional)
            if directional
            else 0.0
        ),
        "overall_documented_evidence_coverage": sum(
            bool(row["supporting_evidence"]) for row in rows
        )
        / len(rows),
        "incorrect_seasonal_inheritance_count": sum(
            row["incorrect_inheritance"] for row in rows
        ),
        "seasonal_unknown_rate": sum(
            row["predicted_relevance"] == "unknown" for row in rows
        )
        / len(rows),
        "product_unknown_rate": sum(
            row["predicted_type"] == "unknown" for row in rows
        )
        / len(rows),
        "gemini_resolver_consistency": sum(
            row["gemini_resolver_consistent"] is True
            for row in rows
            if row["gemini_resolver_consistent"] is not None
        )
        / sum(
            row["gemini_resolver_consistent"] is not None for row in rows
        ),
    }
    return {
        "dataset_version": dataset["dataset_version"],
        "labeling_note": dataset["labeling_note"],
        "classifier_version": classifier.version,
        "metrics": metrics,
        "cases": rows,
    }


def _percent(value: object) -> str:
    return f"{float(value) * 100:.2f}%"


def write_report(report: dict[str, object]) -> None:
    metrics = report["metrics"]
    rows = report["cases"]
    assert isinstance(metrics, dict) and isinstance(rows, list)
    lines = [
        "# Hierarchical Seasonal Knowledge Evaluation",
        "",
        str(report["labeling_note"]),
        "",
        f"Classifier: `{report['classifier_version']}`",
        "",
        "| Metric | Result |",
        "|---|---:|",
        f"| Cases | {metrics['case_count']} |",
        f"| Product-identification accuracy | {_percent(metrics['product_identification_accuracy'])} |",
        f"| Seasonal-classification accuracy | {_percent(metrics['seasonal_classification_accuracy'])} |",
        f"| Evidence-basis accuracy | {_percent(metrics['evidence_basis_accuracy'])} |",
        f"| Directional evidence coverage | {_percent(metrics['directional_evidence_coverage'])} |",
        f"| Overall documented-evidence coverage | {_percent(metrics['overall_documented_evidence_coverage'])} |",
        f"| Incorrect seasonal inheritance | {metrics['incorrect_seasonal_inheritance_count']} |",
        f"| Seasonal UNKNOWN rate | {_percent(metrics['seasonal_unknown_rate'])} |",
        f"| Product UNKNOWN rate | {_percent(metrics['product_unknown_rate'])} |",
        f"| Gemini/local resolver consistency | {_percent(metrics['gemini_resolver_consistency'])} |",
        "",
        "Directional evidence coverage requires every dry/rainy result to carry at least one local cited source. It does not measure retail-demand accuracy.",
        "",
        "## Case results and supporting relationships",
        "",
        "| Product | Type | Relevance | Basis | Evidence | Outcome |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        evidence = row["supporting_evidence"]
        assert isinstance(evidence, list)
        titles = "; ".join(str(source["title"]) for source in evidence) or "None"
        correct = (
            row["type_correct"]
            and row["seasonal_correct"]
            and row["match_type_correct"]
        )
        lines.append(
            f"| {row['product_name']} | {row['predicted_type']} | "
            f"{row['predicted_relevance']} | {row['predicted_match_type']} | "
            f"{titles} | {'PASS' if correct else 'FAIL'} |"
        )
    lines.extend(
        [
            "",
            "## Evidence boundaries",
            "",
            "- Product-specific relationships take priority over inherited activity groups.",
            "- The construction relationship inherits from Philippine climatology plus rainfall-related disruption to outdoor construction work; it is not proof that a specific SKU sells more.",
            "- Provisional leak-repair relationships remain product-specific domain assumptions, not verified demand effects.",
            "- General tools, poultry netting, and products without a supported relationship remain UNKNOWN.",
            "- No multiplier, percentage, forecast, replenishment value, or database write is produced.",
            "- Classification is recomputed from the loaded knowledge-base version and is not persisted on a product. A deployed knowledge-base update is used after the backend reloads.",
        ]
    )
    OUTPUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_JSON.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    OUTPUT_MARKDOWN.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    evaluation = evaluate()
    write_report(evaluation)
    print(json.dumps(evaluation["metrics"], indent=2))
