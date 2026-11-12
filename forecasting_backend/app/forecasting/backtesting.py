from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal

from app.data.validation import DemandDataError

from .lightgbm_model import LightGBMForecaster
from .mean28 import Mean28Forecaster
from .models import DataProvenance, HistoricalDemandDataset
from .series import prepare_history


@dataclass(frozen=True)
class RollingOriginConfig:
    initial_training_days: int = 112
    horizon_days: int = 28
    step_days: int = 28

    def __post_init__(self) -> None:
        if self.initial_training_days <= 0:
            raise ValueError("initial_training_days must be positive")
        if self.horizon_days <= 0 or self.step_days <= 0:
            raise ValueError("horizon_days and step_days must be positive")


@dataclass(frozen=True)
class BacktestPoint:
    origin_date: date
    forecast_date: date
    actual_quantity: Decimal | None
    lightgbm_quantity: Decimal
    mean28_quantity: Decimal
    lightgbm_used: bool
    is_stockout_censored: bool


@dataclass(frozen=True)
class BacktestFold:
    training_start: date
    training_end: date
    validation_start: date
    validation_end: date
    points: tuple[BacktestPoint, ...]


@dataclass(frozen=True)
class BacktestReport:
    folds: tuple[BacktestFold, ...]
    provenance: DataProvenance

    @property
    def points(self) -> tuple[BacktestPoint, ...]:
        return tuple(point for fold in self.folds for point in fold.points)


class RollingOriginBacktester:
    """Expanding-window evaluation with strictly future validation periods."""

    def __init__(
        self,
        *,
        lightgbm: LightGBMForecaster | None = None,
        mean28: Mean28Forecaster | None = None,
    ) -> None:
        self.lightgbm = lightgbm or LightGBMForecaster()
        self.mean28 = mean28 or Mean28Forecaster()

    def run(
        self,
        dataset: HistoricalDemandDataset,
        *,
        config: RollingOriginConfig | None = None,
    ) -> BacktestReport:
        settings = config or RollingOriginConfig()
        if dataset.history_start is None:
            return BacktestReport(folds=(), provenance=dataset.provenance)

        full_series = prepare_history(dataset)
        actual_by_date = {day.business_date: day for day in full_series.days}
        first_origin = dataset.history_start + timedelta(
            days=settings.initial_training_days - 1
        )
        last_origin = dataset.history_end - timedelta(days=settings.horizon_days)
        folds: list[BacktestFold] = []
        origin = first_origin
        while origin <= last_origin:
            training = self._history_through(dataset, origin)
            lightgbm_forecasts = self.lightgbm.forecast(
                training, horizon_days=settings.horizon_days
            )
            mean28_forecasts = self.mean28.forecast(
                training, horizon_days=settings.horizon_days
            )
            points: list[BacktestPoint] = []
            for ml_value, mean_value in zip(
                lightgbm_forecasts, mean28_forecasts, strict=True
            ):
                if ml_value.forecast_date != mean_value.forecast_date:
                    raise DemandDataError("backtest component dates do not align")
                actual = actual_by_date[ml_value.forecast_date]
                points.append(
                    BacktestPoint(
                        origin_date=origin,
                        forecast_date=ml_value.forecast_date,
                        actual_quantity=(
                            None
                            if actual.is_stockout_censored
                            else actual.sales_quantity
                        ),
                        lightgbm_quantity=ml_value.quantity,
                        mean28_quantity=mean_value.quantity,
                        lightgbm_used=ml_value.metadata.model_name == "lightgbm",
                        is_stockout_censored=actual.is_stockout_censored,
                    )
                )
            validation_start = origin + timedelta(days=1)
            validation_end = origin + timedelta(days=settings.horizon_days)
            if not origin < validation_start:
                raise DemandDataError("backtest validation must follow training")
            folds.append(
                BacktestFold(
                    training_start=dataset.history_start,
                    training_end=origin,
                    validation_start=validation_start,
                    validation_end=validation_end,
                    points=tuple(points),
                )
            )
            origin += timedelta(days=settings.step_days)
        return BacktestReport(folds=tuple(folds), provenance=dataset.provenance)

    @staticmethod
    def _history_through(
        dataset: HistoricalDemandDataset, training_end: date
    ) -> HistoricalDemandDataset:
        observations = tuple(
            value
            for value in dataset.observations
            if value.business_date <= training_end
        )
        availability = tuple(
            value
            for value in dataset.availability_evidence
            if value.business_date <= training_end
        )
        constructor = (
            HistoricalDemandDataset.from_real_observations
            if dataset.provenance is DataProvenance.REAL
            else HistoricalDemandDataset.from_synthetic_observations
        )
        return constructor(
            product=dataset.product,
            history_start=dataset.history_start,
            history_end=training_end,
            observations=observations,
            availability_evidence=availability,
        )


def mean_absolute_error(
    actual: list[Decimal], predicted: list[Decimal]
) -> Decimal:
    if not actual or len(actual) != len(predicted):
        raise ValueError("metric inputs must be nonempty and aligned")
    return sum(
        (abs(observed - estimate) for observed, estimate in zip(actual, predicted)),
        Decimal("0"),
    ) / Decimal(len(actual))
