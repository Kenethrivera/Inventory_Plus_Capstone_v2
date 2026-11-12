from __future__ import annotations

import argparse
import json
from pathlib import Path

from app.simulation.stage29a_accuracy_diagnostics import (
    build_diagnostics,
    flatten_product_rows,
    load_json,
    load_points,
    sha256,
    write_csv,
)


ROOT = Path(__file__).resolve().parent


def percent(value: object) -> str:
    return "n/a" if value is None else f"{float(value) * 100:.2f}%"


def render_markdown(report: dict[str, object]) -> str:
    baseline = report["published_baseline_reproduction"]
    summary = report["diagnostic_summary"]
    products = report["ranked_product_error_contributors"]
    group_rows = report["group_comparisons"]
    totals = report["horizon_quantity_metrics"]

    lines = [
        "# Stage 2.9A Forecast Accuracy Diagnostics",
        "",
        f"**Recommendation: {report['recommendation']}**",
        "",
        "This report is diagnostic only. It does not alter forecasting, training, Supabase, Flutter, or replenishment.",
        "",
        "## Frozen Stage 2.6 reproduction",
        "",
        "| Model | 28-day daily WAPE |",
        "|---|---:|",
    ]
    for model, value in baseline["daily_28_day_wape"].items():
        lines.append(f"| {model} | {percent(value)} |")
    lines.extend(
        [
            "",
            "## Ranked product error contributors",
            "",
            "The overall rank and contribution share reproduce the mixed-unit Stage 2.6 WAPE diagnostic. They must not be interpreted as interchangeable physical quantities; use the unit and within-unit rank for operational comparisons.",
            "",
            "| Overall rank | Unit rank | SKU | Product | Unit | Group | Pattern | Actual | Predicted | Absolute error | Share | WAPE | Bias | vs ablation |",
            "|---:|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|",
        ]
    )
    for row in products:
        lines.append(
            f"| {row['rank']} | {row['unit_rank']} | {row['sku']} | {row['product_name']} | "
            f"{row['unit']} | {row['seasonal_group']} | {row['demand_pattern']} | "
            f"{float(row['actual_total']):.1f} | {float(row['predicted_total']):.1f} | "
            f"{float(row['absolute_error_total']):.1f} | "
            f"{percent(row['absolute_error_contribution'])} | {percent(row['wape'])} | "
            f"{percent(row['signed_bias'])} | {row['seasonal_candidate_vs_ablation']} |"
        )

    def selected_groups(dimension: str) -> list[dict[str, object]]:
        return [
            row
            for row in group_rows
            if row["horizon_days"] == 28
            and row["model"] == "product_specific_seasonal_lightgbm"
            and row["dimension"] == dimension
        ]

    for dimension, title in (
        ("seasonal_group", "Seasonal groups"),
        ("demand_class", "Regular, intermittent and no-sales"),
        ("actual_volume_band", "Actual-volume bands"),
        ("seasonal_transition", "Dry/rainy transitions"),
        ("actual_state", "Zero- versus positive-demand rows"),
    ):
        lines.extend(
            [
                "",
                f"## {title}",
                "",
                "| Group | Observations | Actual | Predicted | WAPE | Bias | Absolute error |",
                "|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for row in selected_groups(dimension):
            lines.append(
                f"| {row['group']} | {row['observations']} | "
                f"{float(row['actual_total']):.1f} | {float(row['predicted_total']):.1f} | "
                f"{percent(row['wape'])} | {percent(row['signed_bias'])} | "
                f"{float(row['absolute_error_total']):.1f} |"
            )

    lines.extend(
        [
            "",
            "## Model comparison by demand segment",
            "",
            "| Dimension | Group | Mean28 | Existing LGBM | Ablation | Seasonal LGBM |",
            "|---|---|---:|---:|---:|---:|",
        ]
    )
    for dimension in (
        "seasonal_group",
        "demand_class",
        "actual_volume_band",
        "seasonal_transition",
    ):
        groups = sorted(
            {
                row["group"]
                for row in group_rows
                if row["horizon_days"] == 28
                and row["dimension"] == dimension
            }
        )
        for group in groups:
            values = {
                row["model"]: row["wape"]
                for row in group_rows
                if row["horizon_days"] == 28
                and row["dimension"] == dimension
                and row["group"] == group
            }
            lines.append(
                f"| {dimension} | {group} | {percent(values['mean28'])} | "
                f"{percent(values['existing_lightgbm'])} | "
                f"{percent(values['matched_nonseasonal_ablation'])} | "
                f"{percent(values['product_specific_seasonal_lightgbm'])} |"
            )

    lines.extend(
        [
            "",
            "## Overforecasting versus underforecasting",
            "",
            "| Direction | Observations | Signed error | Absolute error |",
            "|---|---:|---:|---:|",
        ]
    )
    for row in selected_groups("error_direction"):
        lines.append(
            f"| {row['group']} | {row['observations']} | "
            f"{float(row['signed_error_total']):.1f} | "
            f"{float(row['absolute_error_total']):.1f} |"
        )

    lines.extend(
        [
            "",
            "## Daily versus decision-horizon accuracy",
            "",
            "The published daily WAPE remains unchanged. Horizon-total WAPE first sums each product forecast over one origin and then calculates absolute error, which better matches an order-quantity decision while allowing daily timing errors to cancel.",
            "",
            "| Horizon | Model | Quantity-total WAPE | Quantity-total MAE | Bias |",
            "|---:|---|---:|---:|---:|",
        ]
    )
    for row in totals:
        lines.append(
            f"| {row['horizon_days']} | {row['model']} | "
            f"{percent(row['quantity_total_wape'])} | "
            f"{float(row['quantity_total_mae']):.3f} | "
            f"{percent(row['quantity_total_signed_bias'])} |"
        )

    lines.extend(
        [
            "",
            "## Main findings",
            "",
            f"- The five largest product contributors account for {percent(summary['top_five_product_absolute_error_share'])} of seasonal-model absolute error.",
            f"- Intermittent 28-day daily WAPE is {percent(summary['intermittent_28_day_daily_wape'])}, compared with {percent(summary['regular_28_day_daily_wape'])} for regular products.",
            f"- The seasonal candidate improves {summary['candidate_products_better_than_ablation']} products and worsens {summary['candidate_products_worse_than_ablation']} versus the matched ablation.",
            f"- Overall seasonal-model bias is {percent(summary['candidate_overall_signed_bias'])}; the error is mostly absolute dispersion rather than a single global offset.",
            f"- Seven-day daily WAPE is {percent(summary['daily_7_day_wape'])}, while seven-day quantity-total WAPE is {percent(summary['quantity_total_7_day_wape'])}.",
            f"- Twenty-eight-day daily WAPE is {percent(summary['daily_28_day_wape'])}, while 28-day quantity-total WAPE is {percent(summary['quantity_total_28_day_wape'])}.",
            "- Stockout effects cannot be measured: the synthetic generator is not availability-censored and the frozen forecast rows have no stockout flags.",
            "",
            "## Error-source assessment",
            "",
        ]
    )
    for source in report["identified_error_sources"]:
        lines.append(
            f"- **{source['source']} ({source['assessment']}):** {source['evidence']}"
        )
    lines.extend(["", "## Controlled experiments, not implementations", ""])
    holdout = report["holdout_policy"]
    lines.extend(
        [
            f"- Stage 2.6 final-period use: **{holdout['stage26_final_use']}**; it is not eligible for experiment selection.",
            f"- {holdout['future_experiment']}",
            "",
        ]
    )
    for experiment in report["targeted_improvements"]:
        lines.append(
            f"{experiment['priority']}. **{experiment['experiment']}** — expected benefit: "
            f"{experiment['expected_benefit']}; risk: {experiment['implementation_risk']}. "
            f"{experiment['evaluation']}"
        )
    calibration = report["calibration_assessment"]
    lines.extend(
        [
            "",
            "## Calibration assessment",
            "",
            f"- Global calibration justified now: **{calibration['global_calibration_justified']}**.",
            f"- {calibration['reason']}",
            f"- {calibration['controlled_experiment_condition']}",
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Diagnose frozen Stage 2.6 forecast errors without retraining"
    )
    parser.add_argument(
        "--stage26-dir",
        type=Path,
        default=ROOT / "simulation_reports" / "stage26",
    )
    parser.add_argument(
        "--assumptions",
        type=Path,
        default=ROOT / "app" / "simulation" / "expanded_seasonal_assumptions.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "simulation_reports" / "stage29a",
    )
    args = parser.parse_args()

    points_path = args.stage26_dir / "historical_forecast_vs_actual.csv"
    stage26_path = args.stage26_dir / "stage26_historical_accuracy.json"
    points = load_points(points_path)
    report = build_diagnostics(
        points=points,
        stage26=load_json(stage26_path),
        assumptions=load_json(args.assumptions),
        points_sha256=sha256(points_path),
        stage26_sha256=sha256(stage26_path),
        assumptions_sha256=sha256(args.assumptions),
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "stage29a_accuracy_diagnostics.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (args.output_dir / "STAGE29A_FORECAST_ACCURACY_DIAGNOSTICS.md").write_text(
        render_markdown(report), encoding="utf-8"
    )
    write_csv(
        args.output_dir / "ranked_product_error_contributors.csv",
        flatten_product_rows(report),
    )
    write_csv(
        args.output_dir / "model_and_demand_group_comparisons.csv",
        report["group_comparisons"],
    )
    write_csv(
        args.output_dir / "horizon_quantity_metrics.csv",
        report["horizon_quantity_metrics"],
    )
    print(
        json.dumps(
            {
                "recommendation": report["recommendation"],
                "output_dir": str(args.output_dir),
                "input_rows": report["source_integrity"]["input_rows"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
