from __future__ import annotations

import math
from dataclasses import dataclass, replace
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Iterable, Protocol

from app.classification import HardwareProductClassifier
from app.data.validation import DemandDataError
from app.seasonality import (
    PhilippineSeasonResolver,
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


class SharedSeasonalCatalogProduct(Protocol):
    product_id: str
    sku: str
    product_name: str
    category: str
    unit: str

    @property
    def forecast_product(self): ...


@dataclass(frozen=True)
class SharedProductContext:
    product_id: str
    sku: str
    product_name: str
    category: str
    unit: str
    product_type: str
    intended_use_group: str
    industry_activity_group: str
    seasonal_relevance: str
    seasonal_match_type: str
    evidence_level: str
    classification_confidence: str


class SharedProductContextRegistry:
    """Versioned, reusable product context; no Gemini calls occur per row."""

    def __init__(
        self,
        *,
        contexts: tuple[SharedProductContext, ...],
        version: str,
    ) -> None:
        self.version = version
        self._by_product_id = {value.product_id: value for value in contexts}
        if len(self._by_product_id) != len(contexts):
            raise ValueError("shared product contexts contain a duplicate product_id")

        self.product_ids = tuple(sorted(value.product_id for value in contexts))
        self.categories = tuple(sorted({value.category for value in contexts}))
        self.units = tuple(sorted({value.unit for value in contexts}))
        self.product_types = tuple(sorted({value.product_type for value in contexts}))
        self.intended_use_groups = tuple(
            sorted({value.intended_use_group for value in contexts})
        )
        self.industry_activity_groups = tuple(
            sorted({value.industry_activity_group for value in contexts})
        )
        self.seasonal_relevances = tuple(
            sorted({value.seasonal_relevance for value in contexts})
        )
        self.evidence_levels = tuple(
            sorted({value.evidence_level for value in contexts})
        )

    @classmethod
    def from_catalog(
        cls,
        catalog: Iterable[SharedSeasonalCatalogProduct],
        *,
        classifier: HardwareProductClassifier | None = None,
        profile_registry: ProductSeasonalProfileRegistry | None = None,
    ) -> SharedProductContextRegistry:
        selected_classifier = classifier or HardwareProductClassifier.load_default(
            semantic_mode="disabled"
        )
        profiles = profile_registry or ProductSeasonalProfileRegistry.load_default()
        products = tuple(catalog)
        profiles.validate_catalog(
            tuple(value.forecast_product for value in products)
        )
        contexts: list[SharedProductContext] = []
        for product in products:
            classification = selected_classifier.classify(
                product_name=product.product_name,
                category=product.category,
            )
            profile = profiles.require(product.forecast_product)
            intended_group = profile.seasonal_relevance.value
            activity_group = _activity_group(intended_group)
            contexts.append(
                SharedProductContext(
                    product_id=product.product_id,
                    sku=product.sku,
                    product_name=product.product_name,
                    category=product.category.casefold(),
                    unit=product.unit.casefold(),
                    product_type=classification.identified_product_type,
                    intended_use_group=intended_group,
                    industry_activity_group=activity_group,
                    seasonal_relevance=classification.seasonal_relevance.value,
                    seasonal_match_type=classification.seasonal_match_type.value,
                    evidence_level=classification.seasonal_evidence_level.value,
                    classification_confidence=(
                        classification.identification_confidence.value
                    ),
                )
            )
        return cls(
            contexts=tuple(contexts),
            version=(
                "shared-product-context-v1+"
                f"{selected_classifier.version}+{profiles.REGISTRY_VERSION}"
            ),
        )

    @property
    def contexts(self) -> tuple[SharedProductContext, ...]:
        return tuple(
            sorted(self._by_product_id.values(), key=lambda value: value.sku)
        )

    def require(self, product_id: str) -> SharedProductContext:
        try:
            return self._by_product_id[product_id]
        except KeyError as error:
            raise ValueError(
                f"no shared product context exists for {product_id}"
            ) from error

    def subset(
        self,
        product_ids: Iterable[str],
        *,
        version_suffix: str,
    ) -> SharedProductContextRegistry:
        """Return a closed registry for a controlled product pool."""

        selected_ids = tuple(sorted(set(product_ids)))
        if not selected_ids:
            raise ValueError("a shared product context subset cannot be empty")
        contexts = tuple(self.require(product_id) for product_id in selected_ids)
        return SharedProductContextRegistry(
            contexts=contexts,
            version=f"{self.version}+{version_suffix}",
        )

    def validate_datasets(
        self, datasets: tuple[HistoricalDemandDataset, ...]
    ) -> None:
        supplied = {value.product.product_id for value in datasets}
        if supplied != set(self._by_product_id):
            raise ValueError(
                "shared model datasets and product context registry differ"
            )


def _activity_group(intended_use_group: str) -> str:
    return {
        "construction_activity": "outdoor_weather_exposed_construction",
        "plumbing_installation_and_repair": "mixed_plumbing_installation_repair",
        "mixed_project_activity": "mixed_indoor_outdoor_project_activity",
        "unclassified_test_item": "unclassified",
    }[intended_use_group]


@dataclass(frozen=True)
class SharedSeasonalLightGBMConfig:
    min_history_days: int = 84
    min_training_rows: int = 400
    n_estimators: int = 80
    learning_rate: float = 0.04
    num_leaves: int = 20
    max_depth: int = 6
    min_child_samples: int = 30
    reg_alpha: float = 0.1
    reg_lambda: float = 0.7
    feature_fraction: float = 0.85
    bagging_fraction: float = 0.85
    random_seed: int = 26061108
    zero_never_sold_forecasts: bool = True

    def __post_init__(self) -> None:
        if self.min_history_days < 28 or self.min_training_rows <= 0:
            raise ValueError("shared model history/training thresholds are invalid")
        if self.n_estimators <= 0 or not 0 < self.learning_rate <= 1:
            raise ValueError("shared model boosting configuration is invalid")
        if self.num_leaves < 2 or self.max_depth < 1:
            raise ValueError("shared model tree configuration is invalid")
        if self.min_child_samples <= 0 or self.reg_alpha < 0 or self.reg_lambda < 0:
            raise ValueError("shared model regularization is invalid")
        if not 0 < self.feature_fraction <= 1 or not 0 < self.bagging_fraction <= 1:
            raise ValueError("shared model sampling fractions are invalid")


class SharedSeasonalLightGBMForecaster:
    """Experimental pooled model across products, never selected by the API."""

    MODEL_VERSION = "1"
    LOOKBACK_DAYS = 28

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
            "shared_seasonal_lightgbm_experimental"
            if self.include_seasonal_features
            else "shared_lightgbm_nonseasonal_ablation_experimental"
        )

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[DemandForecast]:
        raise DemandDataError(
            "the shared pooled candidate requires forecast_many with the full catalog"
        )

    def forecast_many(
        self,
        datasets: Iterable[HistoricalDemandDataset],
        *,
        horizon_days: int,
    ) -> list[DemandForecast]:
        if isinstance(horizon_days, bool) or not isinstance(horizon_days, int):
            raise DemandDataError("horizon_days must be an integer")
        if horizon_days <= 0:
            raise DemandDataError("horizon_days must be greater than zero")
        ordered = tuple(sorted(datasets, key=lambda value: value.product.series_key))
        if not ordered:
            return []
        self.registry.validate_datasets(ordered)
        if len({value.provenance for value in ordered}) != 1:
            raise DemandDataError("a shared batch cannot mix data provenance")
        if len({value.history_end for value in ordered}) != 1:
            raise DemandDataError("shared batch histories must end at one origin")
        if len({value.product.location_id for value in ordered}) != 1:
            raise DemandDataError("shared batch must contain one store location")

        prepared = {value.product.product_id: prepare_history(value) for value in ordered}
        never_sold = {
            product_id
            for product_id, series in prepared.items()
            if series.days
            and not any(day.sales_quantity > 0 for day in series.days)
        }
        if any(
            len(value.days) < self.config.min_history_days
            for value in prepared.values()
        ):
            return self._fallback_many(
                ordered, horizon_days, "insufficient_training_history"
            )

        features, targets = self._training_matrix(ordered, prepared)
        if len(targets) < self.config.min_training_rows:
            return self._fallback_many(
                ordered, horizon_days, "insufficient_uncensored_training_rows"
            )

        try:
            model = self._new_regressor()
            model.fit(features, targets)
            histories = {
                product_id: [float(day.model_value) for day in series.days]
                for product_id, series in prepared.items()
            }
            predictions: dict[str, list[Decimal]] = {
                value.product.product_id: [] for value in ordered
            }
            clipped: set[str] = set()
            origin = ordered[0].history_end
            for offset in range(1, horizon_days + 1):
                target_date = origin + timedelta(days=offset)
                rows = [
                    self._feature_row(
                        values=histories[value.product.product_id],
                        index=len(histories[value.product.product_id]),
                        target_date=target_date,
                        location_id=value.product.location_id,
                        context=self.registry.require(value.product.product_id),
                    )
                    for value in ordered
                ]
                raw_values = model.predict(rows)
                for dataset, raw in zip(ordered, raw_values, strict=True):
                    numeric = float(raw)
                    if not math.isfinite(numeric):
                        raise ArithmeticError("shared LightGBM produced non-finite output")
                    product_id = dataset.product.product_id
                    if numeric < 0:
                        clipped.add(product_id)
                    numeric = max(0.0, numeric)
                    if (
                        self.config.zero_never_sold_forecasts
                        and product_id in never_sold
                    ):
                        numeric = 0.0
                    histories[product_id].append(numeric)
                    predictions[product_id].append(Decimal(format(numeric, ".12g")))
        except ImportError:
            return self._fallback_many(ordered, horizon_days, "lightgbm_unavailable")
        except Exception:
            return self._fallback_many(
                ordered, horizon_days, "lightgbm_training_or_validation_failed"
            )

        result: list[DemandForecast] = []
        for dataset in ordered:
            product = dataset.product
            series = prepared[product.product_id]
            context = self.registry.require(product.product_id)
            warnings = series.data_quality.warnings + (
                "experimental_shared_candidate_not_active_for_normal_application",
                "model_trained_across_current_catalog_products",
                f"shared_product_context:{self.registry.version}",
                f"season_calendar:{self.resolver.CALENDAR_VERSION}",
                f"seasonal_evidence:{context.evidence_level}",
                "no_fixed_seasonal_multiplier",
                "synthetic_backtest_does_not_validate_real_hardware_seasonality",
            )
            if not self.include_seasonal_features:
                warnings += ("seasonal_features_removed_for_ablation",)
            if product.product_id in clipped:
                warnings += ("negative_model_predictions_clipped_to_zero",)
            if (
                self.config.zero_never_sold_forecasts
                and product.product_id in never_sold
            ):
                warnings += (
                    "never_sold_zero_forecast_gate:known_history_contains_no_sales",
                )
            recent = [
                day
                for day in series.days[-self.LOOKBACK_DAYS :]
                if not day.is_stockout_censored
            ]
            metadata = ForecastMetadata(
                model_name=self.model_name,
                model_version=self.MODEL_VERSION,
                lookback_days=self.LOOKBACK_DAYS,
                history_days_available=len(series.days),
                sample_days_used=len(targets),
                nonzero_demand_days=sum(
                    1 for day in recent if day.sales_quantity > 0
                ),
                is_cold_start=False,
                cold_start_reason=None,
                cold_start_strategy=None,
                history_start=dataset.history_start,
                history_end=dataset.history_end,
                dataset_role=dataset.role,
                data_provenance=dataset.provenance,
                forecast_horizon_days=horizon_days,
                data_quality=replace(series.data_quality, warnings=warnings),
                components=(
                    ModelComponent(
                        model_name=self.model_name,
                        model_version=self.MODEL_VERSION,
                        weight=Decimal("1"),
                    ),
                ),
            )
            result.extend(
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
                for index, quantity in enumerate(predictions[product.product_id])
            )
        return result

    def _new_regressor(self) -> Any:
        from lightgbm import LGBMRegressor

        return LGBMRegressor(
            objective="regression_l1",
            n_estimators=self.config.n_estimators,
            learning_rate=self.config.learning_rate,
            num_leaves=self.config.num_leaves,
            max_depth=self.config.max_depth,
            min_child_samples=self.config.min_child_samples,
            reg_alpha=self.config.reg_alpha,
            reg_lambda=self.config.reg_lambda,
            colsample_bytree=self.config.feature_fraction,
            subsample=self.config.bagging_fraction,
            subsample_freq=1,
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
        datasets: tuple[HistoricalDemandDataset, ...],
        prepared: dict[str, PreparedSeries],
    ) -> tuple[list[list[float]], list[float]]:
        features: list[list[float]] = []
        targets: list[float] = []
        for dataset in datasets:
            series = prepared[dataset.product.product_id]
            values = [float(day.model_value) for day in series.days]
            context = self.registry.require(dataset.product.product_id)
            for index in range(self.LOOKBACK_DAYS, len(series.days)):
                day = series.days[index]
                if day.is_stockout_censored:
                    continue
                features.append(
                    self._feature_row(
                        values=values,
                        index=index,
                        target_date=day.business_date,
                        location_id=dataset.product.location_id,
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
        if index < self.LOOKBACK_DAYS:
            raise DemandDataError("shared model features require 28 prior days")
        prior7 = values[index - 7 : index]
        prior14 = values[index - 14 : index - 7]
        prior28 = values[index - 28 : index]
        lag_features = [
            values[index - 1],
            values[index - 7],
            values[index - 14],
            values[index - 28],
            sum(prior7) / 7.0,
            sum(prior28) / 28.0,
            (sum(prior7) / 7.0) - (sum(prior14) / 7.0),
            sum(1 for value in prior28 if value > 0) / 28.0,
            float(_days_since_nonzero(values, index)),
            float(index),
        ]
        weekday_angle = 2.0 * math.pi * target_date.weekday() / 7.0
        base = lag_features + [
            math.sin(weekday_angle),
            math.cos(weekday_angle),
            *_one_hot(context.product_id, self.registry.product_ids),
            *_one_hot(context.category, self.registry.categories),
            *_one_hot(context.unit, self.registry.units),
            *_one_hot(context.product_type, self.registry.product_types),
            *_one_hot(
                context.intended_use_group, self.registry.intended_use_groups
            ),
            *_one_hot(
                context.industry_activity_group,
                self.registry.industry_activity_groups,
            ),
            *_one_hot(
                context.evidence_level, self.registry.evidence_levels
            ),
        ]
        if not self.include_seasonal_features:
            return base

        season = self.resolver.resolve(location_id, target_date)
        season_features = list(season.feature_vector())
        month_features = _one_hot(target_date.month, tuple(range(1, 13)))
        year_angle = 2.0 * math.pi * target_date.timetuple().tm_yday / 365.25
        product_features = _one_hot(context.product_id, self.registry.product_ids)
        intended_features = _one_hot(
            context.intended_use_group, self.registry.intended_use_groups
        )
        relevance_features = _one_hot(
            context.seasonal_relevance, self.registry.seasonal_relevances
        )
        seasonal_context = [*season_features[:4], *month_features]
        return base + [
            math.sin(year_angle),
            math.cos(year_angle),
            *season_features,
            *month_features,
            *_cross(product_features, seasonal_context),
            *_cross(intended_features, season_features[:4]),
            *_cross(relevance_features, season_features[:4]),
        ]

    def _fallback_many(
        self,
        datasets: tuple[HistoricalDemandDataset, ...],
        horizon_days: int,
        reason: str,
    ) -> list[DemandForecast]:
        result: list[DemandForecast] = []
        for dataset in datasets:
            for value in self.mean28.forecast(dataset, horizon_days=horizon_days):
                quality = replace(
                    value.metadata.data_quality,
                    warnings=value.metadata.data_quality.warnings
                    + (
                        f"mean28_fallback:{reason}",
                        "experimental_shared_candidate_not_active_for_normal_application",
                    ),
                )
                result.append(
                    replace(
                        value,
                        metadata=replace(
                            value.metadata,
                            model_name="mean28_fallback",
                            fallback_reason=reason,
                            data_quality=quality,
                        ),
                    )
                )
        return result


def _one_hot(value: object, vocabulary: tuple[object, ...]) -> list[float]:
    return [float(value == candidate) for candidate in vocabulary]


def _cross(left: list[float], right: list[float]) -> list[float]:
    return [left_value * right_value for left_value in left for right_value in right]


def _days_since_nonzero(values: list[float], index: int) -> int:
    for offset in range(1, min(index, 365) + 1):
        if values[index - offset] > 0:
            return offset - 1
    return min(index, 365)
