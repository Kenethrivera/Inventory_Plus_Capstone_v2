from __future__ import annotations

import math
from dataclasses import replace
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Iterable

from app.data.validation import DemandDataError
from app.seasonality import PhilippineSeasonResolver

from .lightgbm_model import LightGBMConfig, LightGBMForecaster
from .mean28 import Mean28Forecaster
from .models import (
    DemandForecast,
    ForecastMetadata,
    HistoricalDemandDataset,
    ModelComponent,
)
from .series import PreparedSeries, prepare_history
from .shared_seasonal_lightgbm import (
    SharedProductContext,
    SharedProductContextRegistry,
)


class ProductSpecificSeasonalLightGBMForecaster:
    """Experimental one-model-per-product candidate with future-known context.

    The nonseasonal ablation delegates its feature construction to the existing
    production LightGBM implementation.  Seasonal knowledge supplies only
    categorical/calendar context; all numerical effects must be learned from
    that product's own historical targets.
    """

    MODEL_VERSION = "1"
    LOOKBACK_DAYS = LightGBMForecaster.LOOKBACK_DAYS

    def __init__(
        self,
        *,
        registry: SharedProductContextRegistry,
        include_seasonal_features: bool = True,
        config: LightGBMConfig | None = None,
        mean28: Mean28Forecaster | None = None,
        resolver: PhilippineSeasonResolver | None = None,
        zero_never_sold_forecasts: bool = True,
    ) -> None:
        self.registry = registry
        self.include_seasonal_features = include_seasonal_features
        self.config = config or LightGBMConfig()
        self.mean28 = mean28 or Mean28Forecaster()
        self.resolver = resolver or PhilippineSeasonResolver()
        self.zero_never_sold_forecasts = zero_never_sold_forecasts

    @property
    def model_name(self) -> str:
        return (
            "product_specific_seasonal_lightgbm_experimental"
            if self.include_seasonal_features
            else "product_specific_nonseasonal_ablation_experimental"
        )

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        if isinstance(horizon_days, bool) or not isinstance(horizon_days, int):
            raise DemandDataError("horizon_days must be an integer")
        if horizon_days <= 0:
            raise DemandDataError("horizon_days must be greater than zero")

        try:
            context = self.registry.require(dataset.product.product_id)
            self.resolver.location_profile(dataset.product.location_id)
        except ValueError as error:
            return self._fallback(
                dataset,
                horizon_days,
                "seasonal_context_or_product_context_unavailable",
                detail=str(error),
            )

        prepared = prepare_history(dataset)
        if len(prepared.days) < self.config.min_history_days:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_training_history",
            )

        features, targets = self._training_matrix(
            prepared,
            location_id=dataset.product.location_id,
            context=context,
        )
        if len(targets) < self.config.min_training_rows:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_uncensored_training_rows",
            )

        never_sold = not any(day.sales_quantity > 0 for day in prepared.days)
        try:
            model = self._new_regressor()
            model.fit(features, targets)
            values = [float(day.model_value) for day in prepared.days]
            predictions: list[Decimal] = []
            clipped = False
            for offset in range(1, horizon_days + 1):
                forecast_date = dataset.history_end + timedelta(days=offset)
                row = self._feature_row(
                    values=values,
                    index=len(values),
                    target_date=forecast_date,
                    location_id=dataset.product.location_id,
                    context=context,
                )
                raw = float(model.predict([row])[0])
                if not math.isfinite(raw):
                    raise ArithmeticError("LightGBM produced a non-finite value")
                if raw < 0:
                    clipped = True
                numeric = max(0.0, raw)
                if self.zero_never_sold_forecasts and never_sold:
                    numeric = 0.0
                values.append(numeric)
                predictions.append(Decimal(format(numeric, ".12g")))
        except ImportError:
            return self._fallback(dataset, horizon_days, "lightgbm_unavailable")
        except Exception:
            return self._fallback(
                dataset,
                horizon_days,
                "lightgbm_training_or_validation_failed",
            )

        warnings = prepared.data_quality.warnings + (
            "experimental_product_specific_candidate_not_active",
            f"product_context:{self.registry.version}",
            f"season_calendar:{self.resolver.CALENDAR_VERSION}",
            f"seasonal_relevance:{context.seasonal_relevance}",
            f"seasonal_evidence:{context.evidence_level}",
            "seasonal_context_contains_no_numeric_multiplier",
            "synthetic_backtest_does_not_validate_real_hardware_seasonality",
        )
        if not self.include_seasonal_features:
            warnings += ("new_seasonal_features_removed_for_ablation",)
        if clipped:
            warnings += ("negative_model_predictions_clipped_to_zero",)
        if self.zero_never_sold_forecasts and never_sold:
            warnings += (
                "never_sold_zero_forecast_gate:known_history_contains_no_sales",
            )
        recent = [
            day
            for day in prepared.days[-self.LOOKBACK_DAYS :]
            if not day.is_stockout_censored
        ]
        metadata = ForecastMetadata(
            model_name=self.model_name,
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
            data_quality=replace(prepared.data_quality, warnings=warnings),
            components=(
                ModelComponent(
                    model_name=self.model_name,
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
        self,
        prepared: PreparedSeries,
        *,
        location_id: str,
        context: SharedProductContext,
    ) -> tuple[list[list[float]], list[float]]:
        values = [float(day.model_value) for day in prepared.days]
        features: list[list[float]] = []
        targets: list[float] = []
        for index in range(self.LOOKBACK_DAYS, len(prepared.days)):
            day = prepared.days[index]
            if day.is_stockout_censored:
                continue
            features.append(
                self._feature_row(
                    values=values,
                    index=index,
                    target_date=day.business_date,
                    location_id=location_id,
                    context=context,
                )
            )
            targets.append(float(day.sales_quantity))
        return features, targets

    def _feature_row(
        self,
        *,
        values: list[float],
        index: int,
        target_date: date,
        location_id: str,
        context: SharedProductContext,
    ) -> list[float]:
        base = LightGBMForecaster._feature_row(values, index, target_date)
        if not self.include_seasonal_features:
            return base
        season = self.resolver.resolve(location_id, target_date)
        relevance = context.seasonal_relevance.casefold()
        core_expected = float(
            (relevance == "summer" and season.season.value == "dry")
            or (relevance == "rainy" and season.season.value == "rainy")
        )
        transition_expected = float(
            (relevance == "summer" and season.transition.value == "to_dry")
            or (relevance == "rainy" and season.transition.value == "to_rainy")
        )
        opposite_core = float(
            (relevance == "summer" and season.season.value == "rainy")
            or (relevance == "rainy" and season.season.value == "dry")
        )
        return [
            *base,
            *season.feature_vector(),
            *_one_hot(target_date.month, tuple(range(1, 13))),
            float(_days_until_month_start(target_date, 5)),
            float(_days_until_month_start(target_date, 11)),
            float(_days_until_month_start(target_date, 5) <= 28),
            float(_days_until_month_start(target_date, 11) <= 28),
            core_expected,
            transition_expected,
            opposite_core,
            float(relevance == "neutral"),
        ]

    def _fallback(
        self,
        dataset: HistoricalDemandDataset,
        horizon_days: int,
        reason: str,
        *,
        detail: str | None = None,
    ) -> list[DemandForecast]:
        result: list[DemandForecast] = []
        for value in self.mean28.forecast(dataset, horizon_days=horizon_days):
            warnings = value.metadata.data_quality.warnings + (
                f"mean28_fallback:{reason}",
                "experimental_product_specific_candidate_not_active",
            )
            if detail:
                warnings += (f"seasonal_context_detail:{detail}",)
            result.append(
                replace(
                    value,
                    metadata=replace(
                        value.metadata,
                        model_name="mean28_fallback",
                        fallback_reason=reason,
                        data_quality=replace(
                            value.metadata.data_quality,
                            warnings=warnings,
                        ),
                    ),
                )
            )
        return result


def _one_hot(value: object, choices: tuple[object, ...]) -> list[float]:
    return [float(value == choice) for choice in choices]


def _days_until_month_start(target_date: date, month: int) -> int:
    candidate = date(target_date.year, month, 1)
    if candidate < target_date:
        candidate = date(target_date.year + 1, month, 1)
    return (candidate - target_date).days
