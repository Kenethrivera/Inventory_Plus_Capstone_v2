from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, replace
from datetime import date, timedelta
from decimal import Decimal

from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    DemandForecast,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    ModelComponent,
    RollingOriginConfig,
)

from .datasets import historical_dataset
from .evaluation import calculate_metrics
from .models import MetricSet, SimulationConfig, SyntheticProductPolicy, SyntheticScenario
from .stage6a2_models import (
    EligibilityRecord,
    ForecastEvaluationResult,
    RobustForecastReport,
)


REFERENCE_CANDIDATES = ("mean28", "lightgbm", "calibrated_blend")
EXPERIMENTAL_CANDIDATES = (
    "eligibility_routed",
    "intermittent_guardrail",
)


@dataclass(frozen=True)
class _Point:
    actual: Decimal
    predicted: Decimal
    category: str
    segments: tuple[str, ...]


@dataclass(frozen=True)
class _CandidateValues:
    requested_name: str
    values: tuple[DemandForecast, ...]


class RobustForecastEvaluator:
    """Chronological Stage 6A.2 evaluation without changing reference models."""

    def __init__(
        self,
        config: SimulationConfig,
        *,
        include_launch_origins: bool = False,
        intermittent_threshold: Decimal = Decimal("0.50"),
    ) -> None:
        if not Decimal("0") <= intermittent_threshold <= Decimal("1"):
            raise ValueError("intermittent_threshold must be between zero and one")
        self.config = config
        self.include_launch_origins = include_launch_origins
        self.intermittent_threshold = intermittent_threshold
        self.mean28 = Mean28Forecaster()
        self.lightgbm = LightGBMForecaster(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=30,
                learning_rate=0.06,
                num_leaves=12,
                random_seed=config.seed,
            ),
            mean28=self.mean28,
        )
        self.blend = CalibratedBlendForecaster(
            config=CalibratedBlendConfig(
                minimum_calibration_points=28,
                rolling_origin=RollingOriginConfig(
                    initial_training_days=112,
                    horizon_days=config.forecast_horizon_days,
                    step_days=84,
                ),
            ),
            lightgbm=self.lightgbm,
            mean28=self.mean28,
        )

    @property
    def model_configuration(self) -> dict[str, object]:
        return {
            "mean28_lookback_days": 28,
            "lightgbm": {
                "min_history_days": 84,
                "min_training_rows": 40,
                "n_estimators": 30,
                "learning_rate": 0.06,
                "num_leaves": 12,
                "random_seed": self.config.seed,
                "objective": "regression_l1",
            },
            "blend": {
                "lightgbm_weight": "0.5",
                "mean28_weight": "0.5",
                "minimum_calibration_points": 28,
                "initial_training_days": 112,
                "rolling_horizon_days": self.config.forecast_horizon_days,
                "step_days": 84,
                "bias_factor_bounds": ["0.5", "2.0"],
            },
            "intermittent_guardrail_nonzero_share_threshold": str(
                self.intermittent_threshold
            ),
            "launch_relative_origin_offsets": [-1, 6, 27, 83],
        }

    def evaluate(self, scenario: SyntheticScenario) -> ForecastEvaluationResult:
        points: dict[str, list[_Point]] = defaultdict(list)
        totals: dict[str, list[_Point]] = defaultdict(list)
        actual_models: dict[str, Counter[str]] = defaultdict(Counter)
        origins_used: Counter[str] = Counter()
        cold_origins: Counter[str] = Counter()
        eligibility: list[EligibilityRecord] = []

        by_series = {
            policy.key: scenario.series(policy.location_id, policy.product_id)
            for policy in scenario.policies
        }
        for policy in scenario.policies:
            series = by_series[policy.key]
            actual_by_date = {value.business_date: value for value in series}
            for origin, origin_kind in self._origins_for_policy(scenario, policy):
                future_dates = tuple(
                    origin + timedelta(days=offset)
                    for offset in range(1, self.config.forecast_horizon_days + 1)
                )
                if any(day not in actual_by_date for day in future_dates):
                    continue
                dataset = historical_dataset(scenario, policy, history_end=origin)
                mean_values = tuple(
                    self.mean28.forecast(
                        dataset, horizon_days=self.config.forecast_horizon_days
                    )
                )
                light_values = tuple(
                    self.lightgbm.forecast(
                        dataset, horizon_days=self.config.forecast_horizon_days
                    )
                )
                blend_values = tuple(
                    self.blend.forecast(
                        dataset, horizon_days=self.config.forecast_horizon_days
                    )
                )
                routed_values = self._eligibility_routed(
                    policy, mean_values, light_values, blend_values
                )
                guarded_values = self._intermittent_guardrail(
                    mean_values, light_values
                )
                candidates = (
                    _CandidateValues("mean28", mean_values),
                    _CandidateValues("lightgbm", light_values),
                    _CandidateValues("calibrated_blend", blend_values),
                    _CandidateValues("eligibility_routed", routed_values),
                    _CandidateValues("intermittent_guardrail", guarded_values),
                )
                quality = mean_values[0].metadata.data_quality
                eligibility.append(
                    EligibilityRecord(
                        location_id=policy.location_id,
                        product_id=policy.product_id,
                        category=policy.category.value,
                        origin=origin,
                        origin_kind=origin_kind,
                        launch_date=policy.launch_date,
                        history_days=mean_values[0].metadata.history_days_available,
                        stockout_censored_days=quality.stockout_censored_days,
                        mean28_model=mean_values[0].metadata.model_name,
                        lightgbm_model=light_values[0].metadata.model_name,
                        blend_model=blend_values[0].metadata.model_name,
                        routed_model=routed_values[0].metadata.model_name,
                        cold_start_reason=(
                            mean_values[0].metadata.cold_start_reason.value
                            if mean_values[0].metadata.cold_start_reason is not None
                            else None
                        ),
                    )
                )
                segments = self._segments(
                    scenario,
                    policy,
                    mean_values[0],
                    tuple(actual_by_date[day] for day in future_dates),
                )
                actual_quantities = tuple(
                    actual_by_date[day].underlying_net_demand for day in future_dates
                )
                for candidate in candidates:
                    origins_used[candidate.requested_name] += 1
                    actual_models[candidate.requested_name][
                        candidate.values[0].metadata.model_name
                    ] += 1
                    if candidate.values[0].metadata.is_cold_start:
                        cold_origins[candidate.requested_name] += 1
                    predicted_total = Decimal("0")
                    actual_total = Decimal("0")
                    for actual, forecast in zip(
                        actual_quantities, candidate.values, strict=True
                    ):
                        if forecast.forecast_date <= origin:
                            raise AssertionError("forecast crossed its history boundary")
                        points[candidate.requested_name].append(
                            _Point(
                                actual=actual,
                                predicted=forecast.quantity,
                                category=policy.category.value,
                                segments=segments,
                            )
                        )
                        actual_total += actual
                        predicted_total += forecast.quantity
                    totals[candidate.requested_name].append(
                        _Point(
                            actual=actual_total,
                            predicted=predicted_total,
                            category=policy.category.value,
                            segments=segments,
                        )
                    )

        reports = tuple(
            self._report(
                name,
                points[name],
                totals[name],
                actual_models[name],
                origins_used[name],
                cold_origins[name],
            )
            for name in REFERENCE_CANDIDATES + EXPERIMENTAL_CANDIDATES
        )
        return ForecastEvaluationResult(
            reports=reports,
            eligibility=tuple(eligibility),
        )

    def _origins_for_policy(
        self,
        scenario: SyntheticScenario,
        policy: SyntheticProductPolicy,
    ) -> tuple[tuple[date, str], ...]:
        end = scenario.config.start_date + timedelta(days=scenario.config.days - 1)
        last = end - timedelta(days=self.config.forecast_horizon_days)
        origins: dict[date, str] = {
            last - timedelta(days=index * self.config.origin_spacing_days): "global"
            for index in range(self.config.evaluation_origins)
        }
        evaluation_start = end - timedelta(days=self.config.evaluation_days - 1)
        if self.include_launch_origins and policy.launch_date >= evaluation_start:
            for offset in (-1, 6, 27, 83):
                origin = policy.launch_date + timedelta(days=offset)
                if scenario.config.start_date <= origin <= last:
                    origins[origin] = f"launch_relative_{offset:+d}"
        return tuple(sorted(origins.items()))

    def _eligibility_routed(
        self,
        policy: SyntheticProductPolicy,
        mean_values: tuple[DemandForecast, ...],
        light_values: tuple[DemandForecast, ...],
        blend_values: tuple[DemandForecast, ...],
    ) -> tuple[DemandForecast, ...]:
        if mean_values[0].metadata.is_cold_start:
            results: list[DemandForecast] = []
            for value in mean_values:
                quality = replace(
                    value.metadata.data_quality,
                    warnings=value.metadata.data_quality.warnings
                    + (
                        "manual_estimate_is_provisional_not_historical_sales",
                        "human_review_required",
                    ),
                )
                metadata = replace(
                    value.metadata,
                    model_name="manual_estimate_fallback",
                    model_version="stage6a2-1",
                    fallback_reason="cold_start_manual_estimate",
                    data_quality=quality,
                    components=(
                        ModelComponent(
                            model_name="manual_estimate",
                            model_version="stage6a2-1",
                            weight=Decimal("1"),
                        ),
                    ),
                )
                results.append(
                    replace(
                        value,
                        quantity=policy.manual_daily_estimate,
                        metadata=metadata,
                    )
                )
            return tuple(results)
        if blend_values[0].metadata.model_name == self.blend.MODEL_NAME:
            return blend_values
        if light_values[0].metadata.model_name == self.lightgbm.MODEL_NAME:
            return light_values
        return mean_values

    def _intermittent_guardrail(
        self,
        mean_values: tuple[DemandForecast, ...],
        light_values: tuple[DemandForecast, ...],
    ) -> tuple[DemandForecast, ...]:
        mean_metadata = mean_values[0].metadata
        if light_values[0].metadata.model_name != self.lightgbm.MODEL_NAME:
            return light_values
        sample_days = mean_metadata.sample_days_used
        nonzero_share = (
            Decimal(mean_metadata.nonzero_demand_days) / Decimal(sample_days)
            if sample_days
            else Decimal("0")
        )
        if nonzero_share > self.intermittent_threshold:
            return tuple(
                replace(
                    value,
                    metadata=replace(
                        value.metadata,
                        model_name="intermittent_guardrail_lightgbm",
                        model_version="stage6a2-1",
                    ),
                )
                for value in light_values
            )
        results: list[DemandForecast] = []
        for value in mean_values:
            quality = replace(
                value.metadata.data_quality,
                warnings=value.metadata.data_quality.warnings
                + (
                    "experimental_intermittent_guardrail_routed_to_mean28",
                ),
            )
            metadata = replace(
                value.metadata,
                model_name="intermittent_guardrail_mean28",
                model_version="stage6a2-1",
                fallback_reason=None,
                data_quality=quality,
            )
            results.append(replace(value, metadata=metadata))
        return tuple(results)

    def _segments(
        self,
        scenario: SyntheticScenario,
        policy: SyntheticProductPolicy,
        representative: DemandForecast,
        future: tuple[object, ...],
    ) -> tuple[str, ...]:
        segments = [f"category:{policy.category.value}"]
        if policy.demand_frequency < Decimal("0.60"):
            segments.append("intermittent")
        if policy.launch_date > scenario.config.start_date:
            segments.append("new_product")
        if representative.metadata.cold_start_reason is not None:
            segments.append(
                f"cold_start:{representative.metadata.cold_start_reason.value}"
            )
        if (
            policy.weekly_seasonality + policy.annual_seasonality
            >= Decimal("0.35")
        ):
            segments.append("high_seasonality")
        if representative.metadata.data_quality.stockout_censored_days:
            segments.append("stockout_censored_history")
        if any(getattr(day, "stockout") for day in future):
            segments.append("stockout_in_horizon")
        if any(
            getattr(day, "customer_demand")
            >= policy.base_daily_demand * Decimal("2")
            for day in future
        ):
            segments.append("demand_spike_in_horizon")
        return tuple(segments)

    @staticmethod
    def _report(
        name: str,
        points: list[_Point],
        totals: list[_Point],
        actual_models: Counter[str],
        origins: int,
        cold_origins: int,
    ) -> RobustForecastReport:
        by_category: dict[str, list[_Point]] = defaultdict(list)
        by_segment: dict[str, list[_Point]] = defaultdict(list)
        for point in points:
            by_category[point.category].append(point)
            for segment in point.segments:
                by_segment[segment].append(point)
        return RobustForecastReport(
            requested_model=name,
            daily=_metrics(points),
            horizon_totals=_metrics(totals),
            by_category={
                category: _metrics(values)
                for category, values in sorted(by_category.items())
            },
            by_segment={
                segment: _metrics(values)
                for segment, values in sorted(by_segment.items())
            },
            actual_models=dict(sorted(actual_models.items())),
            forecast_points=len(points),
            origins=origins,
            cold_start_origins=cold_origins,
        )


def _metrics(points: list[_Point]) -> MetricSet:
    return calculate_metrics(
        [point.actual for point in points],
        [point.predicted for point in points],
    )
