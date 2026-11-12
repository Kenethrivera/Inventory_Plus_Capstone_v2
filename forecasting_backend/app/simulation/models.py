from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date
from decimal import Decimal
from enum import Enum
from typing import Any


class DemandCategory(str, Enum):
    SLOW = "slow"
    MEDIUM = "medium"
    FAST = "fast"


@dataclass(frozen=True)
class SimulationConfig:
    start_date: date = date(2024, 1, 1)
    days: int = 731
    product_count: int = 100
    location_count: int = 2
    seed: int = 2606
    review_period_days: int = 7
    evaluation_days: int = 180
    forecast_horizon_days: int = 28
    evaluation_origins: int = 3
    origin_spacing_days: int = 56
    spike_probability: Decimal = Decimal("0.015")
    cancellation_probability: Decimal = Decimal("0.03")
    return_probability: Decimal = Decimal("0.015")
    delivery_delay_probability: Decimal = Decimal("0.20")
    maximum_delivery_delay_days: int = 4
    backorder_fraction: Decimal = Decimal("0.25")
    fixed_order_cost: Decimal = Decimal("12")
    daily_holding_cost_per_unit: Decimal = Decimal("0.02")
    slow_daily_demand_range: tuple[Decimal, Decimal] = (
        Decimal("0.25"),
        Decimal("1.10"),
    )
    medium_daily_demand_range: tuple[Decimal, Decimal] = (
        Decimal("1.80"),
        Decimal("4.20"),
    )
    fast_daily_demand_range: tuple[Decimal, Decimal] = (
        Decimal("5.00"),
        Decimal("10.00"),
    )
    slow_frequency_range: tuple[Decimal, Decimal] = (
        Decimal("0.25"),
        Decimal("0.55"),
    )
    medium_frequency_range: tuple[Decimal, Decimal] = (
        Decimal("0.65"),
        Decimal("0.90"),
    )
    fast_frequency_range: tuple[Decimal, Decimal] = (
        Decimal("0.88"),
        Decimal("1.00"),
    )
    demand_variability_range: tuple[Decimal, Decimal] = (
        Decimal("0.15"),
        Decimal("0.55"),
    )
    weekly_seasonality_range: tuple[Decimal, Decimal] = (
        Decimal("0.05"),
        Decimal("0.30"),
    )
    annual_seasonality_range: tuple[Decimal, Decimal] = (
        Decimal("0.05"),
        Decimal("0.25"),
    )
    new_product_probability: Decimal = Decimal("0.10")
    new_product_launch_offset_range: tuple[int, int] = (28, 180)
    supplier_lead_time_range: tuple[int, int] = (2, 12)
    pack_size_options: tuple[int, ...] = (1, 2, 4, 6, 12)
    moq_pack_multiple_options: tuple[int, ...] = (1, 2, 3)
    opening_stock_coverage_days: int = 12
    capacity_coverage_days: int = 70
    minimum_safety_stock_days: int = 2

    def __post_init__(self) -> None:
        if self.days <= 0 or self.product_count <= 0 or self.location_count <= 0:
            raise ValueError("days, product_count, and location_count must be positive")
        if self.forecast_horizon_days <= 0 or self.evaluation_days <= 0:
            raise ValueError("forecast and evaluation durations must be positive")
        if self.review_period_days <= 0 or self.evaluation_origins <= 0:
            raise ValueError("review period and evaluation origins must be positive")
        probabilities = (
            self.spike_probability,
            self.cancellation_probability,
            self.return_probability,
            self.delivery_delay_probability,
            self.backorder_fraction,
            self.new_product_probability,
        )
        if any(value < 0 or value > 1 for value in probabilities):
            raise ValueError("simulation probabilities must be between zero and one")
        decimal_ranges = (
            self.slow_daily_demand_range,
            self.medium_daily_demand_range,
            self.fast_daily_demand_range,
            self.slow_frequency_range,
            self.medium_frequency_range,
            self.fast_frequency_range,
            self.demand_variability_range,
            self.weekly_seasonality_range,
            self.annual_seasonality_range,
        )
        if any(low < 0 or high < low for low, high in decimal_ranges):
            raise ValueError("demand and seasonality ranges must be ordered and nonnegative")
        probability_ranges = (
            self.slow_frequency_range,
            self.medium_frequency_range,
            self.fast_frequency_range,
        )
        if any(high > 1 for _, high in probability_ranges):
            raise ValueError("demand frequency ranges must not exceed one")
        integer_ranges = (
            self.new_product_launch_offset_range,
            self.supplier_lead_time_range,
        )
        if any(low < 0 or high < low for low, high in integer_ranges):
            raise ValueError("launch and lead-time ranges must be ordered and nonnegative")
        if self.supplier_lead_time_range[0] <= 0:
            raise ValueError("supplier lead time must be positive")
        if not self.pack_size_options or not self.moq_pack_multiple_options:
            raise ValueError("pack and MOQ options must not be empty")
        if any(value <= 0 for value in self.pack_size_options):
            raise ValueError("pack sizes must be positive")
        if any(value <= 0 for value in self.moq_pack_multiple_options):
            raise ValueError("MOQ pack multiples must be positive")
        if min(
            self.opening_stock_coverage_days,
            self.capacity_coverage_days,
            self.minimum_safety_stock_days,
        ) <= 0:
            raise ValueError("stock coverage durations must be positive")


@dataclass(frozen=True)
class SyntheticProductPolicy:
    product_id: str
    location_id: str
    sku: str
    name: str
    category: DemandCategory
    unit: str
    launch_date: date
    base_daily_demand: Decimal
    demand_frequency: Decimal
    variability: Decimal
    weekly_seasonality: Decimal
    annual_seasonality: Decimal
    lead_time_days: int
    minimum_order_quantity: Decimal
    pack_size: Decimal
    capacity: Decimal
    opening_stock: Decimal
    safety_stock: Decimal
    manual_daily_estimate: Decimal

    @property
    def key(self) -> tuple[str, str]:
        return self.location_id, self.product_id


@dataclass(frozen=True)
class SyntheticDay:
    business_date: date
    location_id: str
    product_id: str
    customer_demand: Decimal
    cancelled_units: Decimal
    underlying_net_demand: Decimal
    returned_units: Decimal
    fulfilled_sales: Decimal
    unmet_demand: Decimal
    supplier_delay_days: int
    reference_delivery_units: Decimal
    reference_on_hand_end: Decimal
    stockout: bool

    @property
    def key(self) -> tuple[str, str]:
        return self.location_id, self.product_id


@dataclass(frozen=True)
class SyntheticScenario:
    config: SimulationConfig
    policies: tuple[SyntheticProductPolicy, ...]
    days: tuple[SyntheticDay, ...]
    provenance: str = "synthetic_stage6a"

    def series(
        self, location_id: str, product_id: str
    ) -> tuple[SyntheticDay, ...]:
        return tuple(
            value
            for value in self.days
            if value.location_id == location_id and value.product_id == product_id
        )


@dataclass(frozen=True)
class MetricSet:
    observations: int
    actual_total: Decimal
    predicted_total: Decimal
    wape: Decimal | None
    signed_bias: Decimal | None
    mae: Decimal


@dataclass(frozen=True)
class ForecastModelReport:
    requested_model: str
    daily: MetricSet
    horizon_totals: MetricSet
    by_category: dict[str, MetricSet]
    actual_models: dict[str, int]
    insufficient_history_series: int
    forecast_points: int
    origins: int
    target: str = "future_underlying_net_demand"


@dataclass(frozen=True)
class InventoryOutcome:
    strategy: str
    underlying_demand_units: Decimal
    immediately_fulfilled_units: Decimal
    unmet_demand_units: Decimal
    late_backorder_fulfilled_units: Decimal
    ending_backorders: Decimal
    stockout_days: int
    fulfilled_demand_percentage: Decimal | None
    average_inventory: Decimal
    excess_inventory_unit_days: Decimal
    orders_placed: int
    ordered_quantity: Decimal
    holding_cost: Decimal
    ordering_cost: Decimal
    review_recommendations: int
    provisional_approvals: int


@dataclass(frozen=True)
class ColdStartLifecycleReport:
    product_id: str
    location_id: str
    registration_state: str
    zero_is_unknown_demand: bool
    manual_estimate_used: bool
    initial_recommendation_status: str
    first_insufficient_history_date: date | None
    first_lightgbm_eligible_date: date | None
    first_blend_eligible_date: date | None
    selection_rule: str


@dataclass(frozen=True)
class SimulationReport:
    configuration: SimulationConfig
    provenance: str
    product_location_series: int
    period_start: date
    period_end: date
    forecast_reports: tuple[ForecastModelReport, ...]
    inventory_outcomes: tuple[InventoryOutcome, ...]
    cold_start: ColdStartLifecycleReport
    error_analysis: tuple[str, ...]
    assumptions: tuple[str, ...]
    limitations: tuple[str, ...]
    reproducible: bool = True

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
