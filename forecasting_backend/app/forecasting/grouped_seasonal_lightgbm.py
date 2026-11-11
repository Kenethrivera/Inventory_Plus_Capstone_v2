from __future__ import annotations

from collections import defaultdict
from dataclasses import replace
from typing import Iterable

from app.data.validation import DemandDataError
from app.seasonality import PhilippineSeasonResolver

from .mean28 import Mean28Forecaster
from .models import DemandForecast, HistoricalDemandDataset, ModelComponent
from .shared_seasonal_lightgbm import (
    SharedProductContextRegistry,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
)


class RelatedActivitySeasonalLightGBMForecaster:
    """Experimental controlled pooling by independently known activity group.

    This wrapper deliberately uses the same pooled estimator and features as the
    unrestricted candidate.  Only the training population changes, which makes
    it a clean test of whether unrelated-product transfer caused regressions.
    """

    MODEL_VERSION = "1"

    def __init__(
        self,
        *,
        registry: SharedProductContextRegistry,
        include_seasonal_features: bool = True,
        config: SharedSeasonalLightGBMConfig | None = None,
        mean28: Mean28Forecaster | None = None,
        resolver: PhilippineSeasonResolver | None = None,
    ) -> None:
        self.registry = registry
        self.include_seasonal_features = include_seasonal_features
        self.config = config or SharedSeasonalLightGBMConfig()
        self.mean28 = mean28 or Mean28Forecaster()
        self.resolver = resolver or PhilippineSeasonResolver()

    @property
    def model_name(self) -> str:
        return (
            "related_activity_seasonal_lightgbm_experimental"
            if self.include_seasonal_features
            else "related_activity_nonseasonal_ablation_experimental"
        )

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        raise DemandDataError(
            "the related-activity candidate requires forecast_many with the full catalog"
        )

    def forecast_many(
        self,
        datasets: Iterable[HistoricalDemandDataset],
        *,
        horizon_days: int,
    ) -> list[DemandForecast]:
        ordered = tuple(sorted(datasets, key=lambda value: value.product.series_key))
        if not ordered:
            return []
        self.registry.validate_datasets(ordered)

        by_group: dict[str, list[HistoricalDemandDataset]] = defaultdict(list)
        for dataset in ordered:
            context = self.registry.require(dataset.product.product_id)
            by_group[context.industry_activity_group].append(dataset)

        forecasts: list[DemandForecast] = []
        for group, group_datasets in sorted(by_group.items()):
            group_registry = self.registry.subset(
                (value.product.product_id for value in group_datasets),
                version_suffix=f"related-activity:{group}",
            )
            model = SharedSeasonalLightGBMForecaster(
                registry=group_registry,
                include_seasonal_features=self.include_seasonal_features,
                config=self.config,
                mean28=self.mean28,
                resolver=self.resolver,
            )
            for forecast in model.forecast_many(
                tuple(group_datasets), horizon_days=horizon_days
            ):
                warnings = forecast.metadata.data_quality.warnings + (
                    f"controlled_pool:industry_activity_group:{group}",
                )
                if forecast.metadata.model_name == model.model_name:
                    component = ModelComponent(
                        model_name=self.model_name,
                        model_version=self.MODEL_VERSION,
                        weight=forecast.metadata.components[0].weight,
                    )
                    metadata = replace(
                        forecast.metadata,
                        model_name=self.model_name,
                        model_version=self.MODEL_VERSION,
                        data_quality=replace(
                            forecast.metadata.data_quality,
                            warnings=warnings,
                        ),
                        components=(component,),
                    )
                else:
                    metadata = replace(
                        forecast.metadata,
                        data_quality=replace(
                            forecast.metadata.data_quality,
                            warnings=warnings,
                        ),
                    )
                forecasts.append(replace(forecast, metadata=metadata))
        return sorted(
            forecasts,
            key=lambda value: (value.product_id, value.forecast_date),
        )
