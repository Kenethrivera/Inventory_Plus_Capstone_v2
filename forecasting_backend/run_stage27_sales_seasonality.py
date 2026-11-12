from __future__ import annotations

import argparse
import csv
import json
from datetime import date
from pathlib import Path
from typing import Any

from app.simulation.expanded_seasonal_fixture import HISTORY_END, PRODUCTS
from app.simulation.sales_seasonality_discovery import (
    LearnedSeasonality,
    SalesSeasonalityDiscoverer,
    classification_metrics,
)
from app.simulation.stage26_historical_validation import (
    compare_live_history,
    load_dense_history,
    verify_frozen_history,
)


ROOT = Path(__file__).resolve().parent
WINDOW_MONTHS = (6, 12, 24, 36)


def add_months(value: date, months: int) -> date:
    month_index = value.month - 1 + months
    year = value.year + month_index // 12
    month = month_index % 12 + 1
    day = min(
        value.day,
        (date(year + (month == 12), month % 12 + 1, 1) - date.resolution).day,
    )
    return date(year, month, day)


def window_cutoff(history_start: date, months: int) -> date:
    return add_months(history_start, months) - date.resolution


def _write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields: list[str] = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    key: (
                        json.dumps(value, sort_keys=True)
                        if isinstance(value, (list, dict, tuple))
                        else value
                    )
                    for key, value in row.items()
                }
            )


def _confusion_rows(
    model: str, metrics: dict[str, object]
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for actual, predicted_values in metrics["confusion_matrix"].items():
        for predicted, count in predicted_values.items():
            rows.append(
                {
                    "model": model,
                    "actual": actual,
                    "predicted": predicted,
                    "count": count,
                }
            )
    return rows


def _render_report(report: dict[str, object]) -> str:
    final = report["final_36_month_evaluation"]
    method = final["discovery_method"]
    baseline = final["simple_baseline"]
    lines = [
        "# Stage 2.7 Sales-Based Seasonal Learning",
        "",
        f"**Decision: {report['decision']}**",
        "",
        "## Verified input",
        "",
        f"- Live export comparison: **{report['input_verification']['live_comparison']['status']}**.",
        f"- Dense rows: {report['input_verification']['live_comparison']['actual_rows']}.",
        f"- Date range: {report['input_verification']['frozen_integrity']['history_start']} through {report['input_verification']['frozen_integrity']['history_end']}.",
        "- Discovery received only dates and quantities. Frozen labels, SKUs, taxonomy, product names, and generator amplitudes were excluded from model inputs.",
        "",
        "## Method",
        "",
        "- Linear trend is the nonseasonal model; one annual sine/cosine pair is the candidate seasonal model.",
        "- A seasonal direction requires delta BIC >= 6, a 95% effect interval excluding zero, at least two consistent significant annual blocks, and positive chronological holdout MAE gain whose 95% moving-block-bootstrap interval excludes zero.",
        "- NEUTRAL requires the trend-only model to be preferred, an effect interval spanning zero, no significant annual block, and no holdout gain.",
        "- Otherwise the result is UNKNOWN. Stock availability is not observed, so these remain sales-pattern classifications.",
        "",
        "## Final 36-month classification",
        "",
        "| Method | Accuracy | Coverage | Covered accuracy | UNKNOWN | Seasonal precision | False seasonal |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for name, values in (
        ("Evidence-gated discovery", method),
        ("Simple raw-season baseline", baseline),
    ):
        lines.append(
            f"| {name} | {values['accuracy']:.2%} | {values['coverage']:.2%} | "
            f"{values['covered_accuracy']:.2%} | {values['unknown_rate']:.2%} | "
            f"{values['seasonal_precision'] if values['seasonal_precision'] is not None else 0:.2%} | "
            f"{values['false_seasonal_assignments']} |"
        )
    lines.extend(
        [
            "",
            "### Performance by frozen hypothesis group",
            "",
            "| Actual group | Correct | Products | Recall |",
            "|---|---:|---:|---:|",
        ]
    )
    for group, values in method["per_group"].items():
        recall = values["correct"] / values["products"]
        lines.append(
            f"| {group} | {values['correct']} | {values['products']} | {recall:.2%} |"
        )
    lines.extend(
        [
            "",
            "## Chronological learning",
            "",
            "| Window | Accuracy | Coverage | UNKNOWN | False seasonal |",
            "|---:|---:|---:|---:|---:|",
        ]
    )
    for window, values in report["chronological_metrics"].items():
        lines.append(
            f"| {window} months | {values['accuracy']:.2%} | "
            f"{values['coverage']:.2%} | {values['unknown_rate']:.2%} | "
            f"{values['false_seasonal_assignments']} |"
        )
    holdout = report["future_year_confirmation"]
    lines.extend(
        [
            "",
            "## Untouched fourth-year confirmation",
            "",
            f"- Seasonal classifications tested: {holdout['tested_seasonal_classifications']}.",
            f"- Direction confirmed at p < 0.05: {holdout['confirmed']}.",
            f"- Confirmation rate: {holdout['confirmation_rate'] if holdout['confirmation_rate'] is not None else 0:.2%}.",
            "- NEUTRAL/UNKNOWN outputs are not treated as proven by a nonsignificant future-year test.",
            "",
            "## Acceptance assessment",
            "",
        ]
    )
    for name, passed in report["acceptance_checks"].items():
        lines.append(f"- {'PASS' if passed else 'FAIL'}: {name}.")
    lines.extend(
        [
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    lines.extend(
        [
            "",
            "## Frontend recommendation",
            "",
            "Keep this offline until real sales and stock-availability data are available. A future UI should show the learned label, UNKNOWN state, evidence gates, history window, last evaluation date, and direct-vs-prior knowledge separately; it must never silently overwrite the existing classification.",
        ]
    )
    return "\n".join(lines) + "\n"


def run(
    *,
    history_path: Path,
    frozen_path: Path,
) -> tuple[dict[str, object], list[dict[str, object]], list[dict[str, object]]]:
    frozen = load_dense_history(frozen_path)
    live = load_dense_history(history_path)
    frozen_verification = verify_frozen_history(frozen)
    live_verification = compare_live_history(frozen, live)
    if frozen_verification["status"] != "PASS":
        raise ValueError("frozen Stage 2.6 fixture failed integrity verification")
    if live_verification["status"] != "PASS":
        raise ValueError("live Stage 2.6 export does not match the frozen fixture")

    product_ids = sorted(live.units)
    all_dates = sorted({business_date for business_date, _ in live.quantities})
    history_start = all_dates[0]
    learner = SalesSeasonalityDiscoverer()

    # This phase is intentionally blind: only dense date/quantity arrays enter
    # learner methods. All results are frozen before labels are loaded below.
    blind_results: dict[tuple[int, str], object] = {}
    blind_baselines: dict[tuple[int, str], object] = {}
    for months in WINDOW_MONTHS:
        cutoff = window_cutoff(history_start, months)
        for product_id in product_ids:
            quantities = [
                float(live.quantities[(business_date, product_id)])
                for business_date in all_dates
            ]
            blind_results[(months, product_id)] = learner.discover(
                all_dates, quantities, cutoff=cutoff
            )
            blind_baselines[(months, product_id)] = learner.simple_baseline(
                all_dates, quantities, cutoff=cutoff
            )

    # Labels are joined only after every chronological classification is frozen.
    truth = {product.product_id: product.seasonal_group for product in PRODUCTS}
    product_metadata = {product.product_id: product for product in PRODUCTS}
    rows: list[dict[str, object]] = []
    chronological_metrics: dict[str, object] = {}
    for months in WINDOW_MONTHS:
        actual: list[str] = []
        predictions: list[str] = []
        baseline_predictions: list[str] = []
        cutoff = window_cutoff(history_start, months)
        for product_id in product_ids:
            result = blind_results[(months, product_id)]
            baseline = blind_baselines[(months, product_id)]
            product = product_metadata[product_id]
            actual.append(truth[product_id])
            predictions.append(result.classification.value)
            baseline_predictions.append(baseline.classification.value)
            rows.append(
                {
                    "window_months": months,
                    "cutoff": cutoff.isoformat(),
                    "product_id": product_id,
                    "sku": product.sku,
                    "product_name": product.product_name,
                    "unit": product.unit,
                    "frozen_hypothesis_label": truth[product_id],
                    **result.as_dict(),
                    "baseline_classification": baseline.classification.value,
                    "baseline_reason": baseline.reason,
                    "baseline_p_value": baseline.p_value,
                    "baseline_dry_minus_rainy_effect": baseline.dry_minus_rainy_daily_effect,
                    "classification_correct": (
                        result.classification.value == truth[product_id]
                    ),
                }
            )
        chronological_metrics[str(months)] = classification_metrics(
            actual, predictions
        )

    final_actual = [truth[product_id] for product_id in product_ids]
    final_predictions = [
        blind_results[(36, product_id)].classification.value
        for product_id in product_ids
    ]
    final_baseline_predictions = [
        blind_baselines[(36, product_id)].classification.value
        for product_id in product_ids
    ]
    method_metrics = classification_metrics(final_actual, final_predictions)
    baseline_metrics = classification_metrics(
        final_actual, final_baseline_predictions
    )

    training_cutoff = window_cutoff(history_start, 36)
    holdout_rows: list[dict[str, object]] = []
    for product_id in product_ids:
        quantities = [
            float(live.quantities[(business_date, product_id)])
            for business_date in all_dates
        ]
        classification = blind_results[(36, product_id)].classification
        confirmation = learner.confirm_on_future_holdout(
            all_dates,
            quantities,
            training_cutoff=training_cutoff,
            holdout_end=HISTORY_END,
            classification=classification,
        )
        product = product_metadata[product_id]
        holdout_rows.append(
            {
                "product_id": product_id,
                "sku": product.sku,
                "product_name": product.product_name,
                "learned_classification": classification.value,
                "frozen_hypothesis_label": truth[product_id],
                "training_cutoff": training_cutoff.isoformat(),
                "holdout_end": HISTORY_END.isoformat(),
                "holdout_dry_minus_rainy_effect": confirmation.dry_minus_rainy_daily_effect,
                "holdout_p_value": confirmation.p_value,
                "direction_confirmed": confirmation.direction_confirmed,
                "reason": confirmation.reason,
            }
        )
    tested = [
        row
        for row in holdout_rows
        if row["learned_classification"] in {"SUMMER", "RAINY"}
    ]
    confirmed = sum(row["direction_confirmed"] is True for row in tested)
    confirmation_rate = confirmed / len(tested) if tested else None

    acceptance_checks = {
        "live Stage 2.6 history exactly matches frozen fixture": True,
        "6- and 12-month windows abstain because fewer than two cycles exist": all(
            blind_results[(months, product_id)].classification
            is LearnedSeasonality.UNKNOWN
            for months in (6, 12)
            for product_id in product_ids
        ),
        "never-sold control remains UNKNOWN": blind_results[
            (36, "33000000-0000-4000-8000-000000000008")
        ].classification
        is LearnedSeasonality.UNKNOWN,
        "final accuracy is at least 70 percent": method_metrics["accuracy"] >= 0.70,
        "coverage is at least 50 percent": method_metrics["coverage"] >= 0.50,
        "seasonal precision is at least 80 percent": (
            method_metrics["seasonal_precision"] is not None
            and method_metrics["seasonal_precision"] >= 0.80
        ),
        "no more than one neutral product is falsely seasonal": method_metrics[
            "false_seasonal_assignments"
        ]
        <= 1,
        "method accuracy is no worse than simple baseline": method_metrics[
            "accuracy"
        ]
        >= baseline_metrics["accuracy"],
        "at least 75 percent of seasonal assignments confirm in untouched year": (
            confirmation_rate is not None and confirmation_rate >= 0.75
        ),
    }
    decision = "PASS" if all(acceptance_checks.values()) else "REVISE"
    report = {
        "stage": "2.7",
        "decision": decision,
        "input_verification": {
            "frozen_integrity": frozen_verification,
            "live_comparison": live_verification,
        },
        "blind_input_contract": {
            "inputs": ["business_date", "quantity", "cutoff"],
            "excluded_until_evaluation": [
                "frozen_hypothesis_label",
                "sku",
                "product_name",
                "category",
                "taxonomy",
                "generator_amplitudes",
            ],
            "stock_availability_observed": False,
        },
        "method_configuration": {
            "minimum_history_days": learner.MIN_HISTORY_DAYS,
            "minimum_positive_days": learner.MIN_POSITIVE_DAYS,
            "minimum_coverage_ratio": learner.MIN_COVERAGE_RATIO,
            "strong_bic_delta": learner.STRONG_BIC_DELTA,
            "confidence_level": learner.CONFIDENCE_LEVEL,
            "oos_days": learner.OOS_DAYS,
            "bootstrap_samples": learner.BLOCK_BOOTSTRAP_SAMPLES,
            "bootstrap_block_weeks": learner.BLOCK_BOOTSTRAP_WEEKS,
            "configuration_frozen_before_label_evaluation": True,
        },
        "chronological_metrics": chronological_metrics,
        "chronological_classifications": rows,
        "final_36_month_evaluation": {
            "discovery_method": method_metrics,
            "simple_baseline": baseline_metrics,
        },
        "final_misclassifications_and_abstentions": [
            {
                "sku": row["sku"],
                "product_name": row["product_name"],
                "frozen_hypothesis_label": row["frozen_hypothesis_label"],
                "classification": row["classification"],
                "reason": row["reason"],
            }
            for row in rows
            if row["window_months"] == 36
            and not row["classification_correct"]
        ],
        "future_year_confirmation": {
            "training_cutoff": training_cutoff.isoformat(),
            "holdout_start": (training_cutoff + date.resolution).isoformat(),
            "holdout_end": HISTORY_END.isoformat(),
            "tested_seasonal_classifications": len(tested),
            "confirmed": confirmed,
            "confirmation_rate": confirmation_rate,
            "rows": holdout_rows,
        },
        "acceptance_checks": acceptance_checks,
        "limitations": [
            "Frozen labels are simulation hypotheses, not verified Philippine hardware retail relationships.",
            "Sales alone cannot distinguish lost demand from stockouts because historical stock availability is unknown.",
            "A NEUTRAL result means the configured evidence gates favored no annual pattern; it does not prove demand can never be seasonal.",
            "UNKNOWN is intentional for inadequate, sparse, conflicting, or unstable evidence.",
            "The experiment does not modify existing classifications, forecasts, replenishment, Supabase, or Flutter.",
        ],
    }
    return report, rows, holdout_rows


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run blind Stage 2.7 sales seasonality discovery"
    )
    parser.add_argument(
        "--history",
        type=Path,
        default=ROOT.parent / "database" / "stage26_live_history.csv",
    )
    parser.add_argument(
        "--frozen",
        type=Path,
        default=ROOT / "simulation_reports" / "expanded_seasonal_daily_demand.csv",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "simulation_reports" / "stage27",
    )
    args = parser.parse_args()
    report, rows, holdout_rows = run(
        history_path=args.history,
        frozen_path=args.frozen,
    )
    output = args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    (output / "stage27_sales_seasonality.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output / "STAGE27_SALES_SEASONALITY_REPORT.md").write_text(
        _render_report(report), encoding="utf-8"
    )
    _write_csv(output / "product_classifications.csv", rows)
    _write_csv(
        output / "chronological_replay.csv",
        [
            {
                key: value
                for key, value in row.items()
                if key
                in {
                    "window_months",
                    "cutoff",
                    "sku",
                    "product_name",
                    "frozen_hypothesis_label",
                    "classification",
                    "evidence_strength",
                    "reason",
                    "delta_bic_seasonal_vs_trend",
                    "oos_mae_gain",
                    "oos_gain_ci_low",
                    "oos_gain_ci_high",
                    "cycle_directions",
                    "classification_correct",
                }
            }
            for row in rows
        ],
    )
    _write_csv(output / "future_year_confirmation.csv", holdout_rows)
    confusion_rows = _confusion_rows(
        "discovery_method",
        report["final_36_month_evaluation"]["discovery_method"],
    ) + _confusion_rows(
        "simple_baseline",
        report["final_36_month_evaluation"]["simple_baseline"],
    )
    _write_csv(output / "confusion_matrix.csv", confusion_rows)
    print(
        json.dumps(
            {
                "decision": report["decision"],
                "accuracy": report["final_36_month_evaluation"][
                    "discovery_method"
                ]["accuracy"],
                "coverage": report["final_36_month_evaluation"][
                    "discovery_method"
                ]["coverage"],
                "output_dir": str(output),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
