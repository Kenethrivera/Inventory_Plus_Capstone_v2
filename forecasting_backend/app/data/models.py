from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal


@dataclass(frozen=True, order=True)
class DemandSeriesKey:
    """Stable identity for one product at one store location."""

    location_id: str
    product_id: str


@dataclass(frozen=True)
class DailyDemand:
    business_date: date
    location_id: str
    product_id: str
    product_name: str
    unit: str
    quantity: Decimal
    completed_order_count: int
    sku: str | None = None

    @property
    def series_key(self) -> DemandSeriesKey:
        return DemandSeriesKey(self.location_id, self.product_id)

