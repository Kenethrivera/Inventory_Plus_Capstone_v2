from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date
from decimal import Decimal
from typing import Iterable

from app.data.validation import DemandDataError

from .backtesting import (
    BacktestPoint,
    RollingOriginBacktester,
    RollingOriginConfig,
)
from .lightgbm_model import LightGBMForecaster
from .mean28 import Mean28Forecaster
from .models import DemandForecast, HistoricalDemandDataset, ModelComponent


@dataclass(frozen=True)
class CalibratedBlendConfig:
    lightgbm_weight: Decimal = Decimal("0.5")
    mean28_weight: Decimal = Decimal("0.5")
    minimum_calibration_points: int = 28
    minimum_bias_factor: Decimal = Decimal("0.5")
    maximum_bias_factor: Decimal = Decimal("2.0")
    rolling_origin: RollingOriginConfig = RollingOriginConfig()

    def __post_init__(self) -> None:
        if self.lightgbm_weight < 0 or self.mean28_weight < 0:
            raise ValueError("blend weights must be nonnegative")
        if self.lightgbm_weight + self.mean28_weight != Decimal("1"):
            raise ValueError("blend weights must sum to one")
        if self.minimum_calibration_points <= 0:
            raise ValueError("minimum_calibration_points must be positive")
        if not Decimal("0") < self.minimum_bias_factor <= self.maximum_bias_factor:
            raise ValueError("bias factor bounds are invalid")


@dataclass(frozen=True)
class BiasCalibration:
    factor: Decimal
    points_used: int
    period_end: date
    was_clipped: bool


def learn_multiplicative_bias(
    points: Iterable[BacktestPoint],
    *,
    config: CalibratedBlendConfig,
) -> BiasCalibration | None:
    eligible = [
        point
        for point in points
        if point.lightgbm_used
        and not point.is_stockout_censored
        and point.actual_quantity is not None
    ]
    if len(eligible) < config.minimum_calibration_points:
        return None
    raw_predictions = [
        config.lightgbm_weight * point.lightgbm_quantity
        + config.mean28_weight * point.mean28_quantity
        for point in eligible
    ]
    prediction_total = sum(raw_predictions, Decimal("0"))
    actual_total = sum(
        (point.actual_quantity for point in eligible if point.actual_quantity is not None),
        Decimal("0"),
    )
    if prediction_total == 0:
        if actual_total != 0:
            return None
        factor = Decimal("1")
    else:
        factor = actual_total / prediction_total
    clipped_factor = min(
        config.maximum_bias_factor, max(config.minimum_bias_factor, factor)
    )
    return BiasCalibration(
        factor=clipped_factor,
        points_used=len(eligible),
        period_end=max(point.forecast_date for point in eligible),
        was_clipped=clipped_factor != factor,
    )


class CalibratedBlendForecaster:
    """50/50 LightGBM/Mean28 candidate with earlier-period bias calibration."""

    MODEL_NAME = "calibrated_lightgbm_mean28_blend"
    MODEL_VERSION = "1"

    def __init__(
        self,
        *,
        config: CalibratedBlendConfig | None = None,
        lightgbm: LightGBMForecaster | None = None,
        mean28: Mean28Forecaster | None = None,
        backtester: RollingOriginBacktester | None = None,
    ) -> None:
        self.config = config or CalibratedBlendConfig()
        self.mean28 = mean28 or Mean28Forecaster()
        self.lightgbm = lightgbm or LightGBMForecaster(mean28=self.mean28)
        self.backtester = backtester or RollingOriginBacktester(
            lightgbm=self.lightgbm, mean28=self.mean28
        )

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        mean_values = self.mean28.forecast(dataset, horizon_days=horizon_days)
        ml_values = self.lightgbm.forecast(dataset, horizon_days=horizon_days)
        if any(value.metadata.model_name != "lightgbm" for value in ml_values):
            reason = ml_values[0].metadata.fallback_reason or "lightgbm_not_validated"
            return self._fallback(mean_values, f"blend_unavailable:{reason}")

        report = self.backtester.run(dataset, config=self.config.rolling_origin)
        calibration = learn_multiplicative_bias(
            report.points, config=self.config
        )
        if calibration is None:
            return self._fallback(mean_values, "insufficient_calibration_history")

        results: list[DemandForecast] = []
        for ml_value, mean_value in zip(ml_values, mean_values, strict=True):
            if ml_value.forecast_date != mean_value.forecast_date:
                raise DemandDataError("blend component forecast dates do not align")
            raw = (
                self.config.lightgbm_weight * ml_value.quantity
                + self.config.mean28_weight * mean_value.quantity
            )
            quantity = raw * calibration.factor
            if not quantity.is_finite() or quantity < 0:
                return self._fallback(mean_values, "blend_validation_failed")
            quality = ml_value.metadata.data_quality
            warnings = quality.warnings
            if dataset.provenance.value == "synthetic":
                warnings += (
                    "synthetic_evaluation_does_not_establish_real_store_accuracy",
                )
            if calibration.was_clipped:
                warnings += ("bias_calibration_factor_clipped",)
            metadata = replace(
                ml_value.metadata,
                model_name=self.MODEL_NAME,
                model_version=self.MODEL_VERSION,
                forecast_horizon_days=horizon_days,
                data_quality=replace(quality, warnings=warnings),
                fallback_reason=None,
                calibration_factor=calibration.factor,
                calibration_points=calibration.points_used,
                calibration_period_end=calibration.period_end,
                components=(
                    ModelComponent(
                        model_name="lightgbm",
                        model_version=LightGBMForecaster.MODEL_VERSION,
                        weight=self.config.lightgbm_weight,
                    ),
                    ModelComponent(
                        model_name="mean28",
                        model_version=Mean28Forecaster.MODEL_VERSION,
                        weight=self.config.mean28_weight,
                    ),
                ),
            )
            results.append(replace(ml_value, quantity=quantity, metadata=metadata))
        return results

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

    @staticmethod
    def _fallback(
        mean_values: list[DemandForecast], reason: str
    ) -> list[DemandForecast]:
        results: list[DemandForecast] = []
        for value in mean_values:
            quality = replace(
                value.metadata.data_quality,
                warnings=value.metadata.data_quality.warnings
                + (f"mean28_fallback:{reason}",),
            )
            metadata = replace(
                value.metadata,
                model_name="mean28_fallback",
                fallback_reason=reason,
                data_quality=quality,
            )
            results.append(replace(value, metadata=metadata))
        return results
