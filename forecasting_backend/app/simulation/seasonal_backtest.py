from __future__ import annotations

from collections import Counter, defaultdict
from collections.abc import Callable
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from decimal import Decimal
from typing import Protocol

from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    DemandForecast,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    RollingOriginConfig,
    SeasonAwareLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver, ProductSeasonalProfileRegistry

from .full_inventory_fixture import (
    HISTORY_END,
    HISTORY_START,
    PRODUCTS,
    bounded_dataset,
    full_inventory_datasets,
    simulated_quantity,
)


class _Forecaster(Protocol):
    def forecast(
        self, dataset: object, *, horizon_days: int
    ) -> list[DemandForecast]: ...


@dataclass(frozen=True)
class SeasonalBacktestConfig:
    horizon_days: int = 28
    initial_training_days: int = 112
    origin_step_days: int = 28
    max_history_days: int = 365
    n_estimators: int = 30
    random_seed: int = 26061108


@dataclass(frozen=True)
class AccuracyMetrics:
    observations: int
    actual_total: Decimal
    predicted_total: Decimal
    wape: Decimal | None
    mae: Decimal
    signed_bias: Decimal | None


@dataclass(frozen=True)
class _Point:
    requested_model: str
    actual_model: str
    product_id: str
    sku: str
    product_name: str
    unit: str
    demand_pattern: str
    origin: date
    forecast_date: date
    season: str
    transition: str
    actual: Decimal
    predicted: Decimal


class FullInventorySeasonalBacktester:
    """Leakage-safe comparison on the exact deterministic SQL 02 demand plan."""

    def __init__(self, config: SeasonalBacktestConfig | None = None) -> None:
        self.config = config or SeasonalBacktestConfig()
        self.resolver = PhilippineSeasonResolver()
        self.registry = ProductSeasonalProfileRegistry.load_default()
        model_config = LightGBMConfig(
            min_history_days=84,
            min_training_rows=40,
            n_estimators=self.config.n_estimators,
            learning_rate=0.06,
            num_leaves=12,
            random_seed=self.config.random_seed,
        )
        mean = Mean28Forecaster()
        lightgbm = LightGBMForecaster(config=model_config, mean28=mean)
        blend = CalibratedBlendForecaster(
            config=CalibratedBlendConfig(
                minimum_calibration_points=28,
                rolling_origin=RollingOriginConfig(
                    initial_training_days=112,
                    horizon_days=self.config.horizon_days,
                    step_days=84,
                ),
            ),
            lightgbm=lightgbm,
            mean28=mean,
        )
        seasonal = SeasonAwareLightGBMForecaster(
            config=model_config,
            mean28=mean,
            resolver=self.resolver,
            registry=self.registry,
        )
        self.models: tuple[tuple[str, _Forecaster], ...] = (
            ("mean28", mean),
            ("lightgbm", lightgbm),
            ("calibrated_blend", blend),
            ("seasonal_lightgbm", seasonal),
        )

    def run(self) -> dict[str, object]:
        datasets = full_inventory_datasets()
        self.registry.validate_catalog(tuple(value.product for value in datasets))
        policies = {value.product_id: value for value in PRODUCTS}
        points: list[_Point] = []
        actual_models: dict[str, Counter[str]] = defaultdict(Counter)
        origins = self._origins()

        for dataset in datasets:
            policy = policies[dataset.product.product_id]
            for origin in origins:
                training = bounded_dataset(
                    dataset,
                    origin,
                    max_history_days=self.config.max_history_days,
                )
                if any(value.business_date > origin for value in training.observations):
                    raise AssertionError("future observation leaked into training")
                for requested_name, model in self.models:
                    forecasts = model.forecast(
                        training, horizon_days=self.config.horizon_days
                    )
                    actual_models[requested_name][forecasts[0].metadata.model_name] += 1
                    for value in forecasts:
                        if value.forecast_date <= origin:
                            raise AssertionError("forecast date is not after its origin")
                        if value.forecast_date > HISTORY_END:
                            raise AssertionError("forecast exceeds the fixture history")
                        context = self.resolver.resolve(
                            value.location_id, value.forecast_date
                        )
                        points.append(
                            _Point(
                                requested_model=requested_name,
                                actual_model=value.metadata.model_name,
                                product_id=value.product_id,
                                sku=value.sku or policy.sku,
                                product_name=value.product_name,
                                unit=value.unit,
                                demand_pattern=policy.demand_pattern,
                                origin=origin,
                                forecast_date=value.forecast_date,
                                season=context.season.value,
                                transition=context.transition.value,
                                actual=simulated_quantity(policy, value.forecast_date),
                                predicted=value.quantity,
                            )
                        )

        overall = self._metrics_by(points, lambda value: value.requested_model)
        by_product = self._nested_metrics(
            points, lambda value: value.requested_model, lambda value: value.sku
        )
        by_season = self._nested_metrics(
            points, lambda value: value.requested_model, lambda value: value.season
        )
        by_pattern = self._nested_metrics(
            points,
            lambda value: value.requested_model,
            lambda value: value.demand_pattern,
        )
        transition_points = [value for value in points if value.transition != "none"]
        by_transition = self._nested_metrics(
            transition_points,
            lambda value: value.requested_model,
            lambda value: value.transition,
        )
        comparisons = self._seasonal_comparisons(by_product)
        return {
            "evaluation_contract": {
                "dataset": "SQL 02 deterministic 676-day full-inventory fixture",
                "history_start": HISTORY_START.isoformat(),
                "history_end": HISTORY_END.isoformat(),
                "calendar_days": (HISTORY_END - HISTORY_START).days + 1,
                "products": len(PRODUCTS),
                "origins": [value.isoformat() for value in origins],
                "horizon_days": self.config.horizon_days,
                "maximum_training_calendar_days": self.config.max_history_days,
                "leakage_controls": [
                    "training observations are bounded at each origin",
                    "training is capped at the deployed latest-365-calendar-day window",
                    "every prediction date is strictly after its origin",
                    "the SQL demand_pattern is used only as an evaluation grouping label",
                    "future quantities are looked up only after forecasts are generated",
                    "season context is deterministic future-known climatology, not realized future weather",
                ],
            },
            "models": [value[0] for value in self.models],
            "actual_model_counts": {
                model: dict(sorted(counts.items()))
                for model, counts in sorted(actual_models.items())
            },
            "overall": overall,
            "by_product": by_product,
            "by_season": by_season,
            "by_demand_pattern": by_pattern,
            "seasonal_transitions": by_transition,
            "seasonal_vs_baselines_by_product": comparisons,
            "limitations": [
                "Programmed month effects are simulation assumptions, not verified Philippine hardware-market effects.",
                "The candidate uses climatological calendar context and no archived PAGASA forecast vintages or observed rainfall.",
                "All catalog profiles prohibit fixed numerical seasonal adjustments.",
                "Synthetic performance cannot authorize activation in normal replenishment.",
            ],
        }

    def _origins(self) -> tuple[date, ...]:
        first = HISTORY_START + timedelta(days=self.config.initial_training_days - 1)
        last = HISTORY_END - timedelta(days=self.config.horizon_days)
        values: set[date] = set()
        current = first
        while current <= last:
            values.add(current)
            current += timedelta(days=self.config.origin_step_days)
        transition_origins = (
            date(2025, 4, 30),
            date(2025, 5, 15),
            date(2025, 10, 15),
            date(2025, 10, 31),
            date(2025, 11, 15),
            date(2026, 4, 15),
            date(2026, 4, 30),
            date(2026, 5, 15),
            date(2026, 10, 10),
        )
        values.update(value for value in transition_origins if first <= value <= last)
        return tuple(sorted(values))

    @staticmethod
    def _metrics(points: list[_Point]) -> dict[str, object]:
        if not points:
            return asdict(
                AccuracyMetrics(
                    observations=0,
                    actual_total=Decimal("0"),
                    predicted_total=Decimal("0"),
                    wape=None,
                    mae=Decimal("0"),
                    signed_bias=None,
                )
            )
        actual_total = sum((value.actual for value in points), Decimal("0"))
        predicted_total = sum((value.predicted for value in points), Decimal("0"))
        absolute_error = sum(
            (abs(value.predicted - value.actual) for value in points), Decimal("0")
        )
        return asdict(
            AccuracyMetrics(
                observations=len(points),
                actual_total=actual_total,
                predicted_total=predicted_total,
                wape=(absolute_error / actual_total if actual_total > 0 else None),
                mae=absolute_error / Decimal(len(points)),
                signed_bias=(
                    (predicted_total - actual_total) / actual_total
                    if actual_total > 0
                    else None
                ),
            )
        )

    @classmethod
    def _metrics_by(
        cls, points: list[_Point], key: Callable[[_Point], str]
    ) -> dict[str, object]:
        grouped: dict[str, list[_Point]] = defaultdict(list)
        for point in points:
            grouped[key(point)].append(point)
        return {
            name: cls._metrics(values) for name, values in sorted(grouped.items())
        }

    @classmethod
    def _nested_metrics(
        cls,
        points: list[_Point],
        outer_key: Callable[[_Point], str],
        inner_key: Callable[[_Point], str],
    ) -> dict[str, object]:
        grouped: dict[str, dict[str, list[_Point]]] = defaultdict(
            lambda: defaultdict(list)
        )
        for point in points:
            grouped[outer_key(point)][inner_key(point)].append(point)
        return {
            outer: {
                inner: cls._metrics(values)
                for inner, values in sorted(inner_values.items())
            }
            for outer, inner_values in sorted(grouped.items())
        }

    @staticmethod
    def _seasonal_comparisons(by_product: dict[str, object]) -> dict[str, object]:
        seasonal = by_product["seasonal_lightgbm"]
        result: dict[str, object] = {}
        for baseline in ("mean28", "lightgbm", "calibrated_blend"):
            rows: dict[str, object] = {}
            better = 0
            worse = 0
            tied = 0
            for sku, seasonal_metrics in seasonal.items():  # type: ignore[union-attr]
                baseline_metrics = by_product[baseline][sku]  # type: ignore[index]
                seasonal_wape = seasonal_metrics["wape"]
                baseline_wape = baseline_metrics["wape"]
                if seasonal_wape is None or baseline_wape is None:
                    outcome = "not_comparable_zero_actual"
                    delta = None
                else:
                    delta = seasonal_wape - baseline_wape
                    if delta < 0:
                        better += 1
                        outcome = "better"
                    elif delta > 0:
                        worse += 1
                        outcome = "worse"
                    else:
                        tied += 1
                        outcome = "tied"
                rows[sku] = {
                    "outcome": outcome,
                    "seasonal_minus_baseline_wape": delta,
                }
            result[baseline] = {
                "better_products": better,
                "worse_products": worse,
                "tied_products": tied,
                "products": rows,
            }
        return result
