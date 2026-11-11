from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from enum import Enum
from typing import Iterable

from app.data.models import DailyDemand, DemandSeriesKey
from app.data.validation import DemandDataError, required_identifier


class DatasetRole(str, Enum):
    """How a dataset may be used by the forecasting pipeline."""

    HISTORICAL = "historical"


class DataProvenance(str, Enum):
    """Whether observations came from real persistence or a controlled fixture."""

    REAL = "real"
    SYNTHETIC = "synthetic"


class ColdStartReason(str, Enum):
    NO_HISTORY = "no_history"
    INSUFFICIENT_HISTORY = "insufficient_history"


class ColdStartStrategy(str, Enum):
    AVAILABLE_DAY_MEAN = "available_day_mean"
    ZERO = "zero"


class AvailabilityStatus(str, Enum):
    IN_STOCK = "in_stock"
    STOCKOUT = "stockout"


@dataclass(frozen=True)
class AvailabilityEvidence:
    business_date: date
    status: AvailabilityStatus


@dataclass(frozen=True)
class DataQualityMetadata:
    history_calendar_days: int
    observed_sales_days: int
    assumed_zero_sales_days: int
    stockout_censored_days: int
    availability_evidence_days: int
    availability_unknown_days: int
    valid_target_days: int
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True)
class ModelComponent:
    model_name: str
    model_version: str
    weight: Decimal


@dataclass(frozen=True)
class ForecastProduct:
    """Stable product/location identity supplied independently of sales rows."""

    location_id: str
    product_id: str
    product_name: str
    unit: str
    sku: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(
            self, "location_id", required_identifier(self.location_id, "location_id")
        )
        object.__setattr__(
            self, "product_id", required_identifier(self.product_id, "product_id")
        )
        if not self.product_name.strip():
            raise DemandDataError("product_name is required")
        if not self.unit.strip():
            raise DemandDataError("unit is required")
        object.__setattr__(self, "product_name", self.product_name.strip())
        object.__setattr__(self, "unit", self.unit.strip())
        if self.sku is not None:
            object.__setattr__(self, "sku", self.sku.strip() or None)

    @property
    def series_key(self) -> DemandSeriesKey:
        return DemandSeriesKey(self.location_id, self.product_id)


@dataclass(frozen=True)
class HistoricalDemandDataset:
    """A bounded historical series with explicit real/synthetic provenance.

    `history_start=None` means the product has no known history. An empty set of
    observations can still represent known zero demand when history_start is
    present, because the Stage 5A contract omits zero-demand dates.
    """

    product: ForecastProduct
    history_start: date | None
    history_end: date
    observations: tuple[DailyDemand, ...]
    provenance: DataProvenance
    availability_evidence: tuple[AvailabilityEvidence, ...] = ()
    role: DatasetRole = DatasetRole.HISTORICAL

    def __post_init__(self) -> None:
        if self.role is not DatasetRole.HISTORICAL:
            raise DemandDataError("forecast input must have the historical role")
        if not isinstance(self.provenance, DataProvenance):
            raise DemandDataError("data provenance must be real or synthetic")
        if self.history_start is None and self.observations:
            raise DemandDataError("history_start is required when observations exist")
        if self.history_start is not None and self.history_start > self.history_end:
            raise DemandDataError("history_start must not be after history_end")
        evidence_dates: set[date] = set()
        for evidence in self.availability_evidence:
            if not isinstance(evidence.status, AvailabilityStatus):
                raise DemandDataError("availability status is invalid")
            if evidence.business_date in evidence_dates:
                raise DemandDataError("availability evidence contains a duplicate date")
            evidence_dates.add(evidence.business_date)
            if self.history_start is None or not (
                self.history_start <= evidence.business_date <= self.history_end
            ):
                raise DemandDataError("availability evidence falls outside history bounds")

    @classmethod
    def from_real_observations(
        cls,
        *,
        product: ForecastProduct,
        history_start: date | None,
        history_end: date,
        observations: Iterable[DailyDemand],
        availability_evidence: Iterable[AvailabilityEvidence] = (),
    ) -> HistoricalDemandDataset:
        return cls(
            product=product,
            history_start=history_start,
            history_end=history_end,
            observations=tuple(observations),
            provenance=DataProvenance.REAL,
            availability_evidence=tuple(availability_evidence),
        )

    @classmethod
    def from_synthetic_observations(
        cls,
        *,
        product: ForecastProduct,
        history_start: date | None,
        history_end: date,
        observations: Iterable[DailyDemand],
        availability_evidence: Iterable[AvailabilityEvidence] = (),
    ) -> HistoricalDemandDataset:
        return cls(
            product=product,
            history_start=history_start,
            history_end=history_end,
            observations=tuple(observations),
            provenance=DataProvenance.SYNTHETIC,
            availability_evidence=tuple(availability_evidence),
        )


@dataclass(frozen=True)
class ForecastMetadata:
    model_name: str
    model_version: str
    lookback_days: int
    history_days_available: int
    sample_days_used: int
    nonzero_demand_days: int
    is_cold_start: bool
    cold_start_reason: ColdStartReason | None
    cold_start_strategy: ColdStartStrategy | None
    history_start: date | None
    history_end: date
    dataset_role: DatasetRole
    data_provenance: DataProvenance
    forecast_horizon_days: int
    data_quality: DataQualityMetadata
    fallback_reason: str | None = None
    calibration_factor: Decimal | None = None
    calibration_points: int = 0
    calibration_period_end: date | None = None
    components: tuple[ModelComponent, ...] = ()


@dataclass(frozen=True)
class DemandForecast:
    forecast_date: date
    location_id: str
    product_id: str
    product_name: str
    unit: str
    quantity: Decimal
    metadata: ForecastMetadata
    sku: str | None = None

    @property
    def series_key(self) -> DemandSeriesKey:
        return DemandSeriesKey(self.location_id, self.product_id)
