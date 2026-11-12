from __future__ import annotations

import argparse
import csv
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.simulation.expanded_seasonal_backtest import (
    MODELS,
    ExpandedSeasonalBacktester,
)
from app.simulation.expanded_seasonal_fixture import (
    HISTORY_END,
    HISTORY_START,
    PRODUCTS,
    simulated_quantity,
)


MODEL_LABELS = {
    "mean28": "Mean28",
    "lightgbm": "Existing per-product LightGBM",
    "shared_nonseasonal_ablation": "Shared nonseasonal LightGBM",
    "shared_seasonal_lightgbm": "Shared seasonal LightGBM",
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
    return f"{float(value) * 100:.{digits}f}"


def _number(value: object, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{digits}f}"


def _load_original_benchmark(path: Path) -> dict[str, object]:
    source = json.loads(path.read_text(encoding="utf-8"))
    selected = {
        model: source["overall_mixed_unit_diagnostic"][model]
        for model in MODELS
    }
    return {
        "artifact": str(path),
        "history_start": source["evaluation_contract"]["history_start"],
        "history_end": source["evaluation_contract"]["history_end"],
        "products": source["evaluation_contract"]["products"],
        "origins": len(source["evaluation_contract"]["origins"]),
        "overall_mixed_unit_diagnostic": selected,
        "recommendation": source["recommendation"],
    }


def _write_daily_csv(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            (
                "business_date",
                "product_id",
                "sku",
                "product_name",
                "category",
                "unit",
                "seasonal_group",
                "quantity",
            )
        )
        current = HISTORY_START
        while current <= HISTORY_END:
            for product in PRODUCTS:
                writer.writerow(
                    (
                        current.isoformat(),
                        product.product_id,
                        product.sku,
                        product.product_name,
                        product.category,
                        product.unit,
                        product.seasonal_group,
                        str(simulated_quantity(product, current)),
                    )
                )
            current = current.fromordinal(current.toordinal() + 1)


def _metric_lines(
    title: str,
    rows: dict[str, dict[str, dict[str, object]]],
    group_label: str,
) -> list[str]:
    lines = [
        f"## {title}",
        "",
        f"| {group_label} | Model | MAE | WAPE | Bias | Actual | Predicted |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    groups = sorted(next(iter(rows.values())).keys())
    for group in groups:
        for model in MODELS:
            metrics = rows[model][group]
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
    audit = report["original_dataset_signal_audit"]
    expanded_audit = report["expanded_dataset_signal_audit"]
    original = report["original_benchmark_reference"]
    validation = report["validation"]
    final = report["final_test"]
    recommendation = report["recommendation"]
    lines = [
        "# Stage 2.1 Seasonal Data Audit and Expanded Simulation",
        "",
        "Status: offline experiment only. No Supabase data, Flutter behavior, active "
        "forecast selection, or replenishment logic was changed.",
        "",
        "## Recommendation",
        "",
        f"**{recommendation['decision']}** for seasonal-model integration. "
        "`activation_allowed` remains false.",
        "",
        "## Original 676-day dataset audit",
        "",
        f"- Products with an explicit generator month effect: "
        f"{audit['products_with_explicit_month_effect']} of 13.",
        f"- Products crossing the frozen calendar-signal threshold: "
        f"{audit['products_meeting_signal_threshold']} of 13.",
        f"- Knowledge-label direction mismatches: "
        f"{', '.join(audit['products_with_direction_mismatch']) or 'none'}.",
        "- The fixture spans less than two full annual cycles, while the deployed "
        "application experiment used only the latest 365 calendar days at each origin.",
        "- Month effects were programmed for reporting variety, not as a balanced "
        "SUMMER/RAINY/NEUTRAL experiment.",
        "",
        audit["audit_conclusion"],
        "",
        "### Why the original shared seasonal model underperformed",
        "",
        "1. The fixture was built for broad transaction testing, not balanced "
        "seasonal-class learning; only four formulas had explicit month effects.",
        "2. Programmed peaks and qualitative knowledge labels do not always align; "
        "two classified products have an audited direction mismatch.",
        "3. The 365-day model window exposed at most one annual cycle, making stable "
        "product-by-season effects hard to separate from trend and noise.",
        "4. Existing per-product LightGBM already has annual sine/cosine features, "
        "so pooling needed genuine cross-product signal to add value.",
        "5. Pooling transferred positive demand into dead-stock, intermittent and "
        "no-sales products, producing a structural false-positive regression.",
        "",
        "### Frozen original benchmark",
        "",
        "| Model | WAPE | MAE | Bias |",
        "|---|---:|---:|---:|",
    ]
    for model in MODELS:
        metrics = original["overall_mixed_unit_diagnostic"][model]
        lines.append(
            f"| {MODEL_LABELS[model]} | {_percent(metrics['wape'])} | "
            f"{_number(metrics['mae'])} | {_percent(metrics['signed_bias'])} |"
        )
    lines.extend(
        [
            "",
            f"Original recommendation: **{original['recommendation']['decision']}**. "
            "These results were not overwritten by the expanded experiment.",
            "",
            "## Database seasonal-support assessment",
            "",
            "No schema change is required. `products` already stores product identity, "
            "normal hardware category, description, unit and location. Completed dated "
            "sales are represented by `order_history.completed_at` plus complete JSON item "
            "snapshots, and `forecast_daily_demand_v1` converts those timestamps into "
            "Asia/Manila business dates and aggregates quantity by product and unit.",
            "",
            "The deployed RPC accepts periods up to five years. The current application "
            "experiment requests 365 days, so a later multi-cycle integration would require "
            "a reviewed backend history-window change, not a database column or table.",
            "",
            "The experimental SUMMER/RAINY/NEUTRAL labels remain in this versioned offline "
            "manifest. They are not written to operational products because they are "
            "hypotheses and should be reassessed as knowledge improves.",
            "",
            "Live MCP query tools were unavailable during this run; this assessment was "
            "checked against the repository's declarative schema and deployed RPC source. "
            "The proposed import includes a schema-drift preflight and must not be executed "
            "until live metadata is rechecked.",
            "",
            "## Expanded dataset contract",
            "",
            f"- Manifest: `{contract['manifest_version']}`",
            f"- Frozen SHA-256: `{contract['manifest_sha256']}`",
            f"- History: {contract['history_start']} through {contract['history_end']} "
            f"({contract['calendar_days']} days)",
            f"- Training: {contract['training_period'][0]} through "
            f"{contract['training_period'][1]}",
            f"- Validation: {contract['validation_period'][0]} through "
            f"{contract['validation_period'][1]}",
            f"- Final test: {contract['final_test_period'][0]} through "
            f"{contract['final_test_period'][1]}",
            "- 24 new, nonduplicating proposed products: eight per experimental group.",
            "- The final daily CSV includes zero-demand dates and contains 35,064 rows.",
            "- Models receive at most 1,095 prior calendar days; generator-only amplitudes, "
            "random streams, shocks and gates are withheld.",
            "",
            "### Signal qualification before model evaluation",
            "",
            f"- SUMMER: {expanded_audit['by_group']['SUMMER']['meaningful_signals']} of 8 "
            "cross the frozen signal threshold.",
            f"- RAINY: {expanded_audit['by_group']['RAINY']['meaningful_signals']} of 8 "
            "cross the frozen signal threshold.",
            f"- NEUTRAL: {expanded_audit['by_group']['NEUTRAL']['meaningful_signals']} of 8 "
            "cross it, as intended.",
            "- Weak/ambiguous seasonal exceptions and intermittent products are retained; "
            "season alone cannot perfectly predict demand.",
            "",
            "### Product-list review and evidence boundary",
            "",
            "The suggested Phillips screwdriver, adjustable wrench and measuring tape "
            "were excluded because those products already exist in the original catalog. "
            "They were replaced with wood screws, a padlock and an explicit LED no-sales "
            "control. Normal hardware categories remain separate from seasonal groups.",
            "",
            "Construction labels inherit only the general PAGASA/PIDS weather-exposed "
            "work mechanism. Waterproofing, roof-drainage and temporary-cover labels are "
            "provisional use-timing hypotheses. Roof flashing deliberately has nearly "
            "offset rainy-repair and dry-installation effects. No reviewed source supplies "
            "a Philippine retail-sales percentage for any product.",
            "",
            "The manifest retains PAGASA climatology, PIDS rainfall/construction evidence, "
            "and the Inventory Plus controlled taxonomy as sources for context and intended "
            "use—not for the synthetic amplitudes.",
            "",
            "## Final product list and frozen assumptions",
            "",
            "| Group | SKU | Product | Unit | Baseline/day | Primary amplitude | Secondary amplitude | Intermittency | Evidence |",
            "|---|---|---|---|---:|---:|---:|---:|---|",
        ]
    )
    for product in report["product_manifest"]:
        lines.append(
            f"| {product['seasonal_group']} | {product['sku']} | "
            f"{product['product_name']} | {product['unit']} | "
            f"{_number(product['baseline_daily'], 2)} | "
            f"{_number(product['primary_amplitude'], 2)} | "
            f"{_number(product['secondary_amplitude'], 2)} | "
            f"{_number(product['intermittency_probability'], 2)} | "
            f"{product['evidence_level']} |"
        )
    lines.extend(
        [
            "",
            "Amplitudes are generator parameters for this simulation only. They are never "
            "passed to the forecasting models and must not be interpreted as real sales "
            "percentages.",
            "",
            "## Expanded validation-cycle overall results",
            "",
            "| Model | MAE | WAPE | Bias |",
            "|---|---:|---:|---:|",
        ]
    )
    for model in MODELS:
        metrics = validation["overall_mixed_unit_diagnostic"][model]
        lines.append(
            f"| {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
            f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} |"
        )
    lines.extend(
        [
            "",
            "## Expanded final-test overall results",
            "",
            "| Model | MAE | WAPE | Bias |",
            "|---|---:|---:|---:|",
        ]
    )
    for model in MODELS:
        metrics = final["overall_mixed_unit_diagnostic"][model]
        lines.append(
            f"| {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
            f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} |"
        )
    lines.append("")

    group_rows = {
        model: {
            group: final["by_seasonal_group"][group][model]
            for group in ("SUMMER", "RAINY", "NEUTRAL")
        }
        for model in MODELS
    }
    lines.extend(
        _metric_lines(
            "Final-test results by experimental group",
            group_rows,
            "Group",
        )
    )
    lines.extend(
        _metric_lines(
            "Final-test results by demand pattern",
            final["by_demand_pattern"],
            "Pattern",
        )
    )
    lines.extend(
        _metric_lines(
            "Final-test results by compatible unit",
            final["by_compatible_unit"],
            "Unit",
        )
    )
    lines.extend(
        _metric_lines(
            "Final-test seasonal transitions",
            final["seasonal_transitions"],
            "Transition",
        )
    )

    lines.extend(
        [
            "## Final-test per-product results",
            "",
            "| SKU | Model | MAE | WAPE | Bias |",
            "|---|---|---:|---:|---:|",
        ]
    )
    for sku in sorted(final["by_product"]["mean28"]):
        for model in MODELS:
            metrics = final["by_product"][model][sku]
            lines.append(
                f"| {sku} | {MODEL_LABELS[model]} | {_number(metrics['mae'])} | "
                f"{_percent(metrics['wape'])} | {_percent(metrics['signed_bias'])} |"
            )
    lines.append("")

    lines.extend(
        [
            "## Pre-transition forecast examples",
            "",
            "The JSON artifact contains every daily actual and prediction for these cases.",
            "",
            "| Origin | Product | Group | Recent 28 actual | Target actual | Mean28 | Existing LGBM | Shared ablation | Shared seasonal | Seasonal - ablation |",
            "|---|---|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for example in report["transition_anticipation_examples"]:
        values = example["predicted_totals"]
        lines.append(
            f"| {example['origin']} | {example['product_name']} | "
            f"{example['seasonal_group']} | "
            f"{_number(example['recent_28_day_actual'], 1)} | "
            f"{_number(example['target_28_day_actual'], 1)} | "
            f"{_number(values['mean28'], 1)} | {_number(values['lightgbm'], 1)} | "
            f"{_number(values['shared_nonseasonal_ablation'], 1)} | "
            f"{_number(values['shared_seasonal_lightgbm'], 1)} | "
            f"{_number(example['seasonal_minus_ablation'], 1)} |"
        )

    lines.extend(
        [
            "",
            "### Daily predicted-versus-actual samples",
            "",
            "The first seven target days from each example are shown below; all 28 days "
            "and every model are retained in JSON.",
            "",
            "| Origin | SKU | Date | Actual | Shared seasonal prediction |",
            "|---|---|---|---:|---:|",
        ]
    )
    for example in report["transition_anticipation_examples"]:
        for day in example["daily"]["shared_seasonal_lightgbm"][:7]:
            lines.append(
                f"| {example['origin']} | {example['sku']} | {day['date']} | "
                f"{_number(day['actual'], 2)} | {_number(day['predicted'], 2)} |"
            )

    lines.extend(
        [
            "",
            "## Acceptance checks",
            "",
            f"- Overall WAPE gain versus ablation: "
            f"{_percent(recommendation['overall_wape_gain_vs_ablation'])} percentage points.",
            f"- SUMMER and RAINY groups both improve: "
            f"{recommendation['seasonal_groups_both_improve']}.",
            f"- Both calendar transitions improve: "
            f"{recommendation['all_transitions_improve']}.",
            f"- Neutral regression within one percentage point: "
            f"{recommendation['neutral_regression_within_one_percentage_point']}.",
            f"- No-sales false-positive guard passed: "
            f"{recommendation['no_sales_false_positive_free']}.",
            "",
            "## Supabase import assessment",
            "",
            "Import is **not recommended yet**. A guarded proposal SQL file is supplied "
            "for review, but it defaults to refusing execution. It uses new products and "
            "deterministic tagged orders, builds item snapshots, and creates a monthly "
            "receipt/daily checkout ledger that ends at each product's catalog quantity. "
            "Rollback targets only the tagged batch and new product IDs.",
            "",
            "Before any later manual import, create a Supabase branch or downloadable "
            "database backup and export the target location's products, orders, "
            "order_history and transaction_history. The proposal is additive and its "
            "rollback is batch-tagged, but a platform backup remains the recovery boundary "
            "for trigger or schema drift.",
            "",
            "No seasonal-label column or new table is proposed. The labels remain an "
            "offline research manifest, preventing provisional assumptions from becoming "
            "permanent operational truth.",
            "",
            "## Evidence boundary and limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    lines.extend(
        [
            "- Product intended uses come from the controlled Inventory Plus taxonomy and "
            "the manifest descriptions. Seasonal magnitudes remain synthetic.",
            "- The generator uses no invented weather observations or future weather data.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the frozen expanded Philippine seasonal experiment"
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        default=Path("simulation_reports/expanded_seasonal_evaluation.json"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("simulation_reports/EXPANDED_SEASONAL_DATASET_REPORT.md"),
    )
    parser.add_argument(
        "--csv-output",
        type=Path,
        default=Path("simulation_reports/expanded_seasonal_daily_demand.csv"),
    )
    parser.add_argument(
        "--original-benchmark",
        type=Path,
        default=Path("simulation_reports/shared_seasonal_lightgbm_676d.json"),
    )
    parser.add_argument(
        "--render-only",
        action="store_true",
        help="render report/CSV from the existing JSON without rerunning models",
    )
    args = parser.parse_args()

    if args.render_only:
        report = json.loads(args.json_output.read_text(encoding="utf-8"))
    else:
        raw_report = ExpandedSeasonalBacktester().run()
        raw_report["original_benchmark_reference"] = _load_original_benchmark(
            args.original_benchmark
        )
        report = _jsonable(raw_report)
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    if not args.render_only:
        args.json_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    args.report_output.write_text(_render_report(report), encoding="utf-8")
    _write_daily_csv(args.csv_output)
    print(json.dumps(report["recommendation"], indent=2, sort_keys=True))
    print(f"wrote {args.json_output}")
    print(f"wrote {args.report_output}")
    print(f"wrote {args.csv_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
