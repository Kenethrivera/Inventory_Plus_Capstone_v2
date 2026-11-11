from __future__ import annotations

from datetime import date

from app.data import DailyDemand
from app.forecasting import (
    AvailabilityEvidence,
    AvailabilityStatus,
    ForecastProduct,
    HistoricalDemandDataset,
)

from .models import SyntheticDay, SyntheticProductPolicy, SyntheticScenario


def historical_dataset(
    scenario: SyntheticScenario,
    policy: SyntheticProductPolicy,
    *,
    history_end: date,
    observed_days: tuple[SyntheticDay, ...] | None = None,
) -> HistoricalDemandDataset:
    product = ForecastProduct(
        location_id=policy.location_id,
        product_id=policy.product_id,
        sku=policy.sku,
        product_name=policy.name,
        unit=policy.unit,
    )
    if history_end < policy.launch_date:
        return HistoricalDemandDataset.from_synthetic_observations(
            product=product,
            history_start=None,
            history_end=history_end,
            observations=(),
        )
    source = (
        observed_days
        if observed_days is not None
        else scenario.series(policy.location_id, policy.product_id)
    )
    bounded = tuple(
        value
        for value in source
        if policy.launch_date <= value.business_date <= history_end
    )
    observations = tuple(
        DailyDemand(
            business_date=value.business_date,
            location_id=policy.location_id,
            product_id=policy.product_id,
            sku=policy.sku,
            product_name=policy.name,
            unit=policy.unit,
            quantity=value.fulfilled_sales,
            completed_order_count=1,
        )
        for value in bounded
        if value.fulfilled_sales > 0
    )
    availability = tuple(
        AvailabilityEvidence(
            business_date=value.business_date,
            status=(
                AvailabilityStatus.STOCKOUT
                if value.stockout
                else AvailabilityStatus.IN_STOCK
            ),
        )
        for value in bounded
    )
    return HistoricalDemandDataset.from_synthetic_observations(
        product=product,
        history_start=policy.launch_date,
        history_end=history_end,
        observations=observations,
        availability_evidence=availability,
    )
