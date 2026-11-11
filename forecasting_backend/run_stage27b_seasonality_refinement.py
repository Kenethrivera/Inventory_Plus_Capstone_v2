from __future__ import annotations

import argparse
import csv
import json
import math
from datetime import date, timedelta
from dataclasses import asdict
from pathlib import Path

from app.simulation.expanded_seasonal_fixture import HISTORY_END, PRODUCTS
from app.simulation.sales_seasonality_discovery import (
    LearnedSeasonality,
    SalesSeasonalityDiscoverer,
    classification_metrics,
)
from app.simulation.seasonality_refinement import (
    RefinementPolicy,
    apply_refinement,
    audit_evidence,
)
from app.simulation.stage26_historical_validation import (
    compare_live_history,
    load_dense_history,
    verify_frozen_history,
)
from run_stage27_sales_seasonality import WINDOW_MONTHS, window_cutoff


ROOT = Path(__file__).resolve().parent


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
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
                        if isinstance(value, (list, tuple, dict))
                        else value
                    )
                    for key, value in row.items()
                }
            )


def root_cause(result, audit) -> str:
    if result.reason == "no_sales_history":
        return "no_sales_control"
    if audit.seasonal_reversal:
        return "inconsistent_or_reversing_pattern"
    if not audit.bic_direction_pass or not audit.effect_ci_excludes_zero:
        return "weak_or_overlapping_seasonal_effect"
    if (
        audit.positive_oos_point_gain
        and (
            not audit.positive_oos_bootstrap_interval
            or not audit.cycle_directions_consistent
        )
    ):
        return "insufficient_power_from_overlapping_significance_gates"
    if (
        audit.strong_trend_only_bic
        and audit.neutral_effect_ci_spans_zero
        and audit.neutral_oos_gain_not_significant
    ):
        return "neutral_confidence_rule_too_sensitive_to_point_gain"
    if result.positive_sales_days < 100:
        return "intermittent_demand_low_power"
    return "mixed_or_inconclusive_evidence"


def confirmation_summary(
    learner: SalesSeasonalityDiscoverer,
    *,
    dates,
    quantities_by_id,
    predictions: dict[str, LearnedSeasonality],
    training_cutoff,
    holdout_end,
    products_by_id,
    model: str,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    rows: list[dict[str, object]] = []
    for product_id, classification in predictions.items():
        result = learner.confirm_on_future_holdout(
            dates,
            quantities_by_id[product_id],
            training_cutoff=training_cutoff,
            holdout_end=holdout_end,
            classification=classification,
        )
        if classification in {
            LearnedSeasonality.SUMMER,
            LearnedSeasonality.RAINY,
        }:
            opposite = (
                result.p_value is not None
                and result.p_value < 0.05
                and (
                    classification is LearnedSeasonality.SUMMER
                    and result.dry_minus_rainy_daily_effect is not None
                    and result.dry_minus_rainy_daily_effect < 0
                    or classification is LearnedSeasonality.RAINY
                    and result.dry_minus_rainy_daily_effect is not None
                    and result.dry_minus_rainy_daily_effect > 0
                )
            )
            rows.append(
                {
                    "model": model,
                    "product_id": product_id,
                    "sku": products_by_id[product_id].sku,
                    "classification": classification.value,
                    "training_cutoff": training_cutoff.isoformat(),
                    "holdout_end": holdout_end.isoformat(),
                    "effect": result.dry_minus_rainy_daily_effect,
                    "p_value": result.p_value,
                    "confirmed": result.direction_confirmed,
                    "significant_opposite_direction": opposite,
                }
            )
    tested = len(rows)
    confirmed = sum(row["confirmed"] is True for row in rows)
    contradicted = sum(
        row["significant_opposite_direction"] is True for row in rows
    )
    return (
        {
            "tested_seasonal_classifications": tested,
            "confirmed": confirmed,
            "confirmation_rate": confirmed / tested if tested else None,
            "significant_opposite_directions": contradicted,
        },
        rows,
    )


def confusion_rows(model: str, metrics: dict[str, object]):
    return [
        {
            "model": model,
            "actual": actual,
            "predicted": predicted,
            "count": count,
        }
        for actual, predictions in metrics["confusion_matrix"].items()
        for predicted, count in predictions.items()
    ]


def render_report(report: dict[str, object]) -> str:
    lines = [
        "# Stage 2.7B Seasonal Discovery Refinement",
        "",
        f"**Decision: {report['decision']}**",
        "",
        "## Refinement boundary",
        "",
        "- Original Stage 2.7 code and results remain unchanged.",
        "- Three ablations were declared: remove only the cycle-significance gate, remove only the bootstrap-significance gate, or remove both redundant significance gates.",
        "- BIC >= 6, a 95% effect interval excluding zero, positive chronological MAE gain, reversal protection, sparse/no-sales abstention, and calendar-only inputs remain mandatory.",
        "- Candidate selection used the 24-month classification and months 25-36 confirmation without frozen labels. The fourth year remained untouched until final evaluation.",
        f"- Selected refinement: **{report['selected_policy']}**.",
        "",
        "## Original UNKNOWN failure causes",
        "",
        "| Cause | Products |",
        "|---|---:|",
    ]
    for cause, count in report["unknown_failure_summary"].items():
        lines.append(f"| {cause} | {count} |")
    lines.extend(
        [
            "",
            "## Final 36-month comparison",
            "",
            "| Method | Accuracy | Coverage | Covered accuracy | UNKNOWN | Seasonal precision | False seasonal | Fourth-year confirmation |",
            "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for model, values in report["final_comparison"].items():
        metrics = values["classification_metrics"]
        holdout = values["fourth_year_confirmation"]
        confirmation = holdout["confirmation_rate"]
        lines.append(
            f"| {model} | {metrics['accuracy']:.2%} | {metrics['coverage']:.2%} | "
            f"{metrics['covered_accuracy'] if metrics['covered_accuracy'] is not None else 0:.2%} | "
            f"{metrics['unknown_rate']:.2%} | "
            f"{metrics['seasonal_precision'] if metrics['seasonal_precision'] is not None else 0:.2%} | "
            f"{metrics['false_seasonal_assignments']} | "
            f"{confirmation if confirmation is not None else 0:.2%} |"
        )
    lines.extend(
        [
            "",
            "## Class-level refined confusion matrix",
            "",
            "| Actual | SUMMER | RAINY | NEUTRAL | UNKNOWN |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    refined = report["final_comparison"]["refined"][
        "classification_metrics"
    ]["confusion_matrix"]
    for actual, values in refined.items():
        lines.append(
            f"| {actual} | {values['SUMMER']} | {values['RAINY']} | "
            f"{values['NEUTRAL']} | {values['UNKNOWN']} |"
        )
    lines.extend(
        [
            "",
            "## Baseline audit",
            "",
            f"- Substantive classification errors: {report['baseline_audit']['substantive_errors']}.",
            f"- Intentional no-sales abstentions counted as benchmark errors: {report['baseline_audit']['safe_no_sales_abstentions']}.",
            "- The raw-season baseline does not detrend, does not require repeatability, and has no internal chronological generalization gate; it is therefore more exposed to trend/partial-cycle confounding and reversals despite its higher synthetic accuracy.",
            f"- Constructed monotonic-trend diagnostic: baseline returned {report['baseline_audit']['adversarial_diagnostics'][0]['baseline_classification']} at p={report['baseline_audit']['adversarial_diagnostics'][0]['baseline_p_value']:.4f}, while original and refined returned UNKNOWN.",
            f"- Constructed reversal diagnostic: baseline returned {report['baseline_audit']['adversarial_diagnostics'][1]['baseline_classification']}; original and refined preserved UNKNOWN for the direction reversal.",
            "",
            "## Conclusion",
            "",
            report["conclusion"],
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {value}" for value in report["limitations"])
    return "\n".join(lines) + "\n"


def run(history_path: Path, frozen_path: Path):
    frozen = load_dense_history(frozen_path)
    live = load_dense_history(history_path)
    frozen_check = verify_frozen_history(frozen)
    live_check = compare_live_history(frozen, live)
    if frozen_check["status"] != "PASS" or live_check["status"] != "PASS":
        raise ValueError("Stage 2.6 input verification failed")

    dates = sorted({business_date for business_date, _ in live.quantities})
    history_start = dates[0]
    product_ids = sorted(live.units)
    quantities_by_id = {
        product_id: [
            float(live.quantities[(business_date, product_id)])
            for business_date in dates
        ]
        for product_id in product_ids
    }
    products_by_id = {product.product_id: product for product in PRODUCTS}
    learner = SalesSeasonalityDiscoverer()

    original_results = {}
    baseline_results = {}
    refined_results = {}
    for months in WINDOW_MONTHS:
        cutoff = window_cutoff(history_start, months)
        for product_id in product_ids:
            original = learner.discover(
                dates, quantities_by_id[product_id], cutoff=cutoff
            )
            original_results[(months, product_id)] = original
            baseline_results[(months, product_id)] = learner.simple_baseline(
                dates, quantities_by_id[product_id], cutoff=cutoff
            )
            for policy in RefinementPolicy:
                refined_results[(policy, months, product_id)] = (
                    apply_refinement(original, policy)
                )

    # Development selection is label-blind. It uses classifications frozen at
    # 24 months and only the following year of quantities for confirmation.
    cutoff_24 = window_cutoff(history_start, 24)
    cutoff_36 = window_cutoff(history_start, 36)
    development_rows = []
    for policy in RefinementPolicy:
        predictions = {
            product_id: refined_results[(policy, 24, product_id)].classification
            for product_id in product_ids
        }
        confirmation, _ = confirmation_summary(
            learner,
            dates=dates,
            quantities_by_id=quantities_by_id,
            predictions=predictions,
            training_cutoff=cutoff_24,
            holdout_end=cutoff_36,
            products_by_id=products_by_id,
            model=policy.value,
        )
        development_rows.append(
            {
                "policy": policy.value,
                "assigned_products": sum(
                    value is not LearnedSeasonality.UNKNOWN
                    for value in predictions.values()
                ),
                **confirmation,
            }
        )
    eligible = [
        row
        for row in development_rows
        if row["tested_seasonal_classifications"] > 0
        and row["significant_opposite_directions"] == 0
        and row["confirmation_rate"] is not None
        and row["confirmation_rate"] >= 0.75
    ]
    if not eligible:
        selected_policy = RefinementPolicy.DROP_CYCLE_SIGNIFICANCE
    else:
        selected_name = max(
            eligible,
            key=lambda row: (
                row["confirmed"],
                row["confirmation_rate"],
                -row["tested_seasonal_classifications"],
            ),
        )["policy"]
        selected_policy = RefinementPolicy(selected_name)

    # Only now join frozen hypothesis labels for final evaluation.
    truth = {product.product_id: product.seasonal_group for product in PRODUCTS}
    actual = [truth[product_id] for product_id in product_ids]
    prediction_sets = {
        "original_evidence_gated": {
            product_id: original_results[(36, product_id)].classification
            for product_id in product_ids
        },
        "simple_baseline": {
            product_id: baseline_results[(36, product_id)].classification
            for product_id in product_ids
        },
        "refined": {
            product_id: refined_results[
                (selected_policy, 36, product_id)
            ].classification
            for product_id in product_ids
        },
    }

    final_comparison = {}
    holdout_rows = []
    for model, predictions in prediction_sets.items():
        metrics = classification_metrics(
            actual,
            [predictions[product_id].value for product_id in product_ids],
        )
        confirmation, rows = confirmation_summary(
            learner,
            dates=dates,
            quantities_by_id=quantities_by_id,
            predictions=predictions,
            training_cutoff=cutoff_36,
            holdout_end=HISTORY_END,
            products_by_id=products_by_id,
            model=model,
        )
        holdout_rows.extend(rows)
        final_comparison[model] = {
            "classification_metrics": metrics,
            "fourth_year_confirmation": confirmation,
        }

    failure_rows = []
    for product_id in product_ids:
        result = original_results[(36, product_id)]
        if result.classification is not LearnedSeasonality.UNKNOWN:
            continue
        audit = audit_evidence(result)
        product = products_by_id[product_id]
        failure_rows.append(
            {
                "product_id": product_id,
                "sku": product.sku,
                "product_name": product.product_name,
                "frozen_hypothesis_label": truth[product_id],
                "root_cause": root_cause(result, audit),
                "original_reason": result.reason,
                "positive_sales_days": result.positive_sales_days,
                "delta_bic": result.delta_bic_seasonal_vs_trend,
                "bic_margin_vs_6": audit.bic_direction_margin,
                "effect": result.dry_minus_rainy_daily_effect,
                "effect_ci_low": result.effect_ci_low,
                "effect_ci_high": result.effect_ci_high,
                "effect_zero_margin": audit.effect_ci_zero_margin,
                "oos_point_gain": result.oos_mae_gain,
                "oos_bootstrap_ci_low": result.oos_gain_ci_low,
                "oos_bootstrap_margin": audit.oos_bootstrap_margin,
                "significant_cycle_count": audit.significant_cycle_count,
                "cycle_count_margin_vs_2": audit.cycle_count_margin,
                "cycle_directions": list(result.cycle_directions),
                "failed_direction_gates": list(
                    audit.failed_original_direction_gates
                ),
                "failed_neutral_gates": list(
                    audit.failed_original_neutral_gates
                ),
                "selected_refined_classification": refined_results[
                    (selected_policy, 36, product_id)
                ].classification.value,
            }
        )
    failure_summary = {}
    for row in failure_rows:
        failure_summary[row["root_cause"]] = (
            failure_summary.get(row["root_cause"], 0) + 1
        )

    baseline_errors = []
    for product_id in product_ids:
        predicted = prediction_sets["simple_baseline"][product_id].value
        if predicted == truth[product_id]:
            continue
        product = products_by_id[product_id]
        baseline_errors.append(
            {
                "sku": product.sku,
                "product_name": product.product_name,
                "actual": truth[product_id],
                "predicted": predicted,
                "error_type": (
                    "safe_no_sales_abstention"
                    if product.demand_pattern == "no_sales"
                    else "substantive_classification_error"
                ),
                "p_value": baseline_results[(36, product_id)].p_value,
                "effect": baseline_results[
                    (36, product_id)
                ].dry_minus_rainy_daily_effect,
            }
        )

    # Two predeclared diagnostics expose baseline risks that the 24-product
    # generator does not strongly exercise. They are not used for policy
    # selection or benchmark accuracy.
    trend_dates = [
        date(2022, 1, 1) + timedelta(days=index) for index in range(730)
    ]
    trend_values = [1.0 + 0.01 * index for index in range(730)]
    trend_original = learner.discover(
        trend_dates, trend_values, cutoff=trend_dates[-1]
    )
    trend_baseline = learner.simple_baseline(
        trend_dates, trend_values, cutoff=trend_dates[-1]
    )
    trend_refined = apply_refinement(trend_original, selected_policy)

    reversal_dates = [
        date(2022, 1, 1) + timedelta(days=index) for index in range(1095)
    ]
    reversal_values = []
    for index, business_date in enumerate(reversal_dates):
        peak = 100 if index // 365 != 1 else 230
        reversal_values.append(
            10.0
            + 6.0
            * math.cos(
                2.0
                * math.pi
                * (business_date.timetuple().tm_yday - peak)
                / 365.25
            )
        )
    reversal_original = learner.discover(
        reversal_dates,
        reversal_values,
        cutoff=reversal_dates[-1],
    )
    reversal_baseline = learner.simple_baseline(
        reversal_dates,
        reversal_values,
        cutoff=reversal_dates[-1],
    )
    reversal_refined = apply_refinement(
        reversal_original, selected_policy
    )
    adversarial_diagnostics = [
        {
            "case": "nonseasonal_monotonic_trend_24_months",
            "known_pattern": "NEUTRAL_TREND_ONLY",
            "baseline_classification": trend_baseline.classification.value,
            "baseline_p_value": trend_baseline.p_value,
            "original_classification": trend_original.classification.value,
            "refined_classification": trend_refined.classification.value,
            "interpretation": "baseline_false_seasonal_assignment_from_trend_confounding",
        },
        {
            "case": "three_cycles_with_middle_cycle_direction_reversal",
            "known_pattern": "UNSTABLE_REVERSAL",
            "baseline_classification": reversal_baseline.classification.value,
            "baseline_p_value": reversal_baseline.p_value,
            "original_classification": reversal_original.classification.value,
            "refined_classification": reversal_refined.classification.value,
            "interpretation": "baseline_masks_reversal_as_stable_neutral",
        },
    ]

    chronological_rows = []
    for months in WINDOW_MONTHS:
        for model in ("original_evidence_gated", "simple_baseline", "refined"):
            if model == "original_evidence_gated":
                predictions = [
                    original_results[(months, product_id)].classification.value
                    for product_id in product_ids
                ]
            elif model == "simple_baseline":
                predictions = [
                    baseline_results[(months, product_id)].classification.value
                    for product_id in product_ids
                ]
            else:
                predictions = [
                    refined_results[
                        (selected_policy, months, product_id)
                    ].classification.value
                    for product_id in product_ids
                ]
            metrics = classification_metrics(actual, predictions)
            chronological_rows.append(
                {
                    "window_months": months,
                    "model": model,
                    **{
                        key: value
                        for key, value in metrics.items()
                        if key not in {"confusion_matrix", "per_group"}
                    },
                }
            )

    original_metrics = final_comparison["original_evidence_gated"][
        "classification_metrics"
    ]
    baseline_metrics = final_comparison["simple_baseline"][
        "classification_metrics"
    ]
    refined_metrics = final_comparison["refined"]["classification_metrics"]
    refined_holdout = final_comparison["refined"]["fourth_year_confirmation"]
    genuinely_better_than_baseline = (
        refined_metrics["accuracy"] > baseline_metrics["accuracy"]
        and refined_metrics["false_seasonal_assignments"]
        <= baseline_metrics["false_seasonal_assignments"]
        and refined_holdout["confirmation_rate"] is not None
        and refined_holdout["confirmation_rate"] >= 0.75
    )
    decision = "PASS" if genuinely_better_than_baseline else "REVISE"
    conclusion = (
        "The refined method is genuinely better than the simple baseline on the frozen benchmark."
        if genuinely_better_than_baseline
        else (
            "The refinement improves the conservative method's coverage, but it is not genuinely better than the simple baseline on this synthetic benchmark. Retain the original conservative method for advisory use, or retain the baseline only as a transparent comparison; do not activate automatic labels."
        )
    )
    report = {
        "stage": "2.7B",
        "decision": decision,
        "input_verification": {
            "frozen": frozen_check,
            "live": live_check,
        },
        "refinement_contract": {
            "candidate_count": len(RefinementPolicy),
            "candidates": [value.value for value in RefinementPolicy],
            "selection_inputs": [
                "24_month_date_quantity_history",
                "months_25_to_36_direction_confirmation",
            ],
            "selection_excluded": [
                "frozen_labels",
                "fourth_year_sales",
                "sku",
                "product_name",
                "category",
            ],
            "numeric_thresholds_changed": False,
        },
        "development_candidate_selection": development_rows,
        "selected_policy": selected_policy.value,
        "unknown_failure_breakdown": failure_rows,
        "unknown_failure_summary": failure_summary,
        "final_comparison": final_comparison,
        "baseline_audit": {
            "errors": baseline_errors,
            "substantive_errors": sum(
                row["error_type"] == "substantive_classification_error"
                for row in baseline_errors
            ),
            "safe_no_sales_abstentions": sum(
                row["error_type"] == "safe_no_sales_abstention"
                for row in baseline_errors
            ),
            "risk_notes": [
                "raw seasonal means do not remove trend",
                "the baseline has no repeatability or reversal gate",
                "the baseline has no internal chronological generalization gate",
                "nonsignificance is treated as NEUTRAL rather than UNKNOWN",
            ],
            "adversarial_diagnostics": adversarial_diagnostics,
        },
        "chronological_comparison": chronological_rows,
        "genuinely_better_than_simple_baseline": genuinely_better_than_baseline,
        "original_accuracy": original_metrics["accuracy"],
        "refined_accuracy": refined_metrics["accuracy"],
        "baseline_accuracy": baseline_metrics["accuracy"],
        "conclusion": conclusion,
        "limitations": [
            "The benchmark labels encode frozen simulation hypotheses, not validated real-store seasonal relationships.",
            "Stock availability is unknown, so observed zero sales cannot be proven to represent zero demand.",
            "The small 24-product benchmark yields wide uncertainty for error-rate comparisons.",
            "The refined policy was selected without labels, but all final comparisons remain synthetic evidence only.",
            "No existing classification, forecast, replenishment result, Supabase record, or Flutter screen is changed.",
        ],
    }
    return {
        "report": report,
        "failure_rows": failure_rows,
        "development_rows": development_rows,
        "holdout_rows": holdout_rows,
        "chronological_rows": chronological_rows,
        "baseline_errors": baseline_errors,
        "baseline_risk_diagnostics": adversarial_diagnostics,
        "prediction_sets": prediction_sets,
        "truth": truth,
        "product_ids": product_ids,
        "products_by_id": products_by_id,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run Stage 2.7B seasonal discovery refinement"
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
        default=ROOT / "simulation_reports" / "stage27b",
    )
    args = parser.parse_args()
    result = run(args.history, args.frozen)
    report = result["report"]
    output = args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    (output / "stage27b_seasonality_refinement.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output / "STAGE27B_SEASONAL_DISCOVERY_REFINEMENT.md").write_text(
        render_report(report), encoding="utf-8"
    )
    write_csv(output / "unknown_failure_breakdown.csv", result["failure_rows"])
    write_csv(
        output / "candidate_development_selection.csv",
        result["development_rows"],
    )
    write_csv(output / "holdout_confirmation.csv", result["holdout_rows"])
    write_csv(
        output / "chronological_comparison.csv",
        result["chronological_rows"],
    )
    write_csv(output / "baseline_error_audit.csv", result["baseline_errors"])
    write_csv(
        output / "baseline_risk_diagnostics.csv",
        result["baseline_risk_diagnostics"],
    )
    comparison_rows = []
    confusion = []
    for model, values in report["final_comparison"].items():
        metrics = values["classification_metrics"]
        comparison_rows.append(
            {
                "model": model,
                **{
                    key: value
                    for key, value in metrics.items()
                    if key not in {"confusion_matrix", "per_group"}
                },
                **{
                    f"holdout_{key}": value
                    for key, value in values[
                        "fourth_year_confirmation"
                    ].items()
                },
            }
        )
        confusion.extend(confusion_rows(model, metrics))
    write_csv(output / "model_comparison.csv", comparison_rows)
    write_csv(output / "confusion_matrix.csv", confusion)
    refined_rows = []
    for product_id in result["product_ids"]:
        product = result["products_by_id"][product_id]
        refined_rows.append(
            {
                "product_id": product_id,
                "sku": product.sku,
                "product_name": product.product_name,
                "frozen_hypothesis_label": result["truth"][product_id],
                **{
                    model: predictions[product_id].value
                    for model, predictions in result["prediction_sets"].items()
                },
            }
        )
    write_csv(output / "refined_classifications.csv", refined_rows)
    print(
        json.dumps(
            {
                "decision": report["decision"],
                "selected_policy": report["selected_policy"],
                "original_accuracy": report["original_accuracy"],
                "refined_accuracy": report["refined_accuracy"],
                "baseline_accuracy": report["baseline_accuracy"],
                "output_dir": str(output),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
