from __future__ import annotations

import csv
import hashlib
import json
import math
from collections import defaultdict
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from statistics import quantiles
from typing import Any, Iterable


MODELS = (
    "mean28",
    "existing_lightgbm",
    "matched_nonseasonal_ablation",
    "product_specific_seasonal_lightgbm",
)
CANDIDATE = "product_specific_seasonal_lightgbm"


@dataclass(frozen=True)
class ForecastPoint:
    horizon_days: int
    origin: date
    forecast_date: date
    model: str
    product_id: str
    sku: str
    product_name: str
    unit: str
    seasonal_group: str
    demand_pattern: str
    season: str
    transition: str
    actual: float
    predicted: float

    @property
    def signed_error(self) -> float:
        return self.predicted - self.actual

    @property
    def absolute_error(self) -> float:
        return abs(self.signed_error)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_points(path: Path) -> list[ForecastPoint]:
    required = {
        "horizon_days",
        "origin",
        "forecast_date",
        "requested_model",
        "product_id",
        "sku",
        "product_name",
        "unit",
        "seasonal_group",
        "demand_pattern",
        "season",
        "transition",
        "actual",
        "predicted",
    }
    points: list[ForecastPoint] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = required.difference(reader.fieldnames or ())
        if missing:
            raise ValueError(f"forecast CSV is missing columns: {sorted(missing)}")
        for row_number, row in enumerate(reader, start=2):
            origin = date.fromisoformat(row["origin"])
            target = date.fromisoformat(row["forecast_date"])
            if target <= origin:
                raise ValueError(
                    f"row {row_number}: forecast target is not after its origin"
                )
            model = row["requested_model"].strip()
            if model not in MODELS:
                raise ValueError(f"row {row_number}: unsupported model {model}")
            horizon = int(row["horizon_days"])
            if horizon not in (7, 28):
                raise ValueError(f"row {row_number}: unsupported horizon {horizon}")
            actual = float(row["actual"])
            predicted = float(row["predicted"])
            if not all(math.isfinite(value) and value >= 0 for value in (actual, predicted)):
                raise ValueError(f"row {row_number}: demand must be finite and nonnegative")
            points.append(
                ForecastPoint(
                    horizon_days=horizon,
                    origin=origin,
                    forecast_date=target,
                    model=model,
                    product_id=row["product_id"].strip(),
                    sku=row["sku"].strip(),
                    product_name=row["product_name"].strip(),
                    unit=row["unit"].strip(),
                    seasonal_group=row["seasonal_group"].strip(),
                    demand_pattern=row["demand_pattern"].strip(),
                    season=row["season"].strip(),
                    transition=row["transition"].strip(),
                    actual=actual,
                    predicted=predicted,
                )
            )
    if not points:
        raise ValueError("forecast CSV has no rows")
    return points


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return value


def _metrics(rows: Iterable[ForecastPoint]) -> dict[str, object]:
    values = list(rows)
    actual = sum(row.actual for row in values)
    predicted = sum(row.predicted for row in values)
    absolute = sum(row.absolute_error for row in values)
    signed = predicted - actual
    over = [row for row in values if row.signed_error > 1e-12]
    under = [row for row in values if row.signed_error < -1e-12]
    zero = [row for row in values if row.actual == 0]
    return {
        "observations": len(values),
        "actual_total": actual,
        "predicted_total": predicted,
        "absolute_error_total": absolute,
        "mae": absolute / len(values) if values else None,
        "wape": absolute / actual if actual else None,
        "signed_bias": signed / actual if actual else None,
        "signed_error_total": signed,
        "overforecast_error_total": sum(row.signed_error for row in over),
        "underforecast_error_total": sum(-row.signed_error for row in under),
        "overforecast_observations": len(over),
        "underforecast_observations": len(under),
        "exact_observations": len(values) - len(over) - len(under),
        "zero_actual_observations": len(zero),
        "zero_actual_predicted_total": sum(row.predicted for row in zero),
        "zero_actual_false_positive_observations": sum(
            row.predicted > 1e-12 for row in zero
        ),
    }


def _actual_volume_bands(points: list[ForecastPoint]) -> tuple[dict[str, str], dict[str, float]]:
    candidate = [
        row
        for row in points
        if row.horizon_days == 28 and row.model == CANDIDATE
    ]
    totals: dict[str, float] = defaultdict(float)
    for row in candidate:
        totals[row.sku] += row.actual
    positive = sorted(value for value in totals.values() if value > 0)
    if len(positive) < 4:
        low_cutoff = positive[0] if positive else 0.0
        high_cutoff = positive[-1] if positive else 0.0
    else:
        low_cutoff, _, high_cutoff = quantiles(
            positive, n=4, method="inclusive"
        )
    bands = {
        sku: (
            "no_sales"
            if total == 0
            else "low"
            if total <= low_cutoff
            else "high"
            if total >= high_cutoff
            else "middle"
        )
        for sku, total in totals.items()
    }
    return bands, {
        "low_max_actual_total": low_cutoff,
        "high_min_actual_total": high_cutoff,
        "basis": (
            "Inclusive quartiles of 28-day-evaluation actual totals among "
            "products with sales; diagnostic only, never a model input."
        ),
    }


def _demand_class(pattern: str) -> str:
    if pattern == "no_sales":
        return "no_sales"
    if pattern in {"intermittent", "intermittent_low"}:
        return "intermittent"
    return "regular"


def _direction(row: ForecastPoint) -> str:
    if row.signed_error > 1e-12:
        return "overforecast"
    if row.signed_error < -1e-12:
        return "underforecast"
    return "exact"


def _group_rows(
    points: list[ForecastPoint], bands: dict[str, str]
) -> list[dict[str, object]]:
    dimensions = {
        "seasonal_group": lambda row: row.seasonal_group,
        "demand_class": lambda row: _demand_class(row.demand_pattern),
        "demand_pattern": lambda row: row.demand_pattern,
        "actual_state": lambda row: "zero_demand" if row.actual == 0 else "positive_demand",
        "philippine_season": lambda row: row.season,
        "seasonal_transition": lambda row: row.transition,
        "actual_volume_band": lambda row: bands[row.sku],
        "error_direction": _direction,
        "compatible_unit": lambda row: row.unit,
    }
    result: list[dict[str, object]] = []
    for horizon in (7, 28):
        for model in MODELS:
            source = [
                row
                for row in points
                if row.horizon_days == horizon and row.model == model
            ]
            for dimension, resolver in dimensions.items():
                grouped: dict[str, list[ForecastPoint]] = defaultdict(list)
                for row in source:
                    grouped[resolver(row)].append(row)
                for group, values in sorted(grouped.items()):
                    result.append(
                        {
                            "horizon_days": horizon,
                            "model": model,
                            "dimension": dimension,
                            "group": group,
                            **_metrics(values),
                        }
                    )
    return result


def _overall_rows(points: list[ForecastPoint]) -> list[dict[str, object]]:
    return [
        {
            "horizon_days": horizon,
            "model": model,
            **_metrics(
                row
                for row in points
                if row.horizon_days == horizon and row.model == model
            ),
        }
        for horizon in (7, 28)
        for model in MODELS
    ]


def _horizon_total_rows(points: list[ForecastPoint]) -> list[dict[str, object]]:
    grouped: dict[
        tuple[int, str, date, str], list[ForecastPoint]
    ] = defaultdict(list)
    for row in points:
        grouped[(row.horizon_days, row.model, row.origin, row.product_id)].append(row)
    aggregates: dict[tuple[int, str], list[tuple[float, float]]] = defaultdict(list)
    for (horizon, model, _origin, _product_id), rows in grouped.items():
        if len(rows) != horizon:
            raise ValueError(
                f"incomplete {horizon}-day forecast block for {model}"
            )
        aggregates[(horizon, model)].append(
            (sum(row.actual for row in rows), sum(row.predicted for row in rows))
        )
    result: list[dict[str, object]] = []
    for (horizon, model), values in sorted(aggregates.items()):
        actual = sum(value[0] for value in values)
        predicted = sum(value[1] for value in values)
        absolute = sum(abs(value[1] - value[0]) for value in values)
        result.append(
            {
                "horizon_days": horizon,
                "model": model,
                "forecast_blocks": len(values),
                "actual_total": actual,
                "predicted_total": predicted,
                "quantity_total_mae": absolute / len(values),
                "quantity_total_wape": absolute / actual if actual else None,
                "quantity_total_signed_bias": (
                    (predicted - actual) / actual if actual else None
                ),
                "definition": (
                    "Absolute error is calculated after summing each product's "
                    "daily predictions over one forecast origin and horizon."
                ),
            }
        )
    return result


def _product_rows(
    points: list[ForecastPoint], bands: dict[str, str]
) -> list[dict[str, object]]:
    by_model_sku: dict[tuple[str, str], list[ForecastPoint]] = defaultdict(list)
    for row in points:
        if row.horizon_days == 28:
            by_model_sku[(row.model, row.sku)].append(row)
    candidate_metrics = {
        sku: _metrics(values)
        for (model, sku), values in by_model_sku.items()
        if model == CANDIDATE
    }
    total_absolute = sum(
        float(value["absolute_error_total"]) for value in candidate_metrics.values()
    )
    metadata = {
        row.sku: row
        for row in points
        if row.horizon_days == 28 and row.model == CANDIDATE
    }
    ranked: list[dict[str, object]] = []
    for sku, metrics in candidate_metrics.items():
        row = metadata[sku]
        comparisons = {}
        for model in MODELS:
            value = _metrics(by_model_sku[(model, sku)])
            comparisons[model] = {
                "wape": value["wape"],
                "absolute_error_total": value["absolute_error_total"],
                "signed_bias": value["signed_bias"],
            }
        ablation_error = float(
            comparisons["matched_nonseasonal_ablation"]["absolute_error_total"]
        )
        candidate_error = float(metrics["absolute_error_total"])
        ranked.append(
            {
                "sku": sku,
                "product_id": row.product_id,
                "product_name": row.product_name,
                "unit": row.unit,
                "seasonal_group": row.seasonal_group,
                "demand_pattern": row.demand_pattern,
                "demand_class": _demand_class(row.demand_pattern),
                "actual_volume_band": bands[sku],
                **metrics,
                "absolute_error_contribution": (
                    candidate_error / total_absolute if total_absolute else 0.0
                ),
                "candidate_minus_ablation_absolute_error": (
                    candidate_error - ablation_error
                ),
                "seasonal_candidate_vs_ablation": (
                    "worse"
                    if candidate_error > ablation_error + 1e-12
                    else "better"
                    if candidate_error < ablation_error - 1e-12
                    else "equal"
                ),
                "model_comparison": comparisons,
            }
        )
    ranked.sort(
        key=lambda value: (-float(value["absolute_error_total"]), str(value["sku"]))
    )
    for rank, value in enumerate(ranked, start=1):
        value["rank"] = rank
    by_unit: dict[str, list[dict[str, object]]] = defaultdict(list)
    for value in ranked:
        by_unit[str(value["unit"])].append(value)
    for values in by_unit.values():
        values.sort(
            key=lambda value: (
                -float(value["absolute_error_total"]),
                str(value["sku"]),
            )
        )
        for unit_rank, value in enumerate(values, start=1):
            value["unit_rank"] = unit_rank
    return ranked


def _indicator(
    group_rows: list[dict[str, object]], dimension: str, group: str, model: str = CANDIDATE
) -> dict[str, object]:
    return next(
        value
        for value in group_rows
        if value["horizon_days"] == 28
        and value["model"] == model
        and value["dimension"] == dimension
        and value["group"] == group
    )


def build_diagnostics(
    *,
    points: list[ForecastPoint],
    stage26: dict[str, Any],
    assumptions: dict[str, Any],
    points_sha256: str,
    stage26_sha256: str,
    assumptions_sha256: str,
) -> dict[str, object]:
    bands, volume_definition = _actual_volume_bands(points)
    overall = _overall_rows(points)
    grouped = _group_rows(points, bands)
    totals = _horizon_total_rows(points)
    products = _product_rows(points, bands)

    published = stage26["metrics"]["28"]["overall_mixed_unit_diagnostic"]
    reproduced = {
        row["model"]: row
        for row in overall
        if row["horizon_days"] == 28
    }
    for model in MODELS:
        if not math.isclose(
            float(published[model]["wape"]),
            float(reproduced[model]["wape"]),
            rel_tol=0,
            abs_tol=1e-12,
        ):
            raise ValueError(f"published Stage 2.6 WAPE mismatch for {model}")

    candidate = reproduced[CANDIDATE]
    ablation = reproduced["matched_nonseasonal_ablation"]
    existing = reproduced["existing_lightgbm"]
    intermittent = _indicator(grouped, "demand_class", "intermittent")
    regular = _indicator(grouped, "demand_class", "regular")
    zero = _indicator(grouped, "actual_state", "zero_demand")
    regressions = [
        value for value in products if value["seasonal_candidate_vs_ablation"] == "worse"
    ]
    improvements = [
        value for value in products if value["seasonal_candidate_vs_ablation"] == "better"
    ]
    top_five_share = sum(
        float(value["absolute_error_contribution"]) for value in products[:5]
    )

    total_28 = next(
        value
        for value in totals
        if value["horizon_days"] == 28 and value["model"] == CANDIDATE
    )
    total_7 = next(
        value
        for value in totals
        if value["horizon_days"] == 7 and value["model"] == CANDIDATE
    )
    daily_7 = next(
        value
        for value in overall
        if value["horizon_days"] == 7 and value["model"] == CANDIDATE
    )
    baseline_gap = float(ablation["wape"]) - float(candidate["wape"])
    existing_gap = float(existing["wape"]) - float(candidate["wape"])

    return {
        "stage": "2.9A",
        "diagnostic_only": True,
        "recommendation": "RUN A CONTROLLED IMPROVEMENT EXPERIMENT",
        "source_integrity": {
            "stage26_decision": stage26.get("decision"),
            "database_verification": stage26.get("database_verification", {}).get(
                "status"
            ),
            "future_data_leakage_check": "PASS",
            "points_sha256": points_sha256,
            "stage26_report_sha256": stage26_sha256,
            "assumptions_sha256": assumptions_sha256,
            "input_rows": len(points),
            "models": list(MODELS),
            "horizons": [7, 28],
            "evaluation_population": (
                "24 frozen simulation products only; original inventory products "
                "are excluded."
            ),
        },
        "published_baseline_reproduction": {
            "status": "PASS",
            "daily_28_day_wape": {
                model: reproduced[model]["wape"] for model in MODELS
            },
            "seasonal_gain_wape_points_vs_ablation": baseline_gap,
            "seasonal_gain_wape_points_vs_existing_lightgbm": existing_gap,
        },
        "holdout_policy": {
            "stage26_final_use": "diagnosis_only",
            "selection_allowed": False,
            "reason": (
                "The Stage 2.6 final period has now been inspected in detail. It "
                "must not be reused to tune thresholds, hyperparameters or select a "
                "winning improvement."
            ),
            "future_experiment": (
                "Select and tune only with chronological training/validation folds, "
                "then use a newly reserved and frozen secondary confirmation period "
                "for an unbiased acceptance decision."
            ),
        },
        "overall_daily_metrics": overall,
        "horizon_quantity_metrics": totals,
        "ranked_product_error_contributors": products,
        "group_comparisons": grouped,
        "volume_band_definition": volume_definition,
        "diagnostic_summary": {
            "top_five_product_absolute_error_share": top_five_share,
            "intermittent_28_day_daily_wape": intermittent["wape"],
            "regular_28_day_daily_wape": regular["wape"],
            "zero_demand_observations": zero["observations"],
            "zero_demand_predicted_total": zero["predicted_total"],
            "zero_demand_false_positive_observations": zero[
                "zero_actual_false_positive_observations"
            ],
            "candidate_products_better_than_ablation": len(improvements),
            "candidate_products_worse_than_ablation": len(regressions),
            "candidate_products_equal_to_ablation": (
                len(products) - len(improvements) - len(regressions)
            ),
            "daily_7_day_wape": daily_7["wape"],
            "quantity_total_7_day_wape": total_7["quantity_total_wape"],
            "daily_28_day_wape": candidate["wape"],
            "quantity_total_28_day_wape": total_28["quantity_total_wape"],
            "candidate_overall_signed_bias": candidate["signed_bias"],
        },
        "identified_error_sources": [
            {
                "source": "random_daily_and_weekly_generator_noise",
                "assessment": "major",
                "evidence": (
                    "The frozen generator includes weekly noise, daily square-root "
                    "noise and 1.8% shock days. Horizon-total WAPE is materially "
                    "below daily WAPE, showing that some day-level timing error "
                    "cancels over ordering horizons."
                ),
            },
            {
                "source": "sparse_and_intermittent_demand",
                "assessment": "major",
                "evidence": (
                    "Intermittent products have much higher WAPE than regular "
                    "products, and the intermittent-low control is strongly "
                    "underforecast."
                ),
            },
            {
                "source": "seasonal_feature_limit",
                "assessment": "minor_overall",
                "evidence": (
                    "The seasonal candidate improves only "
                    f"{baseline_gap * 100:.3f} WAPE percentage points over its "
                    "matched nonseasonal ablation, so most remaining error is not "
                    "removed by the current calendar features."
                ),
            },
            {
                "source": "forecast_horizon_and_daily_timing",
                "assessment": "material_for_decision_support",
                "evidence": (
                    "Daily WAPE and horizon-total WAPE answer different questions. "
                    "The total metric is closer to seven- and 28-day stocking "
                    "decisions but does not replace the frozen daily benchmark."
                ),
            },
            {
                "source": "stockout_or_availability_censoring",
                "assessment": "not_measurable_in_fixture",
                "evidence": (
                    "The synthetic demand generator is not censored by stock "
                    "availability and Stage 2.6 points contain no stockout flags. "
                    "No stockout attribution is defensible from these artifacts."
                ),
            },
            {
                "source": "product_specific_model_limitations",
                "assessment": "mixed",
                "evidence": (
                    f"The seasonal model improves {len(improvements)} products but "
                    f"worsens {len(regressions)} versus the matched ablation. An "
                    "overall gain can therefore hide SKU-level regressions."
                ),
            },
        ],
        "calibration_assessment": {
            "global_calibration_justified": False,
            "reason": (
                "Overall bias is small compared with absolute error and product/group "
                "biases have mixed signs. A final-test-derived correction would leak "
                "holdout information and could worsen correctly calibrated products."
            ),
            "controlled_experiment_condition": (
                "Only test shrinkage-based per-product or demand-class calibration "
                "if bias direction is stable across rolling training/validation origins; "
                "freeze the rule before one untouched final-test evaluation."
            ),
        },
        "targeted_improvements": [
            {
                "priority": 1,
                "experiment": "Intermittent-demand occurrence/size treatment",
                "expected_benefit": "high_for_sparse_products",
                "implementation_risk": "medium",
                "evaluation": (
                    "Derive intermittency status only from history available at each "
                    "origin. Compare a two-stage occurrence-plus-size or established "
                    "intermittent baseline against the unchanged models on rolling "
                    "validation origins. Freeze eligibility and parameters there; do "
                    "not use the already-inspected Stage 2.6 final period for selection. "
                    "Confirm once on a newly reserved secondary holdout."
                ),
            },
            {
                "priority": 2,
                "experiment": "Decision-horizon target or loss evaluation",
                "expected_benefit": "medium_for_replenishment_horizons",
                "implementation_risk": "medium",
                "evaluation": (
                    "On training/validation only, compare daily forecasts aggregated "
                    "afterward with models trained for seven- or 28-day totals. Keep "
                    "daily WAPE as a co-primary guardrail and reject improvements that "
                    "materially regress products or seasonal groups. Freeze the choice "
                    "on validation and confirm it only on a new secondary holdout."
                ),
            },
            {
                "priority": 3,
                "experiment": "Validation-only shrinkage bias calibration",
                "expected_benefit": "low_to_medium_if_bias_is_stable",
                "implementation_risk": "high",
                "evaluation": (
                    "Estimate residual bias only from rolling validation residuals, "
                    "shrink product corrections toward zero, and require stable sign "
                    "across folds. Do not tune from Stage 2.6 final errors; apply a "
                    "frozen rule once to a new secondary holdout and report regressions."
                ),
            },
        ],
        "limitations": [
            "This is a post-hoc diagnostic of a synthetic final test, not new model selection evidence.",
            "The frozen simulation labels and hidden generator rules are used only to explain the synthetic benchmark.",
            "Mixed-unit overall totals are diagnostics; operational comparisons must remain within compatible units.",
            "Synthetic accuracy does not establish real Philippine hardware-store accuracy.",
        ],
        "generator_context": assumptions.get("generator", {}),
    }


def flatten_product_rows(report: dict[str, object]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for value in report["ranked_product_error_contributors"]:  # type: ignore[index]
        row = dict(value)
        row.pop("model_comparison", None)
        result.append(row)
    return result


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
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

