from __future__ import annotations

import math
from dataclasses import replace
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Iterable

from app.data.validation import DemandDataError
from app.seasonality import (
    PhilippineSeasonResolver,
    ProductSeasonalProfile,
    ProductSeasonalProfileRegistry,
)

from .lightgbm_model import LightGBMConfig
from .mean28 import Mean28Forecaster
from .models import (
    DemandForecast,
    ForecastMetadata,
    HistoricalDemandDataset,
    ModelComponent,
)
from .series import PreparedSeries, prepare_history


class SeasonAwareLightGBMForecaster:
    """Experimental LightGBM candidate with future-known season context.

    This model has no fixed rainy/dry demand multiplier. Product profiles only
    expose auditable relevance classes and interactions; LightGBM must learn any
    numerical relationship from the training history supplied at that origin.
    The normal FastAPI service deliberately does not select this candidate.
    """

    MODEL_NAME = "seasonal_lightgbm_experimental"
    MODEL_VERSION = "1"
    LOOKBACK_DAYS = 28

    def __init__(
        self,
        *,
        config: LightGBMConfig | None = None,
        mean28: Mean28Forecaster | None = None,
        resolver: PhilippineSeasonResolver | None = None,
        registry: ProductSeasonalProfileRegistry | None = None,
    ) -> None:
        self.config = config or LightGBMConfig()
        self.mean28 = mean28 or Mean28Forecaster()
        self.resolver = resolver or PhilippineSeasonResolver()
        self.registry = registry or ProductSeasonalProfileRegistry.load_default()

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        if isinstance(horizon_days, bool) or not isinstance(horizon_days, int):
            raise DemandDataError("horizon_days must be an integer")
        if horizon_days <= 0:
            raise DemandDataError("horizon_days must be greater than zero")

        try:
            profile = self.registry.require(dataset.product)
            self.resolver.location_profile(dataset.product.location_id)
        except ValueError as error:
            return self._fallback(
                dataset,
                horizon_days,
                "seasonal_context_or_profile_unavailable",
                profile=None,
                detail=str(error),
            )

        prepared = prepare_history(dataset)
        if len(prepared.days) < self.config.min_history_days:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_training_history",
                profile=profile,
            )

        features, targets = self._training_matrix(
            prepared, dataset.product.location_id, profile
        )
        if len(targets) < self.config.min_training_rows:
            return self._fallback(
                dataset,
                horizon_days,
                "insufficient_uncensored_training_rows",
                profile=profile,
            )

        try:
            model = self._new_regressor()
            model.fit(features, targets)
            values = [float(day.model_value) for day in prepared.days]
            predictions: list[Decimal] = []
            clipped = False
            for offset in range(1, horizon_days + 1):
                forecast_date = dataset.history_end + timedelta(days=offset)
                row = self._feature_row(
                    values,
                    len(values),
                    forecast_date,
                    dataset.product.location_id,
                    profile,
                )
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
                dataset,
                horizon_days,
                "lightgbm_unavailable",
                profile=profile,
            )
        except Exception:
            return self._fallback(
                dataset,
                horizon_days,
                "lightgbm_training_or_validation_failed",
                profile=profile,
            )

        warnings = prepared.data_quality.warnings + self._seasonal_warnings(profile)
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
        self,
        prepared: PreparedSeries,
        location_id: str,
        profile: ProductSeasonalProfile,
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
                    values,
                    index,
                    day.business_date,
                    location_id,
                    profile,
                )
            )
            targets.append(float(day.sales_quantity))
        return features, targets

    def _feature_row(
        self,
        values: list[float],
        index: int,
        target_date: date,
        location_id: str,
        profile: ProductSeasonalProfile,
    ) -> list[float]:
        if index < self.LOOKBACK_DAYS:
            raise DemandDataError("seasonal LightGBM features require 28 prior days")
        prior7 = values[index - 7 : index]
        prior28 = values[index - 28 : index]
        weekday_angle = 2.0 * math.pi * target_date.weekday() / 7.0
        year_angle = 2.0 * math.pi * target_date.timetuple().tm_yday / 365.25
        context = self.resolver.resolve(location_id, target_date)
        seasonal_features = profile.feature_vector(context.feature_vector())
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
            *seasonal_features,
        ]

    def _seasonal_warnings(
        self, profile: ProductSeasonalProfile
    ) -> tuple[str, ...]:
        return (
            "experimental_candidate_not_active_for_normal_replenishment",
            "pagasa_climatology_calendar_not_a_weather_forecast",
            f"season_calendar:{self.resolver.CALENDAR_VERSION}",
            f"seasonal_profile_registry:{self.registry.REGISTRY_VERSION}",
            f"seasonal_profile_evidence:{profile.evidence_level.value}",
            "seasonal_profile_contains_no_numeric_multiplier",
            "synthetic_backtest_does_not_validate_real_hardware_seasonality",
        )

    def _fallback(
        self,
        dataset: HistoricalDemandDataset,
        horizon_days: int,
        reason: str,
        *,
        profile: ProductSeasonalProfile | None,
        detail: str | None = None,
    ) -> list[DemandForecast]:
        baseline = self.mean28.forecast(dataset, horizon_days=horizon_days)
        warnings = (
            f"mean28_fallback:{reason}",
            "experimental_candidate_not_active_for_normal_replenishment",
        )
        if profile is not None:
            warnings += self._seasonal_warnings(profile)[1:]
        if detail:
            warnings += (f"seasonal_context_detail:{detail}",)
        result: list[DemandForecast] = []
        for value in baseline:
            quality = replace(
                value.metadata.data_quality,
                warnings=value.metadata.data_quality.warnings + warnings,
            )
            metadata = replace(
                value.metadata,
                model_name="mean28_fallback",
                fallback_reason=reason,
                data_quality=quality,
            )
            result.append(replace(value, metadata=metadata))
        return result
