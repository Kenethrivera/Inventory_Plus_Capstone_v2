from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta
from decimal import Decimal

from app.forecasting import (
    SharedProductContextRegistry,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver

from .full_inventory_fixture import (
    HISTORY_END,
    HISTORY_START,
    PRODUCTS,
    bounded_dataset,
    full_inventory_datasets,
    simulated_quantity,
)
from .seasonal_backtest import (
    FullInventorySeasonalBacktester,
    SeasonalBacktestConfig,
    _Point,
)


class SharedSeasonalBacktester:
    """Fair six-model comparison on one set of chronological origins."""

    SHARED_NAME = "shared_seasonal_lightgbm"
    ABLATION_NAME = "shared_nonseasonal_ablation"

    def __init__(self, config: SeasonalBacktestConfig | None = None) -> None:
        self.config = config or SeasonalBacktestConfig(n_estimators=30)
        self.baselines = FullInventorySeasonalBacktester(self.config)
        self.resolver = PhilippineSeasonResolver()
        self.registry = SharedProductContextRegistry.from_catalog(PRODUCTS)
        shared_config = SharedSeasonalLightGBMConfig(
            n_estimators=80,
            learning_rate=0.04,
            num_leaves=20,
            max_depth=6,
            min_child_samples=30,
            reg_alpha=0.1,
            reg_lambda=0.7,
            feature_fraction=0.85,
            bagging_fraction=0.85,
            random_seed=self.config.random_seed,
        )
        self.shared = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=True,
            config=shared_config,
            resolver=self.resolver,
        )
        self.ablation = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=False,
            config=shared_config,
            resolver=self.resolver,
        )

    def run(self) -> dict[str, object]:
        datasets = full_inventory_datasets()
        policies = {value.product_id: value for value in PRODUCTS}
        origins = self.baselines._origins()
        points: list[_Point] = []
        actual_models: dict[str, Counter[str]] = defaultdict(Counter)

        for origin in origins:
            training = tuple(
                bounded_dataset(
                    dataset,
                    origin,
                    max_history_days=self.config.max_history_days,
                )
                for dataset in datasets
            )
            for dataset in training:
                if any(value.business_date > origin for value in dataset.observations):
                    raise AssertionError("future observation leaked into training")
                policy = policies[dataset.product.product_id]
                for requested_name, model in self.baselines.models:
                    forecasts = model.forecast(
                        dataset, horizon_days=self.config.horizon_days
                    )
                    actual_models[requested_name][
                        forecasts[0].metadata.model_name
                    ] += 1
                    points.extend(
                        self._points_for_forecasts(
                            forecasts,
                            policy=policy,
                            requested_name=requested_name,
                            origin=origin,
                        )
                    )

            for requested_name, model in (
                (self.SHARED_NAME, self.shared),
                (self.ABLATION_NAME, self.ablation),
            ):
                forecasts = model.forecast_many(
                    training, horizon_days=self.config.horizon_days
                )
                by_product: dict[str, list] = defaultdict(list)
                for forecast in forecasts:
                    by_product[forecast.product_id].append(forecast)
                for product_id, product_forecasts in by_product.items():
                    actual_models[requested_name][
                        product_forecasts[0].metadata.model_name
                    ] += 1
                    points.extend(
                        self._points_for_forecasts(
                            product_forecasts,
                            policy=policies[product_id],
                            requested_name=requested_name,
                            origin=origin,
                        )
                    )

        metrics = FullInventorySeasonalBacktester
        overall = metrics._metrics_by(points, lambda value: value.requested_model)
        by_product = metrics._nested_metrics(
            points, lambda value: value.requested_model, lambda value: value.sku
        )
        by_unit = metrics._nested_metrics(
            points, lambda value: value.requested_model, lambda value: value.unit
        )
        by_season = metrics._nested_metrics(
            points, lambda value: value.requested_model, lambda value: value.season
        )
        by_pattern = metrics._nested_metrics(
            points,
            lambda value: value.requested_model,
            lambda value: value.demand_pattern,
        )
        transition_points = [value for value in points if value.transition != "none"]
        by_transition = metrics._nested_metrics(
            transition_points,
            lambda value: value.requested_model,
            lambda value: value.transition,
        )
        macro_product_wape = self._macro_product_wape(by_product)
        comparison = self._comparison(by_product, overall, by_transition)
        future = self._future_forecasts(datasets, by_product)
        examples = self._transition_examples(points, policies)
        recommendation = self._recommendation(comparison, by_pattern)

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
                "shared_product_context_version": self.registry.version,
                "leakage_controls": [
                    "all six models use identical origins and 28-day horizons",
                    "each training dataset ends at its origin and is capped at 365 calendar days",
                    "lag, rolling, trend, and stockout features use only dates before each target",
                    "future dates contribute only deterministic calendar context before scoring",
                    "future simulated demand is read only after every forecast is generated",
                    "Gemini is not called for training rows; one versioned catalog context is reused",
                    "demand_pattern is evaluation metadata and is never a model feature",
                ],
            },
            "models": [
                "mean28",
                "lightgbm",
                "calibrated_blend",
                "seasonal_lightgbm",
                self.SHARED_NAME,
                self.ABLATION_NAME,
            ],
            "actual_model_counts": {
                model: dict(sorted(counts.items()))
                for model, counts in sorted(actual_models.items())
            },
            "overall_mixed_unit_diagnostic": overall,
            "macro_product_wape": macro_product_wape,
            "by_product": by_product,
            "by_compatible_unit": by_unit,
            "by_season": by_season,
            "by_demand_pattern": by_pattern,
            "seasonal_transitions": by_transition,
            "seasonal_ablation_and_baseline_comparison": comparison,
            "transition_anticipation_examples": examples,
            "next_28_day_forecasts": future,
            "recommendation": recommendation,
            "limitations": [
                "Synthetic month effects are programmed test assumptions, not verified Philippine hardware demand effects.",
                "The model uses climatological calendar context, not archived as-of weather forecasts or realized future rainfall.",
                "Mixed-unit overall totals are diagnostic only; model selection emphasizes per-product and compatible-unit metrics.",
                "The classification registry contains qualitative evidence classes and no demand multiplier.",
                "One 676-day simulation is insufficient to authorize production activation.",
            ],
        }

    def _points_for_forecasts(
        self,
        forecasts: list,
        *,
        policy,
        requested_name: str,
        origin: date,
    ) -> list[_Point]:
        result: list[_Point] = []
        for value in forecasts:
            if value.forecast_date <= origin:
                raise AssertionError("forecast date is not after its origin")
            if value.forecast_date > HISTORY_END:
                raise AssertionError("forecast exceeds fixture history")
            season = self.resolver.resolve(value.location_id, value.forecast_date)
            result.append(
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
                    season=season.season.value,
                    transition=season.transition.value,
                    actual=simulated_quantity(policy, value.forecast_date),
                    predicted=value.quantity,
                )
            )
        return result

    @staticmethod
    def _macro_product_wape(by_product: dict[str, object]) -> dict[str, object]:
        result: dict[str, object] = {}
        for model, rows in by_product.items():
            comparable = [
                values["wape"]
                for values in rows.values()  # type: ignore[union-attr]
                if values["wape"] is not None
            ]
            result[model] = {
                "comparable_products": len(comparable),
                "macro_wape": (
                    sum(comparable, Decimal("0")) / Decimal(len(comparable))
                    if comparable
                    else None
                ),
            }
        return result

    def _comparison(
        self,
        by_product: dict[str, object],
        overall: dict[str, object],
        transitions: dict[str, object],
    ) -> dict[str, object]:
        shared_products = by_product[self.SHARED_NAME]
        comparisons: dict[str, object] = {}
        for baseline in (
            "mean28",
            "lightgbm",
            "calibrated_blend",
            "seasonal_lightgbm",
            self.ABLATION_NAME,
        ):
            better = 0
            worse = 0
            tied = 0
            product_rows: dict[str, object] = {}
            for sku, shared_metrics in shared_products.items():  # type: ignore[union-attr]
                baseline_metrics = by_product[baseline][sku]  # type: ignore[index]
                shared_wape = shared_metrics["wape"]
                baseline_wape = baseline_metrics["wape"]
                if shared_wape is None or baseline_wape is None:
                    outcome = "not_comparable_zero_actual"
                    delta = None
                else:
                    delta = shared_wape - baseline_wape
                    if delta < 0:
                        outcome = "better"
                        better += 1
                    elif delta > 0:
                        outcome = "worse"
                        worse += 1
                    else:
                        outcome = "tied"
                        tied += 1
                product_rows[sku] = {
                    "outcome": outcome,
                    "shared_minus_baseline_wape": delta,
                }
            comparisons[baseline] = {
                "better_products": better,
                "worse_products": worse,
                "tied_products": tied,
                "products": product_rows,
            }

        shared_overall = overall[self.SHARED_NAME]["wape"]
        ablation_overall = overall[self.ABLATION_NAME]["wape"]
        transition_delta: dict[str, object] = {}
        for transition in ("to_rainy", "to_dry"):
            shared_value = transitions[self.SHARED_NAME][transition]["wape"]
            ablation_value = transitions[self.ABLATION_NAME][transition]["wape"]
            transition_delta[transition] = {
                "shared_wape": shared_value,
                "ablation_wape": ablation_value,
                "shared_minus_ablation_wape": shared_value - ablation_value,
            }
        return {
            "overall_shared_minus_ablation_wape": (
                shared_overall - ablation_overall
            ),
            "transition_shared_vs_ablation": transition_delta,
            "by_baseline": comparisons,
        }

    def _future_forecasts(
        self,
        datasets: tuple,
        by_product: dict[str, object],
    ) -> dict[str, object]:
        training = tuple(
            bounded_dataset(value, HISTORY_END, max_history_days=365)
            for value in datasets
        )
        seasonal = self.shared.forecast_many(training, horizon_days=28)
        ablation = self.ablation.forecast_many(training, horizon_days=28)
        seasonal_by_sku: dict[str, list] = defaultdict(list)
        ablation_by_sku: dict[str, list] = defaultdict(list)
        for value in seasonal:
            seasonal_by_sku[value.sku].append(value)
        for value in ablation:
            ablation_by_sku[value.sku].append(value)

        result: dict[str, object] = {}
        for policy in PRODUCTS:
            values = sorted(
                seasonal_by_sku[policy.sku], key=lambda value: value.forecast_date
            )
            without_season = sorted(
                ablation_by_sku[policy.sku], key=lambda value: value.forecast_date
            )
            total7 = sum((value.quantity for value in values[:7]), Decimal("0"))
            total28 = sum((value.quantity for value in values), Decimal("0"))
            ablation28 = sum(
                (value.quantity for value in without_season), Decimal("0")
            )
            shared_wape = by_product[self.SHARED_NAME][policy.sku]["wape"]  # type: ignore[index]
            ablation_wape = by_product[self.ABLATION_NAME][policy.sku]["wape"]  # type: ignore[index]
            wape_gain = (
                ablation_wape - shared_wape
                if shared_wape is not None and ablation_wape is not None
                else None
            )
            total_difference = total28 - ablation28
            relative_difference = (
                abs(total_difference) / ablation28
                if ablation28 > 0
                else None
            )
            materially_influenced = (
                shared_wape is not None
                and ablation_wape is not None
                and wape_gain is not None
                and wape_gain >= Decimal("0.005")
                and relative_difference is not None
                and relative_difference >= Decimal("0.05")
            )
            contexts = [
                self.resolver.resolve(value.location_id, value.forecast_date)
                for value in values
            ]
            changes: list[dict[str, str]] = []
            previous = self.resolver.resolve(
                values[0].location_id, HISTORY_END
            )
            for context in contexts:
                if (
                    context.season != previous.season
                    or context.transition != previous.transition
                ):
                    changes.append(
                        {
                            "date": context.forecast_date.isoformat(),
                            "season": context.season.value,
                            "transition": context.transition.value,
                        }
                    )
                previous = context
            product_context = self.registry.require(policy.product_id)
            result[policy.sku] = {
                "product_name": policy.product_name,
                "unit": policy.unit,
                "total_next_7_days": total7,
                "total_next_28_days": total28,
                "nonseasonal_ablation_28_day_total": ablation28,
                "seasonal_minus_ablation_28_day_total": total_difference,
                "seasonal_vs_ablation_relative_difference": relative_difference,
                "product_backtest_wape_gain_vs_ablation": wape_gain,
                "upcoming_seasonal_transitions": changes,
                "seasonal_evidence_status": {
                    "relevance": product_context.seasonal_relevance,
                    "match_type": product_context.seasonal_match_type,
                    "evidence_level": product_context.evidence_level,
                    "context_registry_version": self.registry.version,
                },
                "seasonal_features_materially_influenced": materially_influenced,
                "influence_basis": (
                    "Supported: product backtest WAPE improved by at least 0.5 percentage point and the 28-day total differs from ablation by at least 5%. These thresholds only label materiality; they do not change forecasts."
                    if materially_influenced
                    else "Not claimed: the ablation comparison did not meet both reporting thresholds (0.5 percentage-point WAPE gain and 5% 28-day total difference)."
                ),
                "daily": [
                    {
                        "date": value.forecast_date.isoformat(),
                        "quantity": value.quantity,
                        "season": context.season.value,
                        "transition": context.transition.value,
                    }
                    for value, context in zip(values, contexts, strict=True)
                ],
            }
        return result

    def _transition_examples(
        self, points: list[_Point], policies: dict[str, object]
    ) -> list[dict[str, object]]:
        cases = (
            (date(2025, 5, 15), "SKU-1006", date(2025, 6, 1), date(2025, 6, 7)),
            (date(2025, 10, 15), "SKU-002", date(2025, 11, 1), date(2025, 11, 7)),
            (date(2025, 10, 15), "SKU-1010", date(2025, 11, 1), date(2025, 11, 7)),
            (date(2026, 10, 10), "SKU-K1CB7XQV", date(2026, 11, 1), date(2026, 11, 7)),
        )
        result: list[dict[str, object]] = []
        policy_by_sku = {value.sku: value for value in policies.values()}
        for origin, sku, start, end in cases:
            policy = policy_by_sku[sku]
            relevant = [
                point
                for point in points
                if point.origin == origin
                and point.sku == sku
                and start <= point.forecast_date <= end
            ]
            by_model: dict[str, Decimal] = defaultdict(lambda: Decimal("0"))
            for point in relevant:
                by_model[point.requested_model] += point.predicted
            actual = sum(
                (
                    simulated_quantity(
                        policy, start + timedelta(days=offset)
                    )
                    for offset in range((end - start).days + 1)
                ),
                Decimal("0"),
            )
            recent28 = sum(
                (
                    simulated_quantity(
                        policy, origin - timedelta(days=offset)
                    )
                    for offset in range(27, -1, -1)
                ),
                Decimal("0"),
            )
            result.append(
                {
                    "origin": origin.isoformat(),
                    "product": policy.product_name,
                    "sku": sku,
                    "unit": policy.unit,
                    "target_period": [start.isoformat(), end.isoformat()],
                    "recent_28_day_actual_before_origin": recent28,
                    "target_actual": actual,
                    "predicted_totals": dict(sorted(by_model.items())),
                    "seasonal_minus_ablation": (
                        by_model[self.SHARED_NAME] - by_model[self.ABLATION_NAME]
                    ),
                }
            )
        return result

    def _recommendation(
        self,
        comparison: dict[str, object],
        by_pattern: dict[str, object],
    ) -> dict[str, object]:
        ablation_delta = comparison["overall_shared_minus_ablation_wape"]
        transitions = comparison["transition_shared_vs_ablation"]
        existing = comparison["by_baseline"]["lightgbm"]
        seasonal_value = ablation_delta < 0
        transitions_maintained = all(
            value["shared_minus_ablation_wape"] <= 0
            for value in transitions.values()
        )
        overall_maintained = (
            existing["better_products"] >= existing["worse_products"]
        )
        no_sales_false_positive_free = (
            by_pattern[self.SHARED_NAME]["no_sales"]["predicted_total"] == 0
        )
        if (
            seasonal_value
            and transitions_maintained
            and overall_maintained
            and no_sales_false_positive_free
        ):
            decision = "ACCEPT"
        elif seasonal_value:
            decision = "REVISE"
        else:
            decision = "REJECT"
        return {
            "decision": decision,
            "seasonal_ablation_improved_overall": seasonal_value,
            "seasonal_ablation_improved_or_tied_both_transitions": (
                transitions_maintained
            ),
            "product_regression_balance_vs_existing_lightgbm_acceptable": (
                overall_maintained
            ),
            "no_sales_false_positive_free": no_sales_false_positive_free,
            "activation_allowed": False,
            "rationale": (
                "This decision applies only to the experimental candidate. Normal API and replenishment activation remain prohibited."
            ),
        }
