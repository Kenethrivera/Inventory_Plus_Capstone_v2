from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date
from decimal import Decimal
from enum import Enum
from typing import Any

from .models import MetricSet, SimulationConfig


@dataclass(frozen=True)
class EligibilityRecord:
    location_id: str
    product_id: str
    category: str
    origin: date
    origin_kind: str
    launch_date: date
    history_days: int
    stockout_censored_days: int
    mean28_model: str
    lightgbm_model: str
    blend_model: str
    routed_model: str
    cold_start_reason: str | None


@dataclass(frozen=True)
class RobustForecastReport:
    requested_model: str
    daily: MetricSet
    horizon_totals: MetricSet
    by_category: dict[str, MetricSet]
    by_segment: dict[str, MetricSet]
    actual_models: dict[str, int]
    forecast_points: int
    origins: int
    cold_start_origins: int
    target: str = "future_underlying_net_demand"


@dataclass(frozen=True)
class ForecastEvaluationResult:
    reports: tuple[RobustForecastReport, ...]
    eligibility: tuple[EligibilityRecord, ...]


@dataclass(frozen=True)
class PolicyMetrics:
    underlying_demand_units: Decimal
    immediately_fulfilled_units: Decimal
    unmet_demand_units: Decimal
    late_backorder_fulfilled_units: Decimal
    ending_backorders: Decimal
    stockout_days: int
    maximum_consecutive_stockout_days: int
    fulfilled_demand_percentage: Decimal | None
    average_inventory: Decimal
    excess_inventory_unit_days: Decimal
    orders_placed: int
    ordered_quantity: Decimal
    holding_cost: Decimal
    ordering_cost: Decimal
    total_assumed_cost: Decimal
    review_recommendations: int
    provisional_approvals: int


@dataclass(frozen=True)
class PolicyComparisonOutcome:
    strategy: str
    overall: PolicyMetrics
    by_category: dict[str, PolicyMetrics]
    requested_forecast_model: str
    actual_forecast_models: dict[str, int]


@dataclass(frozen=True)
class SeedResult:
    seed: int
    configuration: SimulationConfig
    forecasts: tuple[RobustForecastReport, ...]
    warnings: tuple[str, ...]


@dataclass(frozen=True)
class StressResult:
    name: str
    configuration: SimulationConfig
    forecasts: tuple[RobustForecastReport, ...]
    policies: tuple[PolicyComparisonOutcome, ...]
    warnings: tuple[str, ...]


@dataclass(frozen=True)
class Stage6A2Report:
    report_version: str
    created_on: date
    source_revision: str
    seeds: tuple[int, ...]
    model_configuration: dict[str, Any]
    seed_results: tuple[SeedResult, ...]
    cold_start_configuration: SimulationConfig
    cold_start_result: ForecastEvaluationResult
    policy_configuration: SimulationConfig
    policy_results: tuple[PolicyComparisonOutcome, ...]
    stress_results: tuple[StressResult, ...]
    assumptions: tuple[str, ...]
    safeguards: tuple[str, ...]
    warnings: tuple[str, ...]
    limitations: tuple[str, ...]

    def to_jsonable(self) -> dict[str, Any]:
        return _jsonable(asdict(self))


def _jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, Enum)):
        return value.isoformat() if isinstance(value, date) else value.value
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value
