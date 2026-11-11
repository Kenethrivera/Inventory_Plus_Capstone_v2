from __future__ import annotations

from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
from typing import Iterable

from app.data.validation import DemandDataError

from .models import (
    ColdStartReason,
    ColdStartStrategy,
    DemandForecast,
    ForecastMetadata,
    HistoricalDemandDataset,
    ModelComponent,
)
from .series import prepare_history


class Mean28Forecaster:
    """A calendar-day mean baseline over at most the latest 28 known days.

    Missing Stage 5A rows inside the declared history boundary represent zero
    demand. With 1-27 known days, the model uses the mean of those available
    calendar days and marks every output as cold-start. With no known history,
    it emits zero forecasts with an explicit no-history reason.
    """

    MODEL_NAME = "mean28"
    MODEL_VERSION = "1"
    LOOKBACK_DAYS = 28

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        if isinstance(horizon_days, bool) or not isinstance(horizon_days, int):
            raise DemandDataError("horizon_days must be an integer")
        if horizon_days <= 0:
            raise DemandDataError("horizon_days must be greater than zero")
        prepared = prepare_history(dataset)
        history_days = len(prepared.days)
        cold_start_reason: ColdStartReason | None = None
        cold_start_strategy: ColdStartStrategy | None = None
        if history_days == 0:
            cold_start_reason = ColdStartReason.NO_HISTORY
            cold_start_strategy = ColdStartStrategy.ZERO
        elif history_days < self.LOOKBACK_DAYS:
            cold_start_reason = ColdStartReason.INSUFFICIENT_HISTORY
            cold_start_strategy = ColdStartStrategy.AVAILABLE_DAY_MEAN

        window = prepared.days[-self.LOOKBACK_DAYS :]
        usable_days = [day for day in window if not day.is_stockout_censored]
        sample_days = len(usable_days)
        if not usable_days:
            mean = Decimal("0")
            nonzero_days = 0
        else:
            mean = sum(
                (day.sales_quantity for day in usable_days), Decimal("0")
            ) / Decimal(sample_days)
            nonzero_days = sum(1 for day in usable_days if day.sales_quantity > 0)

        if not mean.is_finite() or mean < 0:
            raise DemandDataError("Mean28 produced an invalid forecast")

        data_quality = prepared.data_quality
        if history_days > 0 and not usable_days:
            data_quality = replace(
                data_quality,
                warnings=data_quality.warnings
                + ("no_uncensored_days_zero_is_not_confirmed_customer_demand",),
            )
        if cold_start_reason is not None and mean == 0:
            data_quality = replace(
                data_quality,
                warnings=data_quality.warnings
                + ("cold_start_zero_is_not_confirmed_customer_demand",),
            )
        metadata = ForecastMetadata(
            model_name=self.MODEL_NAME,
            model_version=self.MODEL_VERSION,
            lookback_days=self.LOOKBACK_DAYS,
            history_days_available=history_days,
            sample_days_used=sample_days,
            nonzero_demand_days=nonzero_days,
            is_cold_start=cold_start_reason is not None,
            cold_start_reason=cold_start_reason,
            cold_start_strategy=cold_start_strategy,
            history_start=dataset.history_start,
            history_end=dataset.history_end,
            dataset_role=dataset.role,
            data_provenance=dataset.provenance,
            forecast_horizon_days=horizon_days,
            data_quality=data_quality,
            components=(
                ModelComponent(
                    model_name=self.MODEL_NAME,
                    model_version=self.MODEL_VERSION,
                    weight=Decimal("1"),
                ),
            ),
        )
        product = dataset.product
        return [
            DemandForecast(
                forecast_date=dataset.history_end + timedelta(days=offset),
                location_id=product.location_id,
                product_id=product.product_id,
                sku=product.sku,
                product_name=product.product_name,
                unit=product.unit,
                quantity=mean,
                metadata=metadata,
            )
            for offset in range(1, horizon_days + 1)
        ]

    def forecast_many(
        self,
        datasets: Iterable[HistoricalDemandDataset],
        *,
        horizon_days: int,
    ) -> list[DemandForecast]:
        by_key: dict[object, HistoricalDemandDataset] = {}
        provenances = set()
        for dataset in datasets:
            key = dataset.product.series_key
            if key in by_key:
                raise DemandDataError(
                    "each product/location series must be supplied exactly once"
                )
            by_key[key] = dataset
            provenances.add(dataset.provenance)
        if len(provenances) > 1:
            raise DemandDataError(
                "a forecast batch cannot mix real and synthetic history"
            )

        forecasts: list[DemandForecast] = []
        for key in sorted(by_key):
            forecasts.extend(self.forecast(by_key[key], horizon_days=horizon_days))
        return forecasts

