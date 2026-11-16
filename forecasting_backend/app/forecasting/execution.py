from __future__ import annotations

import sys
from dataclasses import dataclass, replace
from datetime import datetime, timedelta

from .blend import CalibratedBlendForecaster
from .lightgbm_model import LightGBMForecaster
from .mean28 import Mean28Forecaster
from .models import DemandForecast, HistoricalDemandDataset
from .product_specific_seasonal_lightgbm import (
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.performance_diagnostics import log_duration, start_timer


@dataclass(frozen=True)
class DemandForecastExecutionInput:
    """Frozen inputs for one demand forecast execution.

    ``history`` carries the product/location identity, unit, provenance,
    availability evidence, and inclusive historical date bounds. ``as_of``
    and ``source_data_as_of`` are supplied by the caller so a worker can replay
    the same logical execution without consulting its own wall clock. The
    caller owns authorization and model/horizon validation; model instances and
    their configuration are pinned when the executor is constructed.
    """

    history: HistoricalDemandDataset
    model: str
    horizon_days: int
    as_of: datetime
    source_data_as_of: datetime
    preliminary_horizon_days: int


@dataclass(frozen=True)
class DemandForecastExecution:
    """Demand outputs needed by existing forecast and recommendation paths."""

    requested_forecasts: tuple[DemandForecast, ...]
    recommendation_forecasts: tuple[DemandForecast, ...]
    preliminary_forecasts: tuple[DemandForecast, ...]
    as_of: datetime
    source_data_as_of: datetime
    experimental_fallback_reason: str | None = None


class DemandForecastExecutor:
    """Runs existing forecast models against explicit frozen inputs.

    This class owns model selection and the existing auxiliary LightGBM
    forecasts. It does not load external data, authorize a user, inspect
    inventory, calculate recommendations, or read the current clock.
    Forecaster instances are injected so the API service and a future worker
    can use the same configured model implementations.
    """

    def __init__(
        self,
        *,
        mean28: Mean28Forecaster,
        lightgbm: LightGBMForecaster,
        blend: CalibratedBlendForecaster,
        seasonal_experimental: ProductSpecificSeasonalLightGBMForecaster,
    ) -> None:
        self._mean28 = mean28
        self._lightgbm = lightgbm
        self._blend = blend
        self._seasonal_experimental = seasonal_experimental

    def execute(self, inputs: DemandForecastExecutionInput) -> DemandForecastExecution:
        model = inputs.model
        history = inputs.history
        recommendation_history = history
        fallback_reason = None

        model_started = start_timer()
        lightgbm_loaded_before = "lightgbm" in sys.modules
        if model == "seasonal_experimental":
            recommendation_history = self._bounded_history(
                history, history_days=365
            )
            candidate = self._seasonal_experimental.forecast(
                history, horizon_days=inputs.horizon_days
            )
            if (
                candidate[0].metadata.model_name
                == self._seasonal_experimental.model_name
            ):
                requested_forecasts = candidate
            else:
                fallback_reason = (
                    candidate[0].metadata.fallback_reason
                    or "experimental_candidate_unavailable"
                )
                requested_forecasts = self._lightgbm.forecast(
                    recommendation_history, horizon_days=inputs.horizon_days
                )
        else:
            forecaster = {
                "mean28": self._mean28,
                "lightgbm": self._lightgbm,
                "blend": self._blend,
            }[model]
            requested_forecasts = forecaster.forecast(
                history, horizon_days=inputs.horizon_days
            )
        log_duration(
            "analysis.requested_model_forecast",
            model_started,
            model=model,
            lightgbm_loaded_before=lightgbm_loaded_before,
            lightgbm_loaded_after="lightgbm" in sys.modules,
        )

        recommendation_forecasts = requested_forecasts
        if model == "seasonal_experimental":
            recommendation_started = start_timer()
            recommendation_forecasts = self._lightgbm.forecast(
                recommendation_history, horizon_days=inputs.horizon_days
            )
            log_duration(
                "analysis.recommendation_forecast_model",
                recommendation_started,
                model="lightgbm",
                horizon_days=inputs.horizon_days,
            )

        if (
            inputs.horizon_days == inputs.preliminary_horizon_days
            and model in {"lightgbm", "seasonal_experimental"}
        ):
            preliminary_forecasts = recommendation_forecasts
        else:
            preliminary_started = start_timer()
            preliminary_forecasts = self._lightgbm.forecast(
                recommendation_history,
                horizon_days=inputs.preliminary_horizon_days,
            )
            log_duration(
                "analysis.preliminary_forecast_model",
                preliminary_started,
                model="lightgbm",
                horizon_days=inputs.preliminary_horizon_days,
            )

        return DemandForecastExecution(
            requested_forecasts=tuple(requested_forecasts),
            recommendation_forecasts=tuple(recommendation_forecasts),
            preliminary_forecasts=tuple(preliminary_forecasts),
            as_of=inputs.as_of,
            source_data_as_of=inputs.source_data_as_of,
            experimental_fallback_reason=fallback_reason,
        )

    @staticmethod
    def _bounded_history(
        history: HistoricalDemandDataset,
        *,
        history_days: int,
    ) -> HistoricalDemandDataset:
        if history.history_start is None:
            return history
        start = max(
            history.history_start,
            history.history_end - timedelta(days=history_days - 1),
        )
        return replace(
            history,
            history_start=start,
            observations=tuple(
                value
                for value in history.observations
                if start <= value.business_date <= history.history_end
            ),
            availability_evidence=tuple(
                value
                for value in history.availability_evidence
                if start <= value.business_date <= history.history_end
            ),
        )
