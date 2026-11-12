from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal
from typing import Mapping, Protocol
from uuid import UUID

from app.data import DailyDemand
from app.forecasting import HistoricalDemandDataset
from app.recommendations import (
    InventorySnapshot,
    RecommendationPolicy,
    SafetyStockInput,
    SupplierPolicySnapshot,
    UnitConversion,
)


class ApiDataError(RuntimeError):
    pass


class AuthenticationError(ApiDataError):
    pass


class AuthorizationError(ApiDataError):
    pass


class DataUnavailableError(ApiDataError):
    def __init__(self, message: str, *, stage: str | None = None) -> None:
        super().__init__(message)
        self.stage = stage


class ReplenishmentConfigurationUnavailableError(DataUnavailableError):
    pass


class ProductNotFoundError(ApiDataError):
    pass


class RecommendationPersistenceUnavailableError(DataUnavailableError):
    pass


class RecommendationConflictError(ApiDataError):
    pass


@dataclass(frozen=True)
class SessionProfile:
    profile_id: str
    role: str
    location_id: str
    name: str


@dataclass(frozen=True)
class ReplenishmentConfiguration:
    configured: bool
    product_id: str
    location_id: str
    inventory_unit: str
    persistence_available: bool = True
    supplier_lead_time_days: int | None = None
    review_period_days: int | None = None
    safety_stock: Decimal | None = None
    minimum_order_quantity: Decimal | None = None
    supplier_pack_size: Decimal | None = None
    supplier_order_unit: str | None = None
    unit_conversion_factor: Decimal | None = None
    confirmed_incoming_quantity: Decimal | None = None
    incoming_quantity_verified: bool = False
    backorder_quantity: Decimal | None = None
    backorder_quantity_verified: bool = False
    supplier_availability: str | None = None
    data_source: str | None = None
    source_captured_at: datetime | None = None
    rationale: str | None = None
    updated_at: datetime | None = None
    updated_by_profile_id: str | None = None


@dataclass(frozen=True)
class ReplenishmentConfigurationInput:
    supplier_lead_time_days: int | None
    review_period_days: int | None
    safety_stock: Decimal | None
    minimum_order_quantity: Decimal | None
    supplier_pack_size: Decimal | None
    supplier_order_unit: str | None
    unit_conversion_factor: Decimal | None
    confirmed_incoming_quantity: Decimal | None
    incoming_quantity_verified: bool
    backorder_quantity: Decimal | None
    backorder_quantity_verified: bool
    supplier_availability: str | None
    data_source: str
    source_captured_at: datetime
    rationale: str | None


@dataclass(frozen=True)
class AnalysisContext:
    history: HistoricalDemandDataset
    inventory: InventorySnapshot
    supplier: SupplierPolicySnapshot
    safety_stock: SafetyStockInput | None
    conversions: tuple[UnitConversion, ...]
    policy: RecommendationPolicy
    source_data_as_of: datetime
    adapter_name: str
    replenishment_configuration: ReplenishmentConfiguration | None = None


@dataclass(frozen=True)
class TrustedRecommendationSnapshot:
    location_id: str
    product_id: str
    forecast_model: str
    forecast_version: str
    training_history_days: int
    experimental_model: bool
    forecast_generated_at: datetime
    forecast_source_data_as_of: datetime
    planning_horizon_days: int
    forecast_period_start: date
    forecast_period_end: date
    predicted_demand: Decimal
    available_inventory: Decimal
    recommended_restock_quantity: Decimal
    inventory_unit: str
    assumptions: tuple[str, ...]


class ForecastDataAdapter(Protocol):
    def authenticate(self, session_token: str) -> SessionProfile: ...

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = 365,
    ) -> AnalysisContext: ...

    def load_daily_demand(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        period_start: datetime,
        period_end: datetime,
        business_timezone: str = "Asia/Manila",
    ) -> tuple[DailyDemand, ...]: ...

    def load_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
    ) -> ReplenishmentConfiguration: ...

    def save_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        configuration: ReplenishmentConfigurationInput,
    ) -> ReplenishmentConfiguration: ...


class RecommendationPersistenceAdapter(Protocol):
    def snapshot_by_request(
        self,
        *,
        session_token: str,
        request_id: UUID,
    ) -> Mapping[str, object] | None: ...

    def save_snapshot(
        self,
        *,
        session_token: str,
        request_id: UUID,
        snapshot: TrustedRecommendationSnapshot,
    ) -> Mapping[str, object]: ...

    def match_receipt(
        self,
        *,
        session_token: str,
        recommendation_id: int,
        transaction_history_id: UUID,
        allocated_inventory_quantity: Decimal,
    ) -> Mapping[str, object]: ...

    def reconcile(
        self,
        *,
        session_token: str,
        request_id: UUID,
        recommendation_id: int,
        confirm_no_receipts: bool,
        confirmation_note: str | None,
    ) -> Mapping[str, object]: ...

    def tracking(
        self,
        *,
        session_token: str,
        product_id: UUID | None,
    ) -> list[Mapping[str, object]]: ...
