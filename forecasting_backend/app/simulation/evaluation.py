from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from typing import Protocol

from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    DemandForecast,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    RollingOriginConfig,
)

from .datasets import historical_dataset
from .models import (
    ForecastModelReport,
    MetricSet,
    SimulationConfig,
    SyntheticProductPolicy,
    SyntheticScenario,
)


class _Forecaster(Protocol):
    def forecast(self, dataset: object, *, horizon_days: int) -> list[DemandForecast]: ...


@dataclass(frozen=True)
class _Point:
    category: str
    origin: date
    actual: Decimal
    predicted: Decimal


class ForecastEvaluator:
    """Scores future latent demand using histories bounded at each origin."""

    def __init__(self, config: SimulationConfig) -> None:
        mean = Mean28Forecaster()
        lightgbm = LightGBMForecaster(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=30,
                learning_rate=0.06,
                num_leaves=12,
                random_seed=config.seed,
            ),
            mean28=mean,
        )
        blend = CalibratedBlendForecaster(
            config=CalibratedBlendConfig(
                minimum_calibration_points=28,
                rolling_origin=RollingOriginConfig(
                    initial_training_days=112,
                    horizon_days=config.forecast_horizon_days,
                    step_days=84,
                ),
            ),
            lightgbm=lightgbm,
            mean28=mean,
        )
        self._models: tuple[tuple[str, _Forecaster], ...] = (
            ("mean28", mean),
            ("lightgbm", lightgbm),
            ("calibrated_blend", blend),
        )
        self._config = config

    def evaluate(self, scenario: SyntheticScenario) -> tuple[ForecastModelReport, ...]:
        origins = self._origins(scenario)
        by_series = {
            policy.key: scenario.series(policy.location_id, policy.product_id)
            for policy in scenario.policies
        }
        reports: list[ForecastModelReport] = []
        for requested_name, model in self._models:
            points: list[_Point] = []
            totals: list[_Point] = []
            actual_models: Counter[str] = Counter()
            insufficient: set[tuple[tuple[str, str], date]] = set()
            used_origins = 0
            for policy in scenario.policies:
                series = by_series[policy.key]
                actual_by_date = {value.business_date: value for value in series}
                for origin in origins:
                    future_dates = [
                        origin + timedelta(days=offset)
                        for offset in range(1, self._config.forecast_horizon_days + 1)
                    ]
                    if any(value not in actual_by_date for value in future_dates):
                        continue
                    dataset = historical_dataset(
                        scenario, policy, history_end=origin
                    )
                    forecast = model.forecast(
                        dataset, horizon_days=self._config.forecast_horizon_days
                    )
                    used_origins += 1
                    metadata = forecast[0].metadata
                    actual_models[metadata.model_name] += 1
                    if metadata.is_cold_start or metadata.fallback_reason is not None:
                        insufficient.add((policy.key, origin))
                    actual_total = Decimal("0")
                    predicted_total = Decimal("0")
                    for value in forecast:
                        if value.forecast_date <= origin:
                            raise AssertionError("forecast leaked into its training period")
                        actual = actual_by_date[value.forecast_date].underlying_net_demand
                        points.append(
                            _Point(
                                category=policy.category.value,
                                origin=origin,
                                actual=actual,
                                predicted=value.quantity,
                            )
                        )
                        actual_total += actual
                        predicted_total += value.quantity
                    totals.append(
                        _Point(
                            category=policy.category.value,
                            origin=origin,
                            actual=actual_total,
                            predicted=predicted_total,
                        )
                    )
            reports.append(
                ForecastModelReport(
                    requested_model=requested_name,
                    daily=_metrics(points),
                    horizon_totals=_metrics(totals),
                    by_category={
                        category: _metrics(category_points)
                        for category, category_points in _group(points).items()
                    },
                    actual_models=dict(sorted(actual_models.items())),
                    insufficient_history_series=len(insufficient),
                    forecast_points=len(points),
                    origins=used_origins,
                )
            )
        return tuple(reports)

    def _origins(self, scenario: SyntheticScenario) -> tuple[date, ...]:
        end = scenario.config.start_date + timedelta(days=scenario.config.days - 1)
        last = end - timedelta(days=self._config.forecast_horizon_days)
        values = [
            last - timedelta(days=index * self._config.origin_spacing_days)
            for index in range(self._config.evaluation_origins)
        ]
        return tuple(sorted(values))


def _group(points: list[_Point]) -> dict[str, list[_Point]]:
    grouped: dict[str, list[_Point]] = defaultdict(list)
    for point in points:
        grouped[point.category].append(point)
    return grouped


def _metrics(points: list[_Point]) -> MetricSet:
    return calculate_metrics(
        [value.actual for value in points],
        [value.predicted for value in points],
    )


def calculate_metrics(
    actual: list[Decimal], predicted: list[Decimal]
) -> MetricSet:
    if len(actual) != len(predicted):
        raise ValueError("metric inputs must be aligned")
    if not actual:
        return MetricSet(
            observations=0,
            actual_total=Decimal("0"),
            predicted_total=Decimal("0"),
            wape=None,
            signed_bias=None,
            mae=Decimal("0"),
        )
    actual_total = sum(actual, Decimal("0"))
    predicted_total = sum(predicted, Decimal("0"))
    absolute_error = sum(
        (abs(estimate - observed) for observed, estimate in zip(actual, predicted)),
        Decimal("0"),
    )
    signed_error = predicted_total - actual_total
    return MetricSet(
        observations=len(actual),
        actual_total=actual_total,
        predicted_total=predicted_total,
        wape=(absolute_error / actual_total if actual_total > 0 else None),
        signed_bias=(signed_error / actual_total if actual_total > 0 else None),
        mae=absolute_error / Decimal(len(actual)),
    )
