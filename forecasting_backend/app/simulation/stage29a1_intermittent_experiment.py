from __future__ import annotations

import csv
import hashlib
import json
import math
import random
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path
from statistics import median
from typing import Any, Callable, Iterable

from app.data import DailyDemand
from app.forecasting import (
    HistoricalDemandDataset,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.forecasting.models import ForecastProduct
from app.forecasting.series import prepare_history
from app.seasonality import PhilippineSeasonResolver

from .expanded_seasonal_fixture import (
    LOCATION_ID,
    PRODUCTS,
    bounded_dataset,
    shared_context_registry,
)


MEAN28 = "mean28"
EXISTING = "existing_lightgbm"
SEASONAL = "seasonal_lightgbm"
TSB = "tsb_intermittent_baseline"
POLICY = "development_selected_product_policy"


@dataclass(frozen=True)
class TwoStageConfig:
    name: str
    n_estimators: int
    learning_rate: float
    num_leaves: int
    min_child_samples: int
    random_seed: int


@dataclass(frozen=True)
class ExperimentRealization:
    name: str
    seed: int
    datasets: tuple[HistoricalDemandDataset, ...]
    actual: dict[tuple[str, date], Decimal]
    demand_classes: dict[str, str]
    pretest_statistics: dict[str, dict[str, object]]


@dataclass(frozen=True)
class EvaluationPoint:
    realization: str
    requested_model: str
    origin: date
    forecast_date: date
    product_id: str
    sku: str
    product_name: str
    unit: str
    seasonal_group: str
    demand_class: str
    actual: float
    predicted: float

    @property
    def signed_error(self) -> float:
        return self.predicted - self.actual

    @property
    def absolute_error(self) -> float:
        return abs(self.signed_error)


def load_manifest(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("experiment manifest must be an object")
    if not value.get("frozen_before_final_evaluation"):
        raise ValueError("experiment manifest is not frozen")
    if value.get("development_seed") == value.get("independent_final_seed"):
        raise ValueError("development and final seeds must be independent")
    return value


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _uniform(seed: int, sku: str, business_date: date, stream: str) -> float:
    payload = f"{seed}|{sku}|{business_date.isoformat()}|{stream}".encode()
    digest = hashlib.md5(payload, usedforsecurity=False).hexdigest()
    return int(digest[:13], 16) / float(16**13)


def _season_curve(business_date: date, peak_day: int) -> float:
    day = business_date.timetuple().tm_yday
    return (1.0 + math.cos(2.0 * math.pi * (day - peak_day) / 365.25)) / 2.0


def _quantity(
    *,
    seed: int,
    product: Any,
    business_date: date,
    history_start: date,
    generator: dict[str, Any],
    variant: dict[str, Any],
) -> Decimal:
    baseline = float(product.baseline_daily) * float(variant["baseline_scale"])
    if baseline == 0:
        return Decimal("0")
    occurrence = min(
        1.0,
        float(product.intermittency_probability)
        * float(variant["occurrence_scale"]),
    )
    if _uniform(seed, product.sku, business_date, "gate") > occurrence:
        return Decimal("0")

    summer = _season_curve(business_date, 100)
    rainy = _season_curve(business_date, 230)
    if product.seasonal_group == "SUMMER":
        primary, secondary = summer, rainy
    elif product.seasonal_group == "RAINY":
        primary, secondary = rainy, summer
    else:
        primary, secondary = summer, rainy
    year_index = (business_date - history_start).days / 365.25
    trend = max(0.60, 1.0 + float(product.trend_per_year) * year_index)
    annual = float(generator["annual_strength_minimum"]) + float(
        generator["annual_strength_range"]
    ) * _uniform(seed, product.sku, date(business_date.year, 1, 1), "annual")
    seasonal = max(
        0.20,
        1.0
        + annual * float(product.primary_amplitude) * (2.0 * primary - 1.0)
        + float(product.secondary_amplitude) * (2.0 * secondary - 1.0),
    )
    weekday = (
        1.0 + float(product.weekend_effect)
        if business_date.weekday() >= 5
        else 1.0
    )
    week_start = business_date - timedelta(days=business_date.weekday())
    weekly_half = float(generator["weekly_noise_half_range"])
    weekly = 1.0 + (
        _uniform(seed, product.sku, week_start, "weekly") - 0.5
    ) * weekly_half * 2.0
    mean = baseline * trend * seasonal * weekday * weekly
    centered = sum(
        _uniform(seed, product.sku, business_date, f"daily_{index}")
        for index in range(3)
    ) - 1.5
    noisy = mean + centered * float(generator["daily_noise_scale"]) * float(
        variant["noise_scale"]
    ) * math.sqrt(max(mean, 0.1))
    shock_probability = float(generator["base_shock_probability"]) * float(
        variant["shock_probability_scale"]
    )
    if _uniform(seed, product.sku, business_date, "shock") < shock_probability:
        noisy += mean * (
            float(generator["shock_minimum_fraction"])
            + float(generator["shock_additional_fraction"])
            * _uniform(seed, product.sku, business_date, "shock_size")
        )
    step = float(product.quantity_step)
    rounded = max(0.0, math.floor(max(noisy, 0.0) / step + 0.5) * step)
    return Decimal(format(rounded, ".12g"))


def generate_realization(
    manifest: dict[str, Any], *, name: str, seed: int
) -> ExperimentRealization:
    start = date.fromisoformat(manifest["history_start"])
    end = date.fromisoformat(manifest["history_end"])
    pretest_end = date.fromisoformat(manifest["development_validation_start"]) - timedelta(
        days=1
    )
    variants = manifest["scenario_variants"]
    assignments = manifest["scenario_by_sku"]
    generator = manifest["generator"]
    datasets: list[HistoricalDemandDataset] = []
    actual: dict[tuple[str, date], Decimal] = {}
    classes: dict[str, str] = {}
    statistics: dict[str, dict[str, object]] = {}

    for product in PRODUCTS:
        variant_name = assignments[product.sku]
        variant = variants[variant_name]
        observations: list[DailyDemand] = []
        pretest_days = 0
        pretest_sales_days = 0
        pretest_quantity = Decimal("0")
        current = start
        while current <= end:
            quantity = _quantity(
                seed=seed,
                product=product,
                business_date=current,
                history_start=start,
                generator=generator,
                variant=variant,
            )
            actual[(product.product_id, current)] = quantity
            if current <= pretest_end:
                pretest_days += 1
                pretest_quantity += quantity
                pretest_sales_days += quantity > 0
            if quantity > 0:
                observations.append(
                    DailyDemand(
                        business_date=current,
                        location_id=LOCATION_ID,
                        product_id=product.product_id,
                        sku=product.sku,
                        product_name=product.product_name,
                        unit=product.unit,
                        quantity=quantity,
                        completed_order_count=1,
                    )
                )
            current += timedelta(days=1)
        frequency = pretest_sales_days / pretest_days if pretest_days else 0.0
        demand_class = (
            "no_sales"
            if pretest_sales_days == 0
            else "intermittent_low"
            if frequency < 0.5
            else "intermittent"
            if frequency < 0.8
            else "regular"
        )
        classes[product.product_id] = demand_class
        statistics[product.product_id] = {
            "sku": product.sku,
            "product_name": product.product_name,
            "unit": product.unit,
            "seasonal_group": product.seasonal_group,
            "scenario_variant": variant_name,
            "history_days": pretest_days,
            "sale_days": pretest_sales_days,
            "zero_sales_days": pretest_days - pretest_sales_days,
            "demand_frequency": frequency,
            "zero_sales_frequency": 1.0 - frequency,
            "historical_quantity": float(pretest_quantity),
            "demand_class": demand_class,
        }
        datasets.append(
            HistoricalDemandDataset.from_synthetic_observations(
                product=ForecastProduct(
                    location_id=LOCATION_ID,
                    product_id=product.product_id,
                    sku=product.sku,
                    product_name=product.product_name,
                    unit=product.unit,
                ),
                history_start=start,
                history_end=end,
                observations=observations,
            )
        )
    return ExperimentRealization(
        name=name,
        seed=seed,
        datasets=tuple(datasets),
        actual=actual,
        demand_classes=classes,
        pretest_statistics=statistics,
    )


class TSBIntermittentBaseline:
    def __init__(self, *, occurrence_smoothing: float, quantity_smoothing: float):
        self.occurrence_smoothing = occurrence_smoothing
        self.quantity_smoothing = quantity_smoothing

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[float]:
        values = [float(day.sales_quantity) for day in prepare_history(dataset).days]
        first = next((index for index, value in enumerate(values) if value > 0), None)
        if first is None:
            return [0.0] * horizon_days
        probability = 1.0
        size = values[first]
        for value in values[first + 1 :]:
            occurred = float(value > 0)
            probability += self.occurrence_smoothing * (occurred - probability)
            if occurred:
                size += self.quantity_smoothing * (value - size)
        expected = max(0.0, probability * size)
        return [expected] * horizon_days


class TwoStageOccurrenceQuantityForecaster:
    def __init__(self, *, config: TwoStageConfig) -> None:
        self.config = config
        self.registry = shared_context_registry()
        self.resolver = PhilippineSeasonResolver()
        self._feature_builder = ProductSpecificSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=True,
            config=LightGBMConfig(random_seed=config.random_seed),
            resolver=self.resolver,
        )

    def _features(
        self,
        *,
        values: list[float],
        occurrences: list[float],
        index: int,
        target_date: date,
        dataset: HistoricalDemandDataset,
    ) -> list[float]:
        context = self.registry.require(dataset.product.product_id)
        base = self._feature_builder._feature_row(
            values=values,
            index=index,
            target_date=target_date,
            location_id=dataset.product.location_id,
            context=context,
        )
        return [
            *base,
            occurrences[index - 1],
            occurrences[index - 7],
            occurrences[index - 14],
            occurrences[index - 28],
            sum(occurrences[index - 7 : index]) / 7.0,
            sum(occurrences[index - 28 : index]) / 28.0,
        ]

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[float]:
        prepared = prepare_history(dataset)
        values = [float(day.model_value) for day in prepared.days]
        occurrences = [float(day.sales_quantity > 0) for day in prepared.days]
        if not any(occurrences):
            return [0.0] * horizon_days
        features: list[list[float]] = []
        occurrence_targets: list[int] = []
        quantity_features: list[list[float]] = []
        quantity_targets: list[float] = []
        for index in range(28, len(prepared.days)):
            day = prepared.days[index]
            if day.is_stockout_censored:
                continue
            row = self._features(
                values=values,
                occurrences=occurrences,
                index=index,
                target_date=day.business_date,
                dataset=dataset,
            )
            target = float(day.sales_quantity)
            features.append(row)
            occurrence_targets.append(int(target > 0))
            if target > 0:
                quantity_features.append(row)
                quantity_targets.append(target)

        classifier: Any | None = None
        occurrence_constant: float | None = None
        if len(set(occurrence_targets)) < 2:
            occurrence_constant = float(occurrence_targets[0])
        else:
            from lightgbm import LGBMClassifier

            classifier = LGBMClassifier(
                objective="binary",
                n_estimators=self.config.n_estimators,
                learning_rate=self.config.learning_rate,
                num_leaves=self.config.num_leaves,
                min_child_samples=self.config.min_child_samples,
                random_state=self.config.random_seed,
                deterministic=True,
                force_col_wise=True,
                n_jobs=1,
                verbosity=-1,
            )
            classifier.fit(features, occurrence_targets)

        regressor: Any | None = None
        conditional_constant: float | None = None
        if len(quantity_targets) < max(20, self.config.min_child_samples):
            conditional_constant = float(median(quantity_targets))
        else:
            from lightgbm import LGBMRegressor

            regressor = LGBMRegressor(
                objective="regression_l1",
                n_estimators=self.config.n_estimators,
                learning_rate=self.config.learning_rate,
                num_leaves=self.config.num_leaves,
                min_child_samples=self.config.min_child_samples,
                random_state=self.config.random_seed,
                deterministic=True,
                force_col_wise=True,
                n_jobs=1,
                verbosity=-1,
            )
            regressor.fit(quantity_features, quantity_targets)

        predictions: list[float] = []
        for offset in range(1, horizon_days + 1):
            target_date = dataset.history_end + timedelta(days=offset)
            row = self._features(
                values=values,
                occurrences=occurrences,
                index=len(values),
                target_date=target_date,
                dataset=dataset,
            )
            probability = (
                occurrence_constant
                if occurrence_constant is not None
                else float(classifier.predict_proba([row])[0][1])
            )
            conditional = (
                conditional_constant
                if conditional_constant is not None
                else float(regressor.predict([row])[0])
            )
            probability = min(1.0, max(0.0, probability))
            conditional = max(0.0, conditional)
            expected = probability * conditional
            if not math.isfinite(expected):
                raise ArithmeticError("two-stage model produced a non-finite forecast")
            predictions.append(expected)
            values.append(expected)
            occurrences.append(probability)
        return predictions


def _origins(manifest: dict[str, Any], start: date, end: date) -> tuple[date, ...]:
    horizon = int(manifest["forecast_horizon_days"])
    step = int(manifest["origin_step_days"])
    values: set[date] = set()
    origin = start - timedelta(days=1)
    while origin + timedelta(days=horizon) <= end:
        values.add(origin)
        origin += timedelta(days=step)
    values.add(end - timedelta(days=horizon))
    for mm_dd in manifest["additional_origins_mm_dd"]:
        month, day = (int(value) for value in mm_dd.split("-"))
        candidate = date(start.year, month, day)
        if start - timedelta(days=1) <= candidate and candidate + timedelta(days=horizon) <= end:
            values.add(candidate)
    return tuple(sorted(values))


def _predictions(model: Any, dataset: HistoricalDemandDataset, horizon: int) -> list[float]:
    values = model.forecast(dataset, horizon_days=horizon)
    if not values:
        raise ValueError("model returned no forecasts")
    if hasattr(values[0], "quantity"):
        return [float(value.quantity) for value in values]
    return [float(value) for value in values]


def evaluate(
    *,
    realization: ExperimentRealization,
    manifest: dict[str, Any],
    models: dict[str, Any],
    start: date,
    end: date,
) -> tuple[list[EvaluationPoint], tuple[date, ...]]:
    horizon = int(manifest["forecast_horizon_days"])
    max_history = int(manifest["maximum_history_days"])
    origins = _origins(manifest, start, end)
    products = {value.product_id: value for value in PRODUCTS}
    points: list[EvaluationPoint] = []
    for origin in origins:
        for source in realization.datasets:
            training = bounded_dataset(source, origin, max_history_days=max_history)
            if training.history_end != origin:
                raise AssertionError("training does not end at forecast origin")
            if any(value.business_date > origin for value in training.observations):
                raise AssertionError("future sales leaked into training")
            product = products[training.product.product_id]
            for model_name, model in models.items():
                predicted = _predictions(model, training, horizon)
                if len(predicted) != horizon:
                    raise AssertionError("forecast horizon is incomplete")
                for offset, quantity in enumerate(predicted, start=1):
                    target = origin + timedelta(days=offset)
                    if target > end:
                        raise AssertionError("forecast target escaped evaluation split")
                    points.append(
                        EvaluationPoint(
                            realization=realization.name,
                            requested_model=model_name,
                            origin=origin,
                            forecast_date=target,
                            product_id=product.product_id,
                            sku=product.sku,
                            product_name=product.product_name,
                            unit=product.unit,
                            seasonal_group=product.seasonal_group,
                            demand_class=realization.demand_classes[product.product_id],
                            actual=float(realization.actual[(product.product_id, target)]),
                            predicted=max(0.0, quantity),
                        )
                    )
    return points, origins


def _daily_metrics(rows: Iterable[EvaluationPoint]) -> dict[str, object]:
    values = list(rows)
    actual = sum(value.actual for value in values)
    predicted = sum(value.predicted for value in values)
    absolute = sum(value.absolute_error for value in values)
    zero = [value for value in values if value.actual == 0]
    return {
        "observations": len(values),
        "actual_total": actual,
        "predicted_total": predicted,
        "mae": absolute / len(values) if values else None,
        "wape": absolute / actual if actual else None,
        "bias": (predicted - actual) / actual if actual else None,
        "absolute_error_total": absolute,
        "zero_actual_observations": len(zero),
        "zero_actual_predicted_total": sum(value.predicted for value in zero),
        "zero_actual_false_positive_observations": sum(
            value.predicted > 1e-12 for value in zero
        ),
    }


def _quantity_metrics(
    rows: Iterable[EvaluationPoint], *, horizon_days: int
) -> dict[str, object]:
    grouped: dict[tuple[date, str], list[EvaluationPoint]] = defaultdict(list)
    for value in rows:
        if value.forecast_date <= value.origin + timedelta(days=horizon_days):
            grouped[(value.origin, value.product_id)].append(value)
    totals: list[tuple[float, float]] = []
    for values in grouped.values():
        if len(values) != horizon_days:
            raise AssertionError("quantity metric received an incomplete horizon")
        totals.append(
            (
                sum(value.actual for value in values),
                sum(value.predicted for value in values),
            )
        )
    actual = sum(value[0] for value in totals)
    predicted = sum(value[1] for value in totals)
    absolute = sum(abs(value[1] - value[0]) for value in totals)
    return {
        "forecast_blocks": len(totals),
        "actual_total": actual,
        "predicted_total": predicted,
        "mae": absolute / len(totals) if totals else None,
        "wape": absolute / actual if actual else None,
        "bias": (predicted - actual) / actual if actual else None,
        "absolute_error_total": absolute,
    }


def metrics_report(points: list[EvaluationPoint]) -> dict[str, object]:
    models = sorted({value.requested_model for value in points})
    dimensions: dict[str, Callable[[EvaluationPoint], str]] = {
        "by_product": lambda value: value.sku,
        "by_unit": lambda value: value.unit,
        "by_demand_class": lambda value: value.demand_class,
        "by_seasonal_group": lambda value: value.seasonal_group,
    }
    report: dict[str, object] = {
        "overall": {},
        "quantity_7_day": {},
        "quantity_28_day": {},
    }
    for model in models:
        selected = [value for value in points if value.requested_model == model]
        report["overall"][model] = _daily_metrics(selected)  # type: ignore[index]
        report["quantity_7_day"][model] = _quantity_metrics(  # type: ignore[index]
            selected, horizon_days=7
        )
        report["quantity_28_day"][model] = _quantity_metrics(  # type: ignore[index]
            selected, horizon_days=28
        )
    for dimension, resolver in dimensions.items():
        report[dimension] = {}
        groups = sorted({resolver(value) for value in points})
        for model in models:
            report[dimension][model] = {}  # type: ignore[index]
            for group in groups:
                selected = [
                    value
                    for value in points
                    if value.requested_model == model and resolver(value) == group
                ]
                if not selected:
                    continue
                report[dimension][model][group] = {  # type: ignore[index]
                    "daily": _daily_metrics(selected),
                    "quantity_7_day": _quantity_metrics(selected, horizon_days=7),
                    "quantity_28_day": _quantity_metrics(selected, horizon_days=28),
                }
    return report


def _paired_origin_values(
    points: list[EvaluationPoint],
    *,
    baseline: str,
    candidate: str,
    horizon_days: int | None,
    predicate: Callable[[EvaluationPoint], bool],
) -> dict[date, tuple[float, float, float]]:
    selected = [value for value in points if predicate(value)]
    by_model_origin_product: dict[
        tuple[str, date, str], list[EvaluationPoint]
    ] = defaultdict(list)
    for value in selected:
        if value.requested_model not in {baseline, candidate}:
            continue
        if horizon_days is not None and value.forecast_date > value.origin + timedelta(
            days=horizon_days
        ):
            continue
        by_model_origin_product[
            (value.requested_model, value.origin, value.product_id)
        ].append(value)
    by_origin: dict[date, list[float]] = defaultdict(lambda: [0.0, 0.0, 0.0])
    origins = sorted({key[1] for key in by_model_origin_product})
    products = sorted({key[2] for key in by_model_origin_product})
    for origin in origins:
        for product_id in products:
            baseline_rows = by_model_origin_product.get((baseline, origin, product_id), [])
            candidate_rows = by_model_origin_product.get((candidate, origin, product_id), [])
            if not baseline_rows and not candidate_rows:
                continue
            if len(baseline_rows) != len(candidate_rows):
                raise AssertionError("paired comparison rows are misaligned")
            actual = sum(value.actual for value in baseline_rows)
            if horizon_days is None:
                baseline_error = sum(value.absolute_error for value in baseline_rows)
                candidate_error = sum(value.absolute_error for value in candidate_rows)
            else:
                baseline_error = abs(
                    sum(value.predicted for value in baseline_rows) - actual
                )
                candidate_error = abs(
                    sum(value.predicted for value in candidate_rows) - actual
                )
            bucket = by_origin[origin]
            bucket[0] += baseline_error
            bucket[1] += candidate_error
            bucket[2] += actual
    return {key: tuple(value) for key, value in by_origin.items()}


def paired_bootstrap(
    points: list[EvaluationPoint],
    *,
    baseline: str,
    candidate: str,
    horizon_days: int | None,
    predicate: Callable[[EvaluationPoint], bool],
    repetitions: int,
    seed: int,
) -> dict[str, object]:
    values = _paired_origin_values(
        points,
        baseline=baseline,
        candidate=candidate,
        horizon_days=horizon_days,
        predicate=predicate,
    )
    origins = sorted(values)
    if not origins:
        return {
            "origins": 0,
            "improvement": None,
            "ci95_lower": None,
            "ci95_upper": None,
        }

    def improvement(sample: list[date]) -> float | None:
        baseline_error = sum(values[value][0] for value in sample)
        candidate_error = sum(values[value][1] for value in sample)
        actual = sum(values[value][2] for value in sample)
        return (baseline_error - candidate_error) / actual if actual else None

    point = improvement(origins)
    rng = random.Random(seed)
    samples = []
    for _ in range(repetitions):
        sampled = [origins[rng.randrange(len(origins))] for _ in origins]
        value = improvement(sampled)
        if value is not None:
            samples.append(value)
    samples.sort()
    lower = samples[int(0.025 * (len(samples) - 1))] if samples else None
    upper = samples[int(0.975 * (len(samples) - 1))] if samples else None
    return {
        "origins": len(origins),
        "bootstrap_repetitions": repetitions,
        "improvement": point,
        "ci95_lower": lower,
        "ci95_upper": upper,
        "positive_means_candidate_is_better": True,
    }


def _policy_points(
    points: list[EvaluationPoint],
    *,
    candidate: str,
    selected_skus: set[str],
) -> list[EvaluationPoint]:
    result: list[EvaluationPoint] = []
    for value in points:
        chosen = candidate if value.sku in selected_skus else SEASONAL
        if value.requested_model != chosen:
            continue
        result.append(
            EvaluationPoint(
                **{
                    **value.__dict__,
                    "requested_model": POLICY,
                }
            )
        )
    return result


def select_development_candidate(
    *,
    manifest: dict[str, Any],
    points: list[EvaluationPoint],
    candidate_names: list[str],
) -> dict[str, object]:
    report = metrics_report(points)
    rows: list[dict[str, object]] = []
    seasonal_intermittent = report["by_demand_class"][SEASONAL]  # type: ignore[index]
    intermittent_groups = [
        value for value in ("intermittent", "intermittent_low") if value in seasonal_intermittent
    ]

    def combined_metrics(model: str, groups: list[str]) -> dict[str, object]:
        selected = [
            value
            for value in points
            if value.requested_model == model and value.demand_class in groups
        ]
        return _daily_metrics(selected)

    baseline_intermittent = combined_metrics(SEASONAL, intermittent_groups)
    baseline_regular = combined_metrics(SEASONAL, ["regular"])
    baseline_total = report["quantity_28_day"][SEASONAL]  # type: ignore[index]
    no_sales_exists = any(value.demand_class == "no_sales" for value in points)
    for name in candidate_names:
        intermittent = combined_metrics(name, intermittent_groups)
        regular = combined_metrics(name, ["regular"])
        total = report["quantity_28_day"][name]  # type: ignore[index]
        no_sales = combined_metrics(name, ["no_sales"])
        eligible = bool(
            intermittent["wape"] < baseline_intermittent["wape"]
            and total["wape"] <= baseline_total["wape"]
            and regular["wape"] <= baseline_regular["wape"]
            and (
                not no_sales_exists
                or (
                    no_sales["actual_total"] == 0
                    and no_sales["predicted_total"] == 0
                )
            )
        )
        rows.append(
            {
                "candidate": name,
                "eligible": eligible,
                "intermittent_daily_wape": intermittent["wape"],
                "regular_daily_wape": regular["wape"],
                "overall_quantity_28_day_wape": total["wape"],
                "no_sales_predicted_total": no_sales["predicted_total"],
            }
        )
    eligible = [value for value in rows if value["eligible"]]
    selected = min(
        eligible or rows,
        key=lambda value: float(value["intermittent_daily_wape"]),
    )
    return {
        "selected_candidate": selected["candidate"],
        "selected_candidate_eligible": selected["eligible"],
        "selection_used_final_data": False,
        "intermittent_groups": intermittent_groups,
        "candidates": rows,
    }


def select_product_policy(
    *,
    manifest: dict[str, Any],
    points: list[EvaluationPoint],
    candidate: str,
) -> dict[str, object]:
    repetitions = int(
        manifest["product_specific_policy"]["bootstrap_repetitions"]
    )
    seed = int(manifest["product_specific_policy"]["bootstrap_seed"])
    skus = sorted({value.sku for value in points})
    selected: list[str] = []
    rows: list[dict[str, object]] = []
    for index, sku in enumerate(skus):
        predicate = lambda value, selected_sku=sku: value.sku == selected_sku
        daily = paired_bootstrap(
            points,
            baseline=SEASONAL,
            candidate=candidate,
            horizon_days=None,
            predicate=predicate,
            repetitions=repetitions,
            seed=seed + index,
        )
        total = paired_bootstrap(
            points,
            baseline=SEASONAL,
            candidate=candidate,
            horizon_days=28,
            predicate=predicate,
            repetitions=repetitions,
            seed=seed + 1000 + index,
        )
        choose = bool(
            daily["ci95_lower"] is not None
            and daily["ci95_lower"] > 0
            and total["ci95_lower"] is not None
            and total["ci95_lower"] > 0
        )
        if choose:
            selected.append(sku)
        rows.append(
            {
                "sku": sku,
                "selected_model": candidate if choose else SEASONAL,
                "daily_improvement": daily,
                "quantity_28_day_improvement": total,
            }
        )
    policy_points = _policy_points(
        points, candidate=candidate, selected_skus=set(selected)
    )
    universal_points = [
        value
        for value in points
        if value.requested_model in {SEASONAL, candidate}
    ]
    universal_metrics = metrics_report(universal_points)
    policy_metrics = metrics_report(
        [value for value in points if value.requested_model == SEASONAL]
        + policy_points
    )
    intermittent = {"intermittent", "intermittent_low"}
    policy_source = (
        [value for value in points if value.requested_model == SEASONAL]
        + policy_points
    )

    def strategy_row(
        *,
        name: str,
        model: str,
        source: list[EvaluationPoint],
        report: dict[str, object],
        seed_offset: int,
    ) -> dict[str, object]:
        daily_bootstrap = paired_bootstrap(
            source,
            baseline=SEASONAL,
            candidate=model,
            horizon_days=None,
            predicate=lambda value: value.demand_class in intermittent,
            repetitions=repetitions,
            seed=seed + seed_offset,
        )
        total_bootstrap = paired_bootstrap(
            source,
            baseline=SEASONAL,
            candidate=model,
            horizon_days=28,
            predicate=lambda value: value.demand_class in intermittent,
            repetitions=repetitions,
            seed=seed + seed_offset + 1,
        )
        regular_wape = report["by_demand_class"][model]["regular"]["daily"]["wape"]  # type: ignore[index]
        baseline_regular = report["by_demand_class"][SEASONAL]["regular"]["daily"]["wape"]  # type: ignore[index]
        group_nonregression = all(
            report["by_seasonal_group"][model][group]["daily"]["wape"]  # type: ignore[index]
            <= report["by_seasonal_group"][SEASONAL][group]["daily"]["wape"]  # type: ignore[index]
            for group in ("SUMMER", "RAINY", "NEUTRAL")
        )
        no_sales = report["by_demand_class"][model]["no_sales"]["daily"]  # type: ignore[index]
        eligible = bool(
            daily_bootstrap["ci95_lower"] is not None
            and daily_bootstrap["ci95_lower"] > 0
            and total_bootstrap["ci95_lower"] is not None
            and total_bootstrap["ci95_lower"] > 0
            and report["quantity_28_day"][model]["wape"]  # type: ignore[index]
            <= report["quantity_28_day"][SEASONAL]["wape"]  # type: ignore[index]
            and regular_wape <= baseline_regular
            and group_nonregression
            and no_sales["actual_total"] == 0
            and no_sales["predicted_total"] == 0
        )
        candidate_name = candidate if name == "universal_two_stage" else POLICY
        return {
            "strategy": name,
            "model": candidate_name,
            "eligible": eligible,
            "intermittent_daily_improvement": daily_bootstrap,
            "intermittent_quantity_28_day_improvement": total_bootstrap,
            "overall_daily_wape": report["overall"][candidate_name]["wape"],  # type: ignore[index]
            "overall_quantity_28_day_wape": report["quantity_28_day"][candidate_name]["wape"],  # type: ignore[index]
            "regular_daily_wape": regular_wape,
            "all_seasonal_groups_nonworse": group_nonregression,
            "never_sold_exact_zero": (
                no_sales["actual_total"] == 0
                and no_sales["predicted_total"] == 0
            ),
        }

    strategies = [
        strategy_row(
            name="universal_two_stage",
            model=candidate,
            source=universal_points,
            report=universal_metrics,
            seed_offset=5000,
        ),
        strategy_row(
            name="product_specific_policy",
            model=POLICY,
            source=policy_source,
            report=policy_metrics,
            seed_offset=6000,
        ),
    ]
    eligible = [value for value in strategies if value["eligible"]]
    chosen = min(
        eligible or strategies,
        key=lambda value: (
            float(value["overall_quantity_28_day_wape"]),
            float(value["overall_daily_wape"]),
        ),
    )
    return {
        "selected_skus": selected,
        "product_decisions": rows,
        "strategies": strategies,
        "selected_strategy": chosen["strategy"],
        "selection_guardrails_passed": bool(eligible),
        "selection_used_final_data": False,
    }


def _model_group_metrics(
    points: list[EvaluationPoint], model: str, predicate: Callable[[EvaluationPoint], bool]
) -> dict[str, object]:
    selected = [
        value
        for value in points
        if value.requested_model == model and predicate(value)
    ]
    return {
        "daily": _daily_metrics(selected),
        "quantity_7_day": _quantity_metrics(selected, horizon_days=7),
        "quantity_28_day": _quantity_metrics(selected, horizon_days=28),
    }


def build_final_assessment(
    *,
    manifest: dict[str, Any],
    points: list[EvaluationPoint],
    candidate: str,
    policy_selection: dict[str, object],
) -> dict[str, object]:
    policy_points = _policy_points(
        points,
        candidate=candidate,
        selected_skus=set(policy_selection["selected_skus"]),
    )
    all_points = points + policy_points
    report = metrics_report(all_points)
    selected_strategy = policy_selection["selected_strategy"]
    selected_model = candidate if selected_strategy == "universal_two_stage" else POLICY
    intermittent = {"intermittent", "intermittent_low"}
    repetitions = int(
        manifest["product_specific_policy"]["bootstrap_repetitions"]
    )
    seed = int(manifest["product_specific_policy"]["bootstrap_seed"]) + 10000
    comparisons = {
        "intermittent_daily": paired_bootstrap(
            all_points,
            baseline=SEASONAL,
            candidate=selected_model,
            horizon_days=None,
            predicate=lambda value: value.demand_class in intermittent,
            repetitions=repetitions,
            seed=seed,
        ),
        "intermittent_quantity_28_day": paired_bootstrap(
            all_points,
            baseline=SEASONAL,
            candidate=selected_model,
            horizon_days=28,
            predicate=lambda value: value.demand_class in intermittent,
            repetitions=repetitions,
            seed=seed + 1,
        ),
        "overall_quantity_28_day": paired_bootstrap(
            all_points,
            baseline=SEASONAL,
            candidate=selected_model,
            horizon_days=28,
            predicate=lambda _value: True,
            repetitions=repetitions,
            seed=seed + 2,
        ),
        "regular_daily": paired_bootstrap(
            all_points,
            baseline=SEASONAL,
            candidate=selected_model,
            horizon_days=None,
            predicate=lambda value: value.demand_class == "regular",
            repetitions=repetitions,
            seed=seed + 3,
        ),
    }
    group_checks: dict[str, bool] = {}
    for group in ("SUMMER", "RAINY", "NEUTRAL"):
        baseline = report["by_seasonal_group"][SEASONAL][group]["daily"]["wape"]  # type: ignore[index]
        selected = report["by_seasonal_group"][selected_model][group]["daily"]["wape"]  # type: ignore[index]
        group_checks[group] = selected <= baseline
    no_sales = _model_group_metrics(
        all_points,
        selected_model,
        lambda value: value.demand_class == "no_sales",
    )
    checks = {
        "development_strategy_guardrails_passed": bool(
            policy_selection["selection_guardrails_passed"]
        ),
        "intermittent_daily_positive_ci": (
            comparisons["intermittent_daily"]["ci95_lower"] is not None
            and comparisons["intermittent_daily"]["ci95_lower"] > 0
        ),
        "intermittent_28_day_positive_ci": (
            comparisons["intermittent_quantity_28_day"]["ci95_lower"] is not None
            and comparisons["intermittent_quantity_28_day"]["ci95_lower"] > 0
        ),
        "overall_28_day_not_worse": (
            report["quantity_28_day"][selected_model]["wape"]  # type: ignore[index]
            <= report["quantity_28_day"][SEASONAL]["wape"]  # type: ignore[index]
        ),
        "regular_daily_not_worse": (
            report["by_demand_class"][selected_model]["regular"]["daily"]["wape"]  # type: ignore[index]
            <= report["by_demand_class"][SEASONAL]["regular"]["daily"]["wape"]  # type: ignore[index]
        ),
        "all_seasonal_groups_not_worse": all(group_checks.values()),
        "never_sold_exact_zero": (
            no_sales["daily"]["actual_total"] == 0
            and no_sales["daily"]["predicted_total"] == 0
        ),
    }
    intermittent_signal = bool(
        checks["intermittent_daily_positive_ci"]
        or checks["intermittent_28_day_positive_ci"]
    )
    accepted = all(checks.values())
    decision = "PASS" if accepted else "REVISE" if intermittent_signal else "FAIL"
    return {
        "decision": decision,
        "adoption_recommended": accepted,
        "recommendation": (
            "ADOPT EXPERIMENTAL POLICY"
            if accepted
            else "KEEP CURRENT MODEL"
        ),
        "selected_development_strategy": selected_strategy,
        "selected_final_model": selected_model,
        "acceptance_checks": checks,
        "seasonal_group_nonregression_checks": group_checks,
        "paired_uncertainty": comparisons,
        "metrics": report,
    }


def product_comparison(
    points: list[EvaluationPoint], *, candidate: str, policy_skus: set[str]
) -> list[dict[str, object]]:
    policy_points = _policy_points(
        points, candidate=candidate, selected_skus=policy_skus
    )
    all_points = points + policy_points
    products = {value.sku: value for value in PRODUCTS}
    rows: list[dict[str, object]] = []
    for sku, product in sorted(products.items()):
        row: dict[str, object] = {
            "sku": sku,
            "product_name": product.product_name,
            "unit": product.unit,
            "seasonal_group": product.seasonal_group,
        }
        for model in (MEAN28, EXISTING, SEASONAL, TSB, candidate, POLICY):
            selected = [
                value
                for value in all_points
                if value.sku == sku and value.requested_model == model
            ]
            daily = _daily_metrics(selected)
            total28 = _quantity_metrics(selected, horizon_days=28)
            row[f"{model}_daily_wape"] = daily["wape"]
            row[f"{model}_daily_bias"] = daily["bias"]
            row[f"{model}_quantity_28_wape"] = total28["wape"]
        rows.append(row)
    return rows


def write_realization_csv(path: Path, realization: ExperimentRealization) -> None:
    products = {value.product_id: value for value in PRODUCTS}
    rows = []
    for (product_id, business_date), quantity in sorted(realization.actual.items()):
        product = products[product_id]
        rows.append(
            {
                "realization": realization.name,
                "seed": realization.seed,
                "business_date": business_date.isoformat(),
                "product_id": product_id,
                "sku": product.sku,
                "product_name": product.product_name,
                "unit": product.unit,
                "seasonal_group": product.seasonal_group,
                "demand_class_from_pretest_history": realization.demand_classes[
                    product_id
                ],
                "quantity": str(quantity),
            }
        )
    write_csv(path, rows)


def write_points_csv(path: Path, points: list[EvaluationPoint]) -> None:
    write_csv(
        path,
        [
            {
                **value.__dict__,
                "origin": value.origin.isoformat(),
                "forecast_date": value.forecast_date.isoformat(),
                "signed_error": value.signed_error,
                "absolute_error": value.absolute_error,
            }
            for value in points
        ],
    )


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


def jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [jsonable(item) for item in value]
    return value
