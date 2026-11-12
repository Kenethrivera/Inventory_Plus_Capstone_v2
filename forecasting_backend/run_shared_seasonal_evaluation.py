from __future__ import annotations

import argparse
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.simulation.shared_seasonal_backtest import SharedSeasonalBacktester


MODEL_LABELS = {
    "mean28": "Mean28",
    "lightgbm": "Existing LightGBM",
    "calibrated_blend": "Calibrated blend",
    "seasonal_lightgbm": "Previous seasonal LightGBM",
    "shared_seasonal_lightgbm": "Shared seasonal LightGBM",
    "shared_nonseasonal_ablation": "Shared model without seasonal features",
}


def _jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _number(value: object, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{digits}f}"


def _percent(value: object, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{float(value) * 100:.{digits}f}"


def _metric_table(
    title: str,
    rows: dict[str, dict[str, object]],
    *,
    group_name: str,
) -> list[str]:
    lines = [
        f"## {title}",
        "",
        f"| Model | {group_name} | MAE | WAPE (%) | Bias (%) | Actual | Predicted |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for model in MODEL_LABELS:
        for group, metrics in sorted(rows[model].items()):
            lines.append(
                "| {model} | {group} | {mae} | {wape} | {bias} | {actual} | {predicted} |".format(
                    model=MODEL_LABELS[model],
                    group=group,
                    mae=_number(metrics["mae"]),
                    wape=_percent(metrics["wape"]),
                    bias=_percent(metrics["signed_bias"]),
                    actual=_number(metrics["actual_total"], 1),
                    predicted=_number(metrics["predicted_total"], 1),
                )
            )
    lines.append("")
    return lines


def _render_report(report: dict[str, object]) -> str:
    contract = report["evaluation_contract"]
    recommendation = report["recommendation"]
    comparison = report["seasonal_ablation_and_baseline_comparison"]
    lines = [
        "# Shared Philippine Seasonal LightGBM Evaluation",
        "",
        "Status: experimental; not connected to the normal forecasting API or replenishment.",
        "",
        "## Decision",
        "",
        f"**{recommendation['decision']}** for application integration.",
        "",
        "The decision is determined by the frozen acceptance rules in the runner. "
        "It is not a deployment switch; `activation_allowed` remains false.",
        "",
        "## Evaluation contract",
        "",
        f"- Dataset: {contract['dataset']}",
        f"- History: {contract['history_start']} through {contract['history_end']} "
        f"({contract['calendar_days']} calendar days)",
        f"- Products: {contract['products']}",
        f"- Rolling origins: {len(contract['origins'])}",
        f"- Horizon: {contract['horizon_days']} days at every origin",
        f"- Maximum training history: {contract['maximum_training_calendar_days']} days",
        f"- Product context: `{contract['shared_product_context_version']}`",
        "",
        "All six models use the same origins and target dates. Demand-pattern labels are "
        "used only after prediction for reporting. Future-known calendar features are "
        "allowed; future sales are not.",
        "",
        "## Overall comparison",
        "",
        "The overall row mixes inventory units and is therefore diagnostic. Product-level "
        "and compatible-unit tables are the decision-safe views.",
        "",
        "| Model | MAE | WAPE (%) | Bias (%) | Macro product WAPE (%) |",
        "|---|---:|---:|---:|---:|",
    ]
    for model in MODEL_LABELS:
        metric = report["overall_mixed_unit_diagnostic"][model]
        macro = report["macro_product_wape"][model]
        lines.append(
            f"| {MODEL_LABELS[model]} | {_number(metric['mae'])} | "
            f"{_percent(metric['wape'])} | {_percent(metric['signed_bias'])} | "
            f"{_percent(macro['macro_wape'])} |"
        )
    lines.extend(["", "## Seasonal-feature ablation", ""])
    lines.append(
        "Shared seasonal minus shared nonseasonal WAPE: "
        f"**{_percent(comparison['overall_shared_minus_ablation_wape'])} percentage points**."
    )
    lines.extend(
        [
            "",
            "| Transition | Shared seasonal WAPE | Ablation WAPE | Difference |",
            "|---|---:|---:|---:|",
        ]
    )
    for transition, values in sorted(
        comparison["transition_shared_vs_ablation"].items()
    ):
        lines.append(
            f"| {transition} | {_percent(values['shared_wape'])} | "
            f"{_percent(values['ablation_wape'])} | "
            f"{_percent(values['shared_minus_ablation_wape'])} |"
        )
    lines.append("")
    lines.extend(
        [
            "## Regression summary",
            "",
            "| Comparator | Products better | Products worse | Tied |",
            "|---|---:|---:|---:|",
        ]
    )
    for baseline in (
        "lightgbm",
        "seasonal_lightgbm",
        "shared_nonseasonal_ablation",
    ):
        values = comparison["by_baseline"][baseline]
        lines.append(
            f"| {MODEL_LABELS[baseline]} | {values['better_products']} | "
            f"{values['worse_products']} | {values['tied_products']} |"
        )
    lines.extend(
        [
            "",
            "Notable failures are visible rather than suppressed: the shared seasonal "
            "model's intermittent-low WAPE is "
            f"{_percent(report['by_demand_pattern']['shared_seasonal_lightgbm']['intermittent_low']['wape'])}, "
            "and it predicts "
            f"{_number(report['by_demand_pattern']['shared_seasonal_lightgbm']['no_sales']['predicted_total'], 1)} "
            "units across backtest points for the zero-sales product. These are "
            "unacceptable production regressions even though seven comparable products "
            "beat the existing per-product LightGBM.",
            "",
        ]
    )
    lines.extend(
        _metric_table(
            "Results by compatible inventory unit",
            report["by_compatible_unit"],
            group_name="Unit",
        )
    )
    lines.extend(
        _metric_table(
            "Results by Philippine season",
            report["by_season"],
            group_name="Season",
        )
    )
    lines.extend(
        _metric_table(
            "Results by demand pattern",
            report["by_demand_pattern"],
            group_name="Pattern",
        )
    )
    lines.extend(
        _metric_table(
            "Season-transition results",
            report["seasonal_transitions"],
            group_name="Transition",
        )
    )

    lines.extend(
        [
            "## Product-level accuracy",
            "",
            "| SKU | Model | MAE | WAPE (%) | Bias (%) |",
            "|---|---|---:|---:|---:|",
        ]
    )
    for sku in sorted(report["by_product"]["mean28"]):
        for model in MODEL_LABELS:
            metric = report["by_product"][model][sku]
            lines.append(
                f"| {sku} | {MODEL_LABELS[model]} | {_number(metric['mae'])} | "
                f"{_percent(metric['wape'])} | {_percent(metric['signed_bias'])} |"
            )
    lines.append("")

    lines.extend(
        [
            "## Transition anticipation examples",
            "",
            "These windows start after their forecast origin and cross into the seasonal "
            "boundary. The seasonal-minus-ablation value is the numeric attribution; no "
            "Gemini explanation or multiplier is used.",
            "",
            "| Origin | Product | Target | Recent 28 actual | Target actual | Shared seasonal | Ablation | Difference |",
            "|---|---|---|---:|---:|---:|---:|---:|",
        ]
    )
    for example in report["transition_anticipation_examples"]:
        predicted = example["predicted_totals"]
        lines.append(
            f"| {example['origin']} | {example['product']} | "
            f"{example['target_period'][0]} to {example['target_period'][1]} | "
            f"{_number(example['recent_28_day_actual_before_origin'], 1)} | "
            f"{_number(example['target_actual'], 1)} | "
            f"{_number(predicted['shared_seasonal_lightgbm'], 1)} | "
            f"{_number(predicted['shared_nonseasonal_ablation'], 1)} | "
            f"{_number(example['seasonal_minus_ablation'], 1)} |"
        )
    lines.append("")

    lines.extend(
        [
            "## Next 28-day experimental forecasts",
            "",
            "The complete daily series for every product is in the JSON artifact.",
            "Material influence requires both a product-level backtest WAPE gain of at "
            "least 0.5 percentage point and a 28-day difference of at least 5% versus "
            "ablation. This reporting threshold does not alter any forecast.",
            "",
            "| SKU | Product | Unit | 7-day total | 28-day total | Ablation total | Seasonal influence supported? | Evidence |",
            "|---|---|---|---:|---:|---:|---|---|",
        ]
    )
    for sku, forecast in sorted(report["next_28_day_forecasts"].items()):
        evidence = forecast["seasonal_evidence_status"]
        lines.append(
            f"| {sku} | {forecast['product_name']} | {forecast['unit']} | "
            f"{_number(forecast['total_next_7_days'], 1)} | "
            f"{_number(forecast['total_next_28_days'], 1)} | "
            f"{_number(forecast['nonseasonal_ablation_28_day_total'], 1)} | "
            f"{'yes' if forecast['seasonal_features_materially_influenced'] else 'no'} | "
            f"{evidence['match_type']}; {evidence['evidence_level']} |"
        )
    lines.append("")

    lines.extend(["## Acceptance checks", ""])
    lines.extend(
        [
            f"- Seasonal model beats pooled nonseasonal ablation overall: "
            f"{recommendation['seasonal_ablation_improved_overall']}",
            f"- Maintains/improves both transitions: "
            f"{recommendation['seasonal_ablation_improved_or_tied_both_transitions']}",
            f"- Product regression balance versus existing LightGBM acceptable: "
            f"{recommendation['product_regression_balance_vs_existing_lightgbm_acceptable']}",
            f"- No-sales false-positive guard passed: "
            f"{recommendation['no_sales_false_positive_free']}",
            "- Normal API/model selection/replenishment changed: False",
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the six-model shared seasonal LightGBM evaluation"
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        default=Path("simulation_reports/shared_seasonal_lightgbm_676d.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("simulation_reports/SHARED_SEASONAL_LIGHTGBM_REPORT.md"),
    )
    parser.add_argument(
        "--render-only",
        action="store_true",
        help="render Markdown from an existing JSON result without rerunning models",
    )
    args = parser.parse_args()
    if args.render_only:
        report = json.loads(args.json_output.read_text(encoding="utf-8"))
    else:
        report = _jsonable(SharedSeasonalBacktester().run())
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    if not args.render_only:
        args.json_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    args.report_output.write_text(_render_report(report), encoding="utf-8")
    print(json.dumps(report["recommendation"], indent=2, sort_keys=True))
    print(f"wrote {args.json_output}")
    print(f"wrote {args.report_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
