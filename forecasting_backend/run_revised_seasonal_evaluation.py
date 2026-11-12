from __future__ import annotations

import argparse
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.simulation.revised_seasonal_backtest import (
    HISTORY_WINDOWS,
    MODELS,
    RevisedSeasonalBacktester,
)


MODEL_LABELS = {
    "mean28": "Mean28",
    "existing_lightgbm": "Existing product-specific LightGBM",
    "unrestricted_ablation": "Unrestricted nonseasonal ablation",
    "unrestricted_seasonal": "Unrestricted seasonal",
    "related_ablation": "Related-activity nonseasonal ablation",
    "related_seasonal": "Related-activity seasonal",
}


def _jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _percent(value: object, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{float(value) * 100:.{digits}f}%"


def _percentage_points(value: object, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{float(value) * 100:.{digits}f} pp"


def _number(value: object, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{digits}f}"


def _stage21_reference(path: Path) -> dict[str, object]:
    source = json.loads(path.read_text(encoding="utf-8"))
    final = source["final_test"]
    return {
        "artifact": str(path),
        "population": source["evaluation_contract"]["product_count"],
        "maximum_training_calendar_days": source["evaluation_contract"][
            "maximum_training_calendar_days"
        ],
        "models": source["evaluation_contract"]["models"],
        "final_overall": final["overall_mixed_unit_diagnostic"],
        "final_by_group": final["by_seasonal_group"],
        "recommendation": source["recommendation"],
        "original_13_product_reference": source.get("original_benchmark_reference"),
    }


def _metric_table(
    *,
    title: str,
    by_model: dict[str, dict[str, dict[str, object]]],
    groups: list[str],
    models: list[str],
    group_label: str,
) -> list[str]:
    lines = [
        f"## {title}",
        "",
        f"| {group_label} | Model | MAE | WAPE | Bias | Actual | Predicted |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for group in groups:
        for model in models:
            metrics = by_model[model][group]
            lines.append(
                f"| {group} | {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
                f"{_number(metrics['actual_total'], 1)} | "
                f"{_number(metrics['predicted_total'], 1)} |"
            )
    lines.append("")
    return lines


def _render_report(report: dict[str, object]) -> str:
    contract = report["evaluation_contract"]
    selection = report["validation_selection"]
    final = report["selected_final_test"]
    recommendation = report["recommendation"]
    seasonal = selection["model"]
    ablation = selection["matched_ablation"]
    selected_models = ["mean28", "existing_lightgbm", ablation, seasonal]
    lines = [
        "# Stage 2.2 Revised Shared Seasonal Forecasting",
        "",
        "Status: offline experiment only. The active forecasting API and application "
        "model selection remain unchanged.",
        "",
        "## Recommendation",
        "",
        f"**{recommendation['decision']}**. Activation remains disabled.",
        "",
        f"Validation selected **{MODEL_LABELS[seasonal]}** with a "
        f"**{selection['history_window_days']}-day** maximum history window. "
        "The final test was not used for selection.",
        "",
        f"- Final WAPE gain versus matched ablation: "
        f"{_percentage_points(recommendation['final_wape_gain_vs_ablation'])}.",
        f"- Final WAPE gain versus existing product-specific LightGBM: "
        f"{_percentage_points(recommendation['final_wape_gain_vs_existing_lightgbm'])}.",
        f"- Never-sold false-positive check: "
        f"{recommendation['no_sales_false_positive_free']}.",
        "",
        "## Evaluation population",
        "",
        f"This evaluation contains exactly **{contract['population']['expanded_products_evaluated']} "
        "expanded synthetic products**: eight SUMMER, eight RAINY, and eight NEUTRAL. "
        "It does not include the original 13 products.",
        "",
        contract["population"]["reason"].capitalize() + ".",
        "",
        "The frozen original 13-product/676-day benchmark is retained by reference; it "
        "was not rerun or combined with the expanded population.",
        "",
        "## Stage 2.1 reference result",
        "",
        "The previous 1,095-day unrestricted pool produced the following frozen "
        "final-test comparison. Stage 2.2 does not overwrite it.",
        "",
        "| Group | Stage 2.1 ablation WAPE | Stage 2.1 seasonal WAPE | Seasonal gain |",
        "|---|---:|---:|---:|",
    ]
    stage21 = report["stage21_reference"]
    for group in ("SUMMER", "RAINY", "NEUTRAL"):
        values = stage21["final_by_group"][group]
        ablation_wape = values["shared_nonseasonal_ablation"]["wape"]
        seasonal_wape = values["shared_seasonal_lightgbm"]["wape"]
        lines.append(
            f"| {group} | {_percent(ablation_wape)} | {_percent(seasonal_wape)} | "
            f"{_percentage_points(ablation_wape - seasonal_wape)} |"
        )
    lines.extend(
        [
        "",
        "Stage 2.1 improved SUMMER but regressed RAINY and NEUTRAL. The controlled "
        "pool test below checks whether cross-activity transfer was responsible.",
        "",
        "## History-window audit",
        "",
        "All models used the same 18 validation origins and 18 final-test origins per "
        "window. Each target horizon is 28 days and every training series ends at the "
        "origin.",
        "",
        "| Window | Split | Observed history min-max | Model | WAPE | MAE | Bias |",
        "|---:|---|---|---|---:|---:|---:|",
        ]
    )
    for window in HISTORY_WINDOWS:
        for split_name in ("validation", "final_test"):
            split = report["by_history_window"][str(window)][split_name]
            observed = split["observed_training_calendar_days"]
            for model in MODELS:
                metrics = split["overall_mixed_unit_diagnostic"][model]
                lines.append(
                    f"| {window} | {split_name} | {observed['minimum']}-"
                    f"{observed['maximum']} | {MODEL_LABELS[model]} | "
                    f"{_percent(metrics['wape'])} | {_number(metrics['mae'])} | "
                    f"{_percent(metrics['signed_bias'])} |"
                )
    lines.extend(
        [
            "",
            "The 1,095-day setting is a maximum, not fabricated history. Early validation "
            "origins use only the history that chronologically exists; final-test origins "
            "have enough history to reach the cap.",
            "",
            "## Why unrestricted seasonality behaved unevenly",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["diagnosis"]["findings"])
    lines.extend(
        [
            "",
            "The controlled related-activity candidate changes only the training pool. "
            "Its feature set, parameters, origins, targets, and no-sales gate are identical "
            "to its matched ablation, so this does not strengthen the generator signal.",
            "",
            "## Selected final-test results by seasonal group",
            "",
            "| Group | Model | MAE | WAPE | Bias | Actual | Predicted |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
    )
    for group in ("SUMMER", "RAINY", "NEUTRAL"):
        for model in selected_models:
            metrics = final["by_seasonal_group"][group][model]
            lines.append(
                f"| {group} | {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
                f"{_number(metrics['actual_total'], 1)} | "
                f"{_number(metrics['predicted_total'], 1)} |"
            )
    lines.append("")

    lines.extend(
        _metric_table(
            title="Selected final-test results by compatible inventory unit",
            by_model=final["by_compatible_unit"],
            groups=sorted(final["by_compatible_unit"][seasonal]),
            models=selected_models,
            group_label="Unit",
        )
    )
    lines.extend(
        _metric_table(
            title="Selected final-test results by demand pattern",
            by_model=final["by_demand_pattern"],
            groups=sorted(final["by_demand_pattern"][seasonal]),
            models=selected_models,
            group_label="Pattern",
        )
    )
    lines.extend(
        _metric_table(
            title="Selected final-test seasonal transitions",
            by_model=final["seasonal_transitions"],
            groups=sorted(final["seasonal_transitions"][seasonal]),
            models=selected_models,
            group_label="Transition",
        )
    )

    lines.extend(
        [
            "## Selected final-test per-product accuracy",
            "",
            "| SKU | Model | MAE | WAPE | Bias | Actual | Predicted |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
    )
    for sku in sorted(final["by_product"][seasonal]):
        for model in selected_models:
            metrics = final["by_product"][model][sku]
            lines.append(
                f"| {sku} | {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
                f"{_number(metrics['actual_total'], 1)} | "
                f"{_number(metrics['predicted_total'], 1)} |"
            )
    lines.extend(
        [
            "",
            "A zero-actual no-sales control has undefined WAPE by design; its MAE and "
            "predicted total are the relevant false-positive checks. Genuine intermittent "
            "products retain their observed nonzero history and are not gated.",
            "",
            "## Pre-transition examples",
            "",
            "| Origin | SKU | Group | Actual next 28d | Mean28 | Existing LGBM | Selected seasonal |",
            "|---|---|---|---:|---:|---:|---:|",
        ]
    )
    for example in report["selected_transition_examples"]:
        predictions = example["predicted_totals"]
        lines.append(
            f"| {example['origin']} | {example['sku']} | "
            f"{example['seasonal_group']} | {_number(example['target_actual'], 1)} | "
            f"{_number(predictions.get('mean28'), 1)} | "
            f"{_number(predictions.get('existing_lightgbm'), 1)} | "
            f"{_number(predictions.get(seasonal), 1)} |"
        )
    lines.extend(
        [
            "",
            "## Boundaries and interpretation",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["unchanged_boundaries"])
    lines.extend(
        [
            "- SUMMER/RAINY/NEUTRAL remain synthetic hypotheses, not verified hardware "
            "retail effects.",
            "- Mixed-unit overall totals are diagnostic only; product and compatible-unit "
            "metrics are the decision-safe comparisons.",
            "- No PAGASA calendar feature is itself a demand multiplier; numerical effects "
            "are learned only from past training targets.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the Stage 2.2 revised seasonal forecast experiment"
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        default=Path("simulation_reports/revised_seasonal_evaluation.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("simulation_reports/REVISED_SHARED_SEASONAL_REPORT.md"),
    )
    parser.add_argument(
        "--stage21-reference",
        type=Path,
        default=Path("simulation_reports/expanded_seasonal_evaluation.json"),
    )
    parser.add_argument("--render-only", action="store_true")
    args = parser.parse_args()

    if args.render_only:
        report = json.loads(args.json_output.read_text(encoding="utf-8"))
    else:
        raw = RevisedSeasonalBacktester().run()
        raw["stage21_reference"] = _stage21_reference(args.stage21_reference)
        report = _jsonable(raw)
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.write_text(_render_report(report), encoding="utf-8")
    print(json.dumps(report["recommendation"], indent=2, sort_keys=True))
    print(f"wrote {args.json_output}")
    print(f"wrote {args.report_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
