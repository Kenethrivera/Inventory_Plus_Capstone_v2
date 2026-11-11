from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal

from app.data import DailyDemand
from app.forecasting import ForecastProduct, HistoricalDemandDataset


LOCATION_ID = "11111111-1111-1111-1111-111111111111"
HISTORY_START = date(2025, 1, 1)
HISTORY_END = date(2026, 11, 7)
SIMULATION_SEED = 26061108


@dataclass(frozen=True)
class FullInventoryProduct:
    plan_index: int
    product_id: str
    sku: str
    product_name: str
    category: str
    unit: str
    demand_pattern: str

    @property
    def forecast_product(self) -> ForecastProduct:
        return ForecastProduct(
            location_id=LOCATION_ID,
            product_id=self.product_id,
            sku=self.sku,
            product_name=self.product_name,
            unit=self.unit,
        )


PRODUCTS: tuple[FullInventoryProduct, ...] = (
    FullInventoryProduct(1, "22222222-2222-2222-2222-222222222221", "SKU-001", "Heavy Duty Staple Gun", "Hand Tools", "pcs", "increasing"),
    FullInventoryProduct(2, "22222222-2222-2222-2222-222222222222", "SKU-002", "Concrete Nails 2-inch", "Fasteners", "kl", "high_seasonal"),
    FullInventoryProduct(3, "7019350c-b165-4d15-ae39-b0ab49341387", "SKU-1004", "Claw Hammer", "Hand Tools", "pcs", "stable_medium"),
    FullInventoryProduct(4, "082643c4-0215-4a9a-a6aa-b99c070bddb7", "SKU-1005", "Phillips Screwdriver", "Hand Tools", "pcs", "increasing_high"),
    FullInventoryProduct(5, "52ab3702-b00b-4969-9fe7-a41f96bd3441", "SKU-1006", "Tape Measure", "Measuring Tools", "pcs", "seasonal_medium"),
    FullInventoryProduct(6, "d9e9be8f-11be-4487-a46e-751d6c26f0ed", "SKU-1007", "Cordless Drill", "Power Tools", "pcs", "intermittent_low"),
    FullInventoryProduct(7, "c9b9ee63-6c49-46b5-97e9-e0227391eda4", "SKU-1008", "PVC Pipe", "Plumbing", "pcs", "decreasing"),
    FullInventoryProduct(8, "f9bac670-bd17-43c7-8416-78e386239a89", "SKU-1009", "Teflon Tape", "Plumbing", "roll", "high_stable"),
    FullInventoryProduct(9, "fb9f102b-c418-40c1-9e4e-52e4d963d4fa", "SKU-1010", "Safety Goggles", "Safety Equipment", "pcs", "growing_seasonal"),
    FullInventoryProduct(10, "ab0af441-e26b-4d9c-95b3-7b5fd0e42be1", "SKU-3UWPD0GN", "Adjustable wrench", "Wrench", "pcs", "decreasing_slow"),
    FullInventoryProduct(11, "90a2f7df-01a5-40a4-abaf-7e1615949f28", "SKU-4W6D3LVI", "realtime_test2", "test", "pcs", "dead_stock"),
    FullInventoryProduct(12, "e1b81338-b56e-46c6-bbfe-fa6eab25f394", "SKU-69QAUJ4Z", "test item", "test", "pcs", "no_sales"),
    FullInventoryProduct(13, "a2df295b-5fbc-4dd3-bd49-f3737627dd00", "SKU-K1CB7XQV", "Concrete Nails 1-inch", "Nails", "kl", "intermittent_seasonal"),
)


def simulated_quantity(product: FullInventoryProduct, business_date: date) -> Decimal:
    """Mirror the deterministic SQL 02 fixture without exposing it to models."""

    if not HISTORY_START <= business_date <= HISTORY_END:
        raise ValueError("business_date is outside the 676-day fixture")
    day_index = (business_date - HISTORY_START).days
    iso_dow = business_date.isoweekday()
    month = business_date.month
    noise = (day_index * 37 + product.plan_index * 53 + SIMULATION_SEED) % 100
    pattern = product.demand_pattern

    if pattern == "increasing":
        value = 1 + day_index // 110 + (1 if iso_dow >= 6 else 0) + (1 if noise < 18 else 0)
    elif pattern == "high_seasonal":
        month_effect = 4 if month in {11, 12} else 2 if month in {3, 4, 5} else 0
        value = 5 + (3 if iso_dow >= 6 else 0) + month_effect + (2 if noise < 22 else 0)
    elif pattern == "stable_medium":
        value = 2 + (1 if iso_dow >= 6 else 0) + (1 if noise < 30 else 0)
    elif pattern == "increasing_high":
        value = 2 + day_index // 150 + (2 if iso_dow >= 6 else 0) + (2 if noise < 25 else 0)
    elif pattern == "seasonal_medium":
        month_effect = 4 if month in {6, 7, 8} else 3 if month in {11, 12} else 0
        value = 2 + month_effect + (2 if iso_dow == 6 else 0) + (1 if noise < 20 else 0)
    elif pattern == "intermittent_low":
        value = 1 + (1 if noise < 35 else 0) if (day_index + product.plan_index * 5) % 9 == 0 else 0
    elif pattern == "decreasing":
        value = max(0, 8 - day_index // 105 + (1 if iso_dow >= 6 else 0) + (1 if noise < 15 else 0))
    elif pattern == "high_stable":
        value = 8 + (4 if iso_dow >= 6 else 0) + noise // 34
    elif pattern == "growing_seasonal":
        month_effect = 3 if month in {6, 7, 8} else 2 if month in {11, 12} else 0
        value = 2 + day_index // 225 + month_effect + (1 if iso_dow == 7 else 0) + (1 if noise < 20 else 0)
    elif pattern == "decreasing_slow":
        value = max(0, 5 - day_index // 150 + (1 if (day_index + product.plan_index) % 3 == 0 else 0))
    elif pattern == "dead_stock":
        cutoff = HISTORY_END - timedelta(days=180)
        value = 1 if business_date <= cutoff and (day_index + product.plan_index) % 14 == 0 else 0
    elif pattern == "no_sales":
        value = 0
    elif pattern == "intermittent_seasonal":
        if (day_index + product.plan_index * 2) % 5 == 0:
            value = 2 + (2 if month in {11, 12} else 0) + (1 if noise < 25 else 0)
        else:
            value = 0
    else:
        raise ValueError(f"unsupported simulation demand pattern: {pattern}")
    return Decimal(value)


def full_inventory_datasets() -> tuple[HistoricalDemandDataset, ...]:
    values: list[HistoricalDemandDataset] = []
    for product in PRODUCTS:
        observations: list[DailyDemand] = []
        current = HISTORY_START
        while current <= HISTORY_END:
            quantity = simulated_quantity(product, current)
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
        values.append(
            HistoricalDemandDataset.from_synthetic_observations(
                product=product.forecast_product,
                history_start=HISTORY_START,
                history_end=HISTORY_END,
                observations=observations,
            )
        )
    return tuple(values)


def bounded_dataset(
    dataset: HistoricalDemandDataset,
    origin: date,
    *,
    max_history_days: int | None = None,
) -> HistoricalDemandDataset:
    if dataset.history_start is None or not dataset.history_start <= origin <= dataset.history_end:
        raise ValueError("origin is outside the dataset history")
    if max_history_days is not None and max_history_days <= 0:
        raise ValueError("max_history_days must be positive")
    history_start = dataset.history_start
    if max_history_days is not None:
        history_start = max(
            history_start, origin - timedelta(days=max_history_days - 1)
        )
    return HistoricalDemandDataset.from_synthetic_observations(
        product=dataset.product,
        history_start=history_start,
        history_end=origin,
        observations=(
            value
            for value in dataset.observations
            if history_start <= value.business_date <= origin
        ),
        availability_evidence=(
            value
            for value in dataset.availability_evidence
            if history_start <= value.business_date <= origin
        ),
    )
