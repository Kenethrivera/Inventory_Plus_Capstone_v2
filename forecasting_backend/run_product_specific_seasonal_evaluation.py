from __future__ import annotations

import argparse
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.simulation.product_specific_seasonal_backtest import (
    HYPERPARAMETERS,
    HISTORY_WINDOWS,
    ProductSpecificSeasonalBacktester,
)


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


def _pp(value: object, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{float(value) * 100:.{digits}f} pp"


def _number(value: object, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{digits}f}"


def _label(model: str) -> str:
    if model == "existing_lightgbm":
        return "Existing product-specific LightGBM"
    if model.startswith("seasonal_"):
        return f"Product seasonal ({model.removeprefix('seasonal_')})"
    if model.startswith("ablation_"):
        return f"Nonseasonal ablation ({model.removeprefix('ablation_')})"
    return model


def _derive_product_level_comparison(report: dict[str, object]) -> dict[str, object]:
    selection = report["validation_selection"]
    final = report["final_test"]
    seasonal = selection["model"]
    ablation = selection["matched_ablation"]
    by_product = final["by_product"]
    result: dict[str, object] = {}
    for baseline in ("existing_lightgbm", ablation):
        rows: list[dict[str, object]] = []
        for sku, seasonal_metrics in by_product[seasonal].items():
            seasonal_wape = seasonal_metrics["wape"]
            baseline_wape = by_product[baseline][sku]["wape"]
            if seasonal_wape is None or baseline_wape is None:
                continue
            rows.append(
                {
                    "sku": sku,
                    "seasonal_wape": seasonal_wape,
                    "baseline_wape": baseline_wape,
                    "wape_gain": baseline_wape - seasonal_wape,
                }
            )
        ordered = sorted(rows, key=lambda value: value["wape_gain"])
        result[baseline] = {
            "comparable_products": len(rows),
            "improved": sum(value["wape_gain"] > 0 for value in rows),
            "regressed": sum(value["wape_gain"] < 0 for value in rows),
            "tied": sum(value["wape_gain"] == 0 for value in rows),
            "largest_regressions": ordered[:5],
            "largest_improvements": list(reversed(ordered[-5:])),
        }
    return result


def _group_table(
    title: str,
    values: dict[str, dict[str, dict[str, object]]],
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
            metrics = values[model][group]
            lines.append(
                f"| {group} | {_label(model)} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
                f"{_number(metrics['actual_total'], 1)} | "
                f"{_number(metrics['predicted_total'], 1)} |"
            )
    lines.append("")
    return lines


def _render(report: dict[str, object]) -> str:
    contract = report["evaluation_contract"]
    selection = report["validation_selection"]
    final = report["final_test"]
    recommendation = report["recommendation"]
    seasonal = selection["model"]
    ablation = selection["matched_ablation"]
    final_models = ["existing_lightgbm", ablation, seasonal]
    lines = [
        "# Stage 2.3 Product-Specific Seasonal LightGBM",
        "",
        "Status: offline experiment only. Production forecasting remains unchanged.",
        "",
        "## Recommendation",
        "",
        f"**{recommendation['decision']}**. "
        + (
            "The candidate passed every acceptance check."
            if recommendation["integration_recommended"]
            else "Retain the existing product-specific LightGBM."
        ),
        "",
        f"Validation selected **{selection['history_window_days']} days** with the "
        f"**{selection['hyperparameters']}** hyperparameter set. Final-test labels "
        "were not accessed until that choice was frozen.",
        "",
        f"- Final WAPE contribution from seasonal features: "
        f"{_pp(recommendation['final_wape_gain_vs_ablation'])}.",
        f"- Final WAPE gain versus existing LightGBM: "
        f"{_pp(recommendation['final_wape_gain_vs_existing_lightgbm'])}.",
        f"- Never-sold false-positive check: "
        f"{recommendation['no_sales_false_positive_free']}.",
        "",
        "## Experiment contract",
        "",
        f"- Population: {contract['population']['expanded_products_evaluated']} expanded "
        "offline products; original operational products are excluded.",
        f"- Validation: {contract['validation_period'][0]} through "
        f"{contract['validation_period'][1]}.",
        f"- Untouched final test: {contract['final_test_period'][0]} through "
        f"{contract['final_test_period'][1]}.",
        "- Each LightGBM is trained from one product's sales history only.",
        "- The ablation calls the production LightGBM feature function directly.",
        "- Added inputs are target-date PAGASA calendar context, transition state, "
        "month, transition proximity, and product-knowledge alignment indicators.",
        "- These values are features, not demand multipliers; every numerical effect is "
        "learned from historical targets.",
        "",
        "## Validation-only model and history selection",
        "",
        "| Window | Hyperparameters | Seasonal WAPE | Ablation gain | Existing-LGBM gain | Neutral gain | Eligible |",
        "|---:|---|---:|---:|---:|---:|---|",
    ]
    for row in selection["all_validation_candidates"]:
        lines.append(
            f"| {row['history_window_days']} | {row['hyperparameters']} | "
            f"{_percent(row['validation_wape'])} | "
            f"{_pp(row['gain_vs_ablation'])} | "
            f"{_pp(row['gain_vs_existing_lightgbm'])} | "
            f"{_pp(row['neutral_gain_vs_ablation'])} | {row['eligible']} |"
        )
    lines.extend(
        [
            "",
            "Observed training lengths were not padded. The 1,095-day setting uses only "
            "731-1,068 available days across validation origins.",
            "",
            "## Final-test overall accuracy",
            "",
            "| Model | MAE | WAPE | Bias | Actual | Predicted |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for model in final_models:
        metrics = final["overall_mixed_unit_diagnostic"][model]
        lines.append(
            f"| {_label(model)} | {_number(metrics['mae'])} | "
            f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
            f"{_number(metrics['actual_total'], 1)} | "
            f"{_number(metrics['predicted_total'], 1)} |"
        )
    lines.extend(
        [
            "",
            "Mixed-unit totals above are diagnostic. Product and compatible-unit results "
            "below are the decision-safe comparisons.",
            "",
            "## Product-level outcome summary",
            "",
            "| Baseline | Comparable | Improved | Regressed | Tied |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    comparison = report["product_level_comparison"]
    for baseline in ("existing_lightgbm", ablation):
        values = comparison[baseline]
        lines.append(
            f"| {_label(baseline)} | {values['comparable_products']} | "
            f"{values['improved']} | {values['regressed']} | {values['tied']} |"
        )
    lines.extend(
        [
            "",
            "Largest WAPE regressions versus each baseline are retained below. A negative "
            "gain means the seasonal candidate was worse.",
            "",
            "| Baseline | SKU | Seasonal WAPE | Baseline WAPE | Gain |",
            "|---|---|---:|---:|---:|",
        ]
    )
    for baseline in ("existing_lightgbm", ablation):
        for row in comparison[baseline]["largest_regressions"]:
            lines.append(
                f"| {_label(baseline)} | {row['sku']} | "
                f"{_percent(row['seasonal_wape'])} | "
                f"{_percent(row['baseline_wape'])} | {_pp(row['wape_gain'])} |"
            )
    lines.extend(
        [
            "",
            "## Final-test results by seasonal group",
            "",
            "| Group | Model | MAE | WAPE | Bias |",
            "|---|---|---:|---:|---:|",
        ]
    )
    for group in ("SUMMER", "RAINY", "NEUTRAL"):
        for model in final_models:
            metrics = final["by_seasonal_group"][group][model]
            lines.append(
                f"| {group} | {_label(model)} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} |"
            )
    lines.append("")
    lines.extend(
        _group_table(
            "Final-test results by compatible inventory unit",
            final["by_compatible_unit"],
            sorted(final["by_compatible_unit"][seasonal]),
            final_models,
            "Unit",
        )
    )
    lines.extend(
        _group_table(
            "Final-test results by demand pattern",
            final["by_demand_pattern"],
            sorted(final["by_demand_pattern"][seasonal]),
            final_models,
            "Pattern",
        )
    )
    lines.extend(
        _group_table(
            "All final-test seasonal-transition targets",
            final["seasonal_transitions"],
            sorted(final["seasonal_transitions"][seasonal]),
            final_models,
            "Transition",
        )
    )
    lines.extend(
        _group_table(
            "Pre-transition anticipation targets",
            final["pretransition_anticipation"],
            sorted(final["pretransition_anticipation"][seasonal]),
            final_models,
            "Upcoming transition",
        )
    )
    lines.extend(
        [
            "The pre-transition table includes only forecasts issued in April for May "
            "transition dates and in October for November transition dates. It therefore "
            "tests target-date anticipation before transition-period sales enter recent lags.",
            "",
            "## Final-test per-product accuracy",
            "",
            "| SKU | Model | MAE | WAPE | Bias | Actual | Predicted |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
    )
    for sku in sorted(final["by_product"][seasonal]):
        for model in final_models:
            metrics = final["by_product"][model][sku]
            lines.append(
                f"| {sku} | {_label(model)} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} | "
                f"{_number(metrics['actual_total'], 1)} | "
                f"{_number(metrics['predicted_total'], 1)} |"
            )
    lines.extend(
        [
            "",
            "The no-sales control has undefined WAPE; zero MAE and zero predicted total "
            "are its acceptance criteria. Intermittent products are evaluated normally.",
            "",
            "## Transition examples",
            "",
            "| Origin | SKU | Group | Recent actual | Target actual | Existing | Ablation | Seasonal | Seasonal - ablation |",
            "|---|---|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for example in report["transition_anticipation_examples"]:
        predictions = example["predicted_totals"]
        lines.append(
            f"| {example['origin']} | {example['sku']} | "
            f"{example['seasonal_group']} | "
            f"{_number(example['recent_28_day_actual'], 1)} | "
            f"{_number(example['target_28_day_actual'], 1)} | "
            f"{_number(predictions['existing_lightgbm'], 1)} | "
            f"{_number(predictions[ablation], 1)} | "
            f"{_number(predictions[seasonal], 1)} | "
            f"{_number(example['seasonal_minus_ablation'], 1)} |"
        )
    lines.extend(["", "## Unchanged boundaries", ""])
    lines.extend(f"- {value}" for value in report["unchanged_boundaries"])
    lines.extend(
        [
            "- Seasonal classifications remain simulation hypotheses, not verified retail "
            "demand effects.",
            "- No forecast was altered by a manually assigned percentage or coefficient.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run Stage 2.3 product-specific seasonal evaluation"
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        default=Path("simulation_reports/product_specific_seasonal_evaluation.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("simulation_reports/PRODUCT_SPECIFIC_SEASONAL_REPORT.md"),
    )
    parser.add_argument("--render-only", action="store_true")
    args = parser.parse_args()

    if args.render_only:
        report = json.loads(args.json_output.read_text(encoding="utf-8"))
        if "product_level_comparison" not in report:
            report["product_level_comparison"] = _derive_product_level_comparison(
                report
            )
            args.json_output.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    else:
        report = _jsonable(ProductSpecificSeasonalBacktester().run())
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.write_text(_render(report), encoding="utf-8")
    print(json.dumps(report["recommendation"], indent=2, sort_keys=True))
    print(f"wrote {args.json_output}")
    print(f"wrote {args.report_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
