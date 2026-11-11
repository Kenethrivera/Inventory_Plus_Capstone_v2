from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal

from app.data.models import DailyDemand
from app.data.validation import DemandDataError

from .models import (
    AvailabilityStatus,
    DataQualityMetadata,
    HistoricalDemandDataset,
)


@dataclass(frozen=True)
class PreparedDay:
    business_date: date
    sales_quantity: Decimal
    model_value: Decimal
    is_stockout_censored: bool


@dataclass(frozen=True)
class PreparedSeries:
    days: tuple[PreparedDay, ...]
    data_quality: DataQualityMetadata


def prepare_history(dataset: HistoricalDemandDataset) -> PreparedSeries:
    """Validate and calendarize one isolated product/location history.

    Missing Stage 5A rows remain zero *sales*. If explicit stockout evidence is
    present, that date is censored as a target and its lag value is imputed
    using prior values only. This avoids turning a known stockout into assumed
    zero underlying demand without introducing future-data leakage.
    """
    if dataset.history_start is None:
        warnings = ("no_history_zero_is_not_confirmed_customer_demand",)
        return PreparedSeries(
            days=(),
            data_quality=DataQualityMetadata(
                history_calendar_days=0,
                observed_sales_days=0,
                assumed_zero_sales_days=0,
                stockout_censored_days=0,
                availability_evidence_days=0,
                availability_unknown_days=0,
                valid_target_days=0,
                warnings=warnings,
            ),
        )

    by_date: dict[date, DailyDemand] = {}
    for value in dataset.observations:
        if value.series_key != dataset.product.series_key:
            raise DemandDataError(
                "historical demand does not match the dataset product/location"
            )
        if value.unit != dataset.product.unit:
            raise DemandDataError("historical demand unit does not match the product")
        if not dataset.history_start <= value.business_date <= dataset.history_end:
            raise DemandDataError("historical demand falls outside dataset bounds")
        if value.business_date in by_date:
            raise DemandDataError("historical demand contains a duplicate date")
        if not isinstance(value.quantity, Decimal):
            raise DemandDataError("historical demand quantities must be decimals")
        if not value.quantity.is_finite() or value.quantity < 0:
            raise DemandDataError(
                "historical demand quantities must be finite and nonnegative"
            )
        if value.completed_order_count < 0:
            raise DemandDataError("completed_order_count must be nonnegative")
        by_date[value.business_date] = value

    availability = {
        value.business_date: value.status for value in dataset.availability_evidence
    }
    days: list[PreparedDay] = []
    assumed_zero_days = 0
    stockout_days = 0
    current = dataset.history_start
    while current <= dataset.history_end:
        observation = by_date.get(current)
        sales = observation.quantity if observation else Decimal("0")
        status = availability.get(current)
        censored = status is AvailabilityStatus.STOCKOUT
        if censored:
            stockout_days += 1
            prior = [day.model_value for day in days[-28:]]
            model_value = (
                sum(prior, Decimal("0")) / Decimal(len(prior))
                if prior
                else Decimal("0")
            )
        else:
            model_value = sales
            if observation is None:
                assumed_zero_days += 1
        days.append(
            PreparedDay(
                business_date=current,
                sales_quantity=sales,
                model_value=model_value,
                is_stockout_censored=censored,
            )
        )
        current += timedelta(days=1)

    unknown_days = len(days) - len(availability)
    warnings: list[str] = []
    if stockout_days:
        warnings.append("stockout_censored_targets_excluded")
    if unknown_days:
        warnings.append(
            "availability_incomplete_sales_may_understate_unconstrained_demand"
        )
    if assumed_zero_days:
        warnings.append("missing_rpc_rows_interpreted_as_zero_sales")

    return PreparedSeries(
        days=tuple(days),
        data_quality=DataQualityMetadata(
            history_calendar_days=len(days),
            observed_sales_days=len(by_date),
            assumed_zero_sales_days=assumed_zero_days,
            stockout_censored_days=stockout_days,
            availability_evidence_days=len(availability),
            availability_unknown_days=unknown_days,
            valid_target_days=len(days) - stockout_days,
            warnings=tuple(warnings),
        ),
    )
