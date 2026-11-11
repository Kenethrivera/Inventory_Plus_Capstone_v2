from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
from enum import Enum

from app.forecasting.models import (
    DataProvenance,
    DataQualityMetadata,
    DemandForecast,
)


class RecommendationStatus(str, Enum):
    SUFFICIENT_INVENTORY = "sufficient_inventory"
    RECOMMEND_ORDER = "recommend_order"
    NEEDS_REVIEW = "needs_review"


class PreliminaryInsightStatus(str, Enum):
    AVAILABLE = "available"
    LIMITED = "limited"


class InventoryBalanceBasis(str, Enum):
    """Whether the supplied on-hand value already excludes reservations."""

    GROSS_BEFORE_RESERVATIONS = "gross_before_reservations"
    NET_OF_RESERVATIONS = "net_of_reservations"


class SupplierAvailability(str, Enum):
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"
    UNKNOWN = "unknown"


class SafetyStockSource(str, Enum):
    ACTUAL = "actual"
    CONFIGURED = "configured"
    EXPLICIT_ASSUMPTION = "explicit_assumption"


@dataclass(frozen=True)
class UnitConversion:
    """One `from_unit` equals `factor` units of `to_unit`."""

    from_unit: str
    to_unit: str
    factor: Decimal


@dataclass(frozen=True)
class DemandForecastSnapshot:
    forecasts: tuple[DemandForecast, ...]
    generated_at: datetime
    source_data_as_of: datetime


@dataclass(frozen=True)
class PreliminaryRestockingInsight:
    status: PreliminaryInsightStatus
    location_id: str
    product_id: str
    inventory_unit: str
    planning_horizon_days: int
    predicted_demand: Decimal | None
    available_inventory: Decimal | None
    suggested_restock_quantity: Decimal | None
    forecast_model: str
    forecast_version: str
    forecast_generated_at: datetime
    forecast_source_data_as_of: datetime
    assumptions: tuple[str, ...]
    limitations: tuple[str, ...]
    requires_owner_review: bool = True


@dataclass(frozen=True)
class InventorySnapshot:
    location_id: str
    product_id: str
    unit: str
    saleable_on_hand: Decimal | None
    confirmed_on_order: Decimal | None
    unfulfilled_reservations: Decimal | None
    backorders: Decimal | None
    max_capacity: Decimal | None
    balance_basis: InventoryBalanceBasis
    captured_at: datetime


@dataclass(frozen=True)
class SupplierPolicySnapshot:
    supplier_id: str
    order_unit: str
    lead_time_days: int | None
    minimum_order_quantity: Decimal | None
    pack_size: Decimal | None
    availability: SupplierAvailability
    captured_at: datetime


@dataclass(frozen=True)
class SafetyStockInput:
    quantity: Decimal
    unit: str
    source: SafetyStockSource
    captured_at: datetime


@dataclass(frozen=True)
class ManualDemandEstimate:
    daily_quantity: Decimal
    unit: str
    captured_at: datetime
    rationale: str


@dataclass(frozen=True)
class RecommendationPolicy:
    version: str
    review_period_days: int | None
    max_forecast_age: timedelta
    max_inventory_age: timedelta
    max_supplier_age: timedelta
    max_safety_stock_age: timedelta
    max_manual_estimate_age: timedelta = timedelta(days=30)


@dataclass(frozen=True)
class RecommendationCalculation:
    gross_on_hand_equivalent: Decimal | None = None
    inventory_position: Decimal | None = None
    expected_lead_time_demand: Decimal | None = None
    safety_stock: Decimal | None = None
    reorder_point: Decimal | None = None
    protection_period_days: int | None = None
    forecasted_protection_period_demand: Decimal | None = None
    target_inventory: Decimal | None = None
    preliminary_quantity_inventory_units: Decimal | None = None
    rounded_quantity_order_units: Decimal | None = None
    rounded_quantity_inventory_units: Decimal | None = None
    capacity_room_inventory_units: Decimal | None = None


@dataclass(frozen=True)
class RecommendationAuditMetadata:
    recommendation_at: datetime
    forecast_generated_at: datetime
    forecast_source_data_as_of: datetime
    inventory_snapshot_at: datetime
    supplier_snapshot_at: datetime
    safety_stock_snapshot_at: datetime | None
    safety_stock_source: SafetyStockSource | None
    manual_estimate_at: datetime | None
    forecast_model: str | None
    forecast_version: str | None
    forecast_provenance: DataProvenance | None
    forecast_data_quality: DataQualityMetadata | None
    policy_version: str


@dataclass(frozen=True)
class RecommendationResult:
    status: RecommendationStatus
    location_id: str
    product_id: str
    inventory_unit: str
    supplier_order_unit: str
    inventory_snapshot: InventorySnapshot
    supplier_snapshot: SupplierPolicySnapshot
    recommended_quantity_order_units: Decimal | None
    recommended_quantity_inventory_units: Decimal | None
    calculation: RecommendationCalculation
    warnings: tuple[str, ...]
    explanations: tuple[str, ...]
    audit: RecommendationAuditMetadata
    requires_human_approval: bool
    purchase_order_created: bool = False
