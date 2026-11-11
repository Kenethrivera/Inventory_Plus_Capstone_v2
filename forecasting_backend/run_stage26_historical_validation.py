from __future__ import annotations

import argparse
import json
from pathlib import Path

from app.simulation.stage26_historical_validation import (
    Stage26HistoricalValidator,
    jsonable,
    load_dense_history,
    metric_rows,
    write_csv,
)


ROOT = Path(__file__).resolve().parent


def _percent(value: object) -> str:
    return "n/a" if value is None else f"{float(value) * 100:.2f}%"


def _append_wape_table(
    lines: list[str],
    *,
    title: str,
    grouped: dict[str, object],
    group_first: bool,
) -> None:
    lines.extend(
        [
            "",
            f"## {title}",
            "",
            "| Group | Existing LGBM | Ablation | Seasonal LGBM | Mean28 |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    model_order = (
        "existing_lightgbm",
        "matched_nonseasonal_ablation",
        "product_specific_seasonal_lightgbm",
        "mean28",
    )
    group_names = (
        grouped.keys()
        if group_first
        else next(iter(grouped.values())).keys()
    )
    for group in group_names:
        metrics = (
            grouped[group]
            if group_first
            else {model: grouped[model][group] for model in model_order}
        )
        cells = " | ".join(_percent(metrics[model]["wape"]) for model in model_order)
        lines.append(f"| {group} | {cells} |")


def render_report(report: dict[str, object]) -> str:
    verification = report["database_verification"]
    frozen = report["frozen_dataset_verification"]
    lines = [
        "# Stage 2.6 Historical Accuracy and Seasonal Learning",
        "",
        f"**Stage decision: {report['decision']}**",
        "",
        "## Imported-history verification",
        "",
        f"- Live database comparison: **{verification['status']}**.",
        f"- Frozen CSV integrity: **{frozen['status']}**.",
        f"- Frozen coverage: {frozen['actual_products']} products x 1,461 dates = {frozen['actual_rows']} rows, {frozen['history_start']} through {frozen['history_end']}.",
        f"- Demand rows: {frozen['positive_demand_rows']} positive and {frozen['zero_demand_rows']} explicit zero-demand rows.",
        f"- Shape mismatches: {frozen['missing_product_date_rows']} missing and {frozen['unexpected_product_date_rows']} unexpected product/date rows.",
        f"- Value/metadata mismatches against the frozen generator: {frozen['generator_quantity_mismatches']} quantity and {frozen['metadata_mismatches']} metadata.",
        "- Accuracy metrics include only the 24 imported seasonal products; the original products are deliberately kept outside this benchmark.",
    ]
    if verification["status"] != "PASS":
        lines.extend(
            [
                f"- Blocker: {verification.get('blocking_reason', 'live history mismatch')}",
                "- All numerical model results below are provisional frozen-source results, not live-import verification.",
            ]
        )
    if "metrics" not in report:
        return "\n".join(lines) + "\n"
    lines.extend(
        [
            "",
            "## Overall accuracy",
            "",
            "| Horizon | Model | MAE | WAPE | Bias | Actual | Predicted |",
            "|---:|---|---:|---:|---:|---:|---:|",
        ]
    )
    for horizon, horizon_values in report["metrics"].items():
        for model, values in horizon_values[
            "overall_mixed_unit_diagnostic"
        ].items():
            lines.append(
                f"| {horizon} | {model} | {float(values['mae']):.4f} | "
                f"{_percent(values['wape'])} | {_percent(values['signed_bias'])} | "
                f"{float(values['actual_total']):.1f} | "
                f"{float(values['predicted_total']):.1f} |"
            )
    horizon_28 = report["metrics"]["28"]
    _append_wape_table(
        lines,
        title="28-day WAPE by seasonal group",
        grouped=horizon_28["by_seasonal_group"],
        group_first=True,
    )
    _append_wape_table(
        lines,
        title="28-day WAPE by compatible unit",
        grouped=horizon_28["by_compatible_unit"],
        group_first=False,
    )
    _append_wape_table(
        lines,
        title="28-day WAPE by demand pattern",
        grouped=horizon_28["by_demand_pattern"],
        group_first=False,
    )
    no_sales = horizon_28["by_demand_pattern"][
        "product_specific_seasonal_lightgbm"
    ]["no_sales"]
    lines.append(
        "\nThe never-sold control remained at "
        f"{float(no_sales['predicted_total']):.1f} predicted units for "
        f"{float(no_sales['actual_total']):.1f} actual units; WAPE is undefined when actual demand is zero."
    )
    _append_wape_table(
        lines,
        title="28-day transition WAPE",
        grouped=horizon_28["seasonal_transitions"],
        group_first=False,
    )
    seasonal = report["seasonal_learning_assessment"]
    lines.extend(
        [
            "",
            "## Pre-transition seasonal contribution",
            "",
        ]
    )
    for transition, gain in seasonal[
        "pretransition_wape_gains_vs_ablation"
    ].items():
        lines.append(f"- {transition}: {_percent(gain)} WAPE-point gain.")
    replay = report["historical_replay"]
    largest = replay["largest_observed_overprediction"]
    lines.extend(
        [
            "",
            "## Historical replay",
            "",
            f"- Products: {', '.join(replay['representative_skus'])}.",
            f"- Period-to-period absolute error improved: {replay['period_to_period_absolute_error_improved']} comparisons.",
            f"- Period-to-period absolute error worsened: {replay['period_to_period_absolute_error_worsened']} comparisons.",
            f"- {replay['interpretation']}",
            (
                "- Largest observed replay overprediction: "
                f"{largest['sku']} forecast {float(largest['forecast_total']):.2f}, "
                f"actual {float(largest['actual_total']):.2f}, error "
                f"+{float(largest['signed_error_predicted_minus_actual']):.2f}."
            ),
            "- Constructed Hammer arithmetic example: forecast 20, actual 5, overprediction 15. This is explicitly not model output; no next prediction is invented.",
            "",
            "## Stage 2.3 reproducibility check",
            "",
        ]
    )
    for model, comparison in report["stage23_comparison"].items():
        lines.append(
            f"- {model}: Stage 2.6 {_percent(comparison['stage26_wape'])}; "
            f"Stage 2.3 {_percent(comparison['stage23_wape'])}; "
            f"difference {float(comparison['difference']):.3e}."
        )
    lines.extend(
        [
            "",
            "## Recommendation",
            "",
            f"- Candidate on frozen synthetic history: **{report['model_recommendation']['decision']}**.",
            "- Frontend recommendation: use a forecast-versus-actual timeline with frozen forecast vintages, actuals revealed afterward, signed-error bars, and separate model comparison toggles. Keep synthetic and provisional badges visible.",
            "- Do not connect these artifacts to replenishment or the active model automatically.",
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run leakage-safe Stage 2.6 historical validation"
    )
    parser.add_argument(
        "--frozen-history",
        type=Path,
        default=ROOT / "simulation_reports" / "expanded_seasonal_daily_demand.csv",
    )
    parser.add_argument("--live-history-csv", type=Path)
    parser.add_argument("--allow-unverified-frozen", action="store_true")
    parser.add_argument(
        "--stage23-report",
        type=Path,
        default=ROOT
        / "simulation_reports"
        / "product_specific_seasonal_evaluation.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "simulation_reports" / "stage26",
    )
    args = parser.parse_args()
    if args.live_history_csv is None and not args.allow_unverified_frozen:
        parser.error(
            "--live-history-csv is required unless --allow-unverified-frozen is explicit"
        )

    frozen = load_dense_history(args.frozen_history)
    live = (
        load_dense_history(args.live_history_csv)
        if args.live_history_csv is not None
        else None
    )
    stage23 = json.loads(args.stage23_report.read_text(encoding="utf-8"))
    report, points, replay = Stage26HistoricalValidator(
        frozen_history=frozen,
        live_history=live,
        stage23_report=stage23,
    ).run()
    output = args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    serializable = jsonable(report)
    (output / "stage26_historical_accuracy.json").write_text(
        json.dumps(serializable, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output / "STAGE26_HISTORICAL_ACCURACY_REPORT.md").write_text(
        render_report(serializable), encoding="utf-8"
    )
    write_csv(output / "historical_forecast_vs_actual.csv", points)
    write_csv(output / "historical_replay.csv", replay)
    if "metrics" in report:
        write_csv(
            output / "product_level_accuracy.csv",
            metric_rows(report, "by_product"),
        )
        write_csv(
            output / "seasonal_transition_accuracy.csv",
            metric_rows(report, "seasonal_transitions"),
        )
    print(json.dumps({
        "decision": report["decision"],
        "database_verification": report["database_verification"]["status"],
        "output_dir": str(output),
    }, indent=2))
    return 0 if report["decision"] != "FAIL" else 2


if __name__ == "__main__":
    raise SystemExit(main())
