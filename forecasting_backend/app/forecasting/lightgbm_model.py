from __future__ import annotations

import math
from dataclasses import dataclass, replace
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Iterable

from app.data.validation import DemandDataError

from .mean28 import Mean28Forecaster
from .models import (
    DemandForecast,
    ForecastMetadata,
    HistoricalDemandDataset,
    ModelComponent,
)
from .series import PreparedSeries, prepare_history


@dataclass(frozen=True)
class LightGBMConfig:
    min_history_days: int = 84
    min_training_rows: int = 40
    n_estimators: int = 80
    learning_rate: float = 0.05
    num_leaves: int = 15
    random_seed: int = 2505

    def __post_init__(self) -> None:
        if self.min_history_days < 29:
            raise ValueError("min_history_days must allow 28 lag days")
        if self.min_training_rows <= 0 or self.n_estimators <= 0:
            raise ValueError("training row and estimator counts must be positive")


class LightGBMForecaster:
    """Train one deterministic LightGBM model per product/location series.

    Models are always trained from the supplied Inventory Plus history. No
    external or Walmart-trained artifact is loaded or treated as validated for
    this domain.
    """

    MODEL_NAME = "lightgbm"
    MODEL_VERSION = "1"
    LOOKBACK_DAYS = 28

    def __init__(
        self,
        *,
        config: LightGBMConfig | None = None,
        mean28: Mean28Forecaster | None = None,
    ) -> None:
        self.config = config or LightGBMConfig()
        self.mean28 = mean28 or Mean28Forecaster()

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        if isinstance(horizon_days, bool) or not isinstance(horizon_days, int):
            raise DemandDataError("horizon_days must be an integer")
        if horizon_days <= 0:
            raise DemandDataError("horizon_days must be greater than zero")

        prepared = prepare_history(dataset)
        if len(prepared.days) < self.config.min_history_days:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_training_history",
            )

        features, targets = self._training_matrix(prepared)
        if len(targets) < self.config.min_training_rows:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_uncensored_training_rows",
            )

        try:
            model = self._new_regressor()
            model.fit(features, targets)
            values = [float(day.model_value) for day in prepared.days]
            predictions: list[Decimal] = []
            clipped = False
            for offset in range(1, horizon_days + 1):
                forecast_date = dataset.history_end + timedelta(days=offset)
                row = self._feature_row(values, len(values), forecast_date)
                raw = float(model.predict([row])[0])
                if not math.isfinite(raw):
                    raise ArithmeticError("LightGBM produced a non-finite value")
                if raw < 0:
                    clipped = True
                value = max(0.0, raw)
                values.append(value)
                predictions.append(Decimal(format(value, ".12g")))
        except ImportError:
            return self._fallback(
                dataset, horizon_days, "lightgbm_unavailable"
            )
        except Exception:
            return self._fallback(
                dataset, horizon_days, "lightgbm_training_or_validation_failed"
            )

        warnings = prepared.data_quality.warnings + (
            "model_trained_only_on_current_product_location_history",
        )
        if clipped:
            warnings += ("negative_model_predictions_clipped_to_zero",)
        quality = replace(prepared.data_quality, warnings=warnings)
        recent = [
            day
            for day in prepared.days[-self.LOOKBACK_DAYS :]
            if not day.is_stockout_censored
        ]
        metadata = ForecastMetadata(
            model_name=self.MODEL_NAME,
            model_version=self.MODEL_VERSION,
            lookback_days=self.LOOKBACK_DAYS,
            history_days_available=len(prepared.days),
            sample_days_used=len(targets),
            nonzero_demand_days=sum(1 for day in recent if day.sales_quantity > 0),
            is_cold_start=False,
            cold_start_reason=None,
            cold_start_strategy=None,
            history_start=dataset.history_start,
            history_end=dataset.history_end,
            dataset_role=dataset.role,
            data_provenance=dataset.provenance,
            forecast_horizon_days=horizon_days,
            data_quality=quality,
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
                forecast_date=dataset.history_end + timedelta(days=index + 1),
                location_id=product.location_id,
                product_id=product.product_id,
                sku=product.sku,
                product_name=product.product_name,
                unit=product.unit,
                quantity=quantity,
                metadata=metadata,
            )
            for index, quantity in enumerate(predictions)
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
        result: list[DemandForecast] = []
        for key in sorted(by_key):
            result.extend(self.forecast(by_key[key], horizon_days=horizon_days))
        return result

    def _new_regressor(self) -> Any:
        from lightgbm import LGBMRegressor

        return LGBMRegressor(
            objective="regression_l1",
            n_estimators=self.config.n_estimators,
            learning_rate=self.config.learning_rate,
            num_leaves=self.config.num_leaves,
            random_state=self.config.random_seed,
            bagging_seed=self.config.random_seed,
            feature_fraction_seed=self.config.random_seed,
            data_random_seed=self.config.random_seed,
            deterministic=True,
            force_col_wise=True,
            n_jobs=1,
            verbosity=-1,
        )

    def _training_matrix(
        self, prepared: PreparedSeries
    ) -> tuple[list[list[float]], list[float]]:
        values = [float(day.model_value) for day in prepared.days]
        features: list[list[float]] = []
        targets: list[float] = []
        for index in range(self.LOOKBACK_DAYS, len(prepared.days)):
            day = prepared.days[index]
            if day.is_stockout_censored:
                continue
            features.append(self._feature_row(values, index, day.business_date))
            targets.append(float(day.sales_quantity))
        return features, targets

    @staticmethod
    def _feature_row(values: list[float], index: int, target_date: date) -> list[float]:
        if index < 28:
            raise DemandDataError("LightGBM features require 28 prior days")
        prior7 = values[index - 7 : index]
        prior28 = values[index - 28 : index]
        weekday_angle = 2.0 * math.pi * target_date.weekday() / 7.0
        year_angle = 2.0 * math.pi * target_date.timetuple().tm_yday / 365.25
        return [
            values[index - 1],
            values[index - 7],
            values[index - 14],
            values[index - 28],
            sum(prior7) / 7.0,
            sum(prior28) / 28.0,
            math.sin(weekday_angle),
            math.cos(weekday_angle),
            math.sin(year_angle),
            math.cos(year_angle),
            float(index),
        ]

    def _fallback(
        self,
        dataset: HistoricalDemandDataset,
        horizon_days: int,
        reason: str,
    ) -> list[DemandForecast]:
        baseline = self.mean28.forecast(dataset, horizon_days=horizon_days)
        warning = f"mean28_fallback:{reason}"
        result: list[DemandForecast] = []
        for value in baseline:
            quality = replace(
                value.metadata.data_quality,
                warnings=value.metadata.data_quality.warnings + (warning,),
            )
            metadata = replace(
                value.metadata,
                model_name="mean28_fallback",
                fallback_reason=reason,
                data_quality=quality,
            )
            result.append(replace(value, metadata=metadata))
        return result
