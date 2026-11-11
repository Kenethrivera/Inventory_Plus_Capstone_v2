from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta
from decimal import Decimal

from app.forecasting import (
    LightGBMConfig,
    LightGBMForecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver

from .expanded_seasonal_backtest import ExpandedSeasonalBacktester
from .expanded_seasonal_fixture import (
    HISTORY_END,
    HISTORY_START,
    MANIFEST_VERSION,
    PRODUCTS,
    TEST_END,
    TEST_START,
    VALIDATION_END,
    VALIDATION_START,
    assumptions_sha256,
    bounded_dataset,
    expanded_datasets,
    shared_context_registry,
    simulated_quantity,
)
from .seasonal_backtest import FullInventorySeasonalBacktester, _Point


HISTORY_WINDOWS = (365, 730, 1095)
HYPERPARAMETERS = {
    "production_parity": {
        "n_estimators": 80,
        "learning_rate": 0.05,
        "num_leaves": 15,
    },
    "conservative": {
        "n_estimators": 120,
        "learning_rate": 0.03,
        "num_leaves": 10,
    },
}


class ProductSpecificSeasonalBacktester:
    """Leakage-safe Stage 2.3 evaluator for one-model-per-product candidates."""

    def __init__(self) -> None:
        self.horizon_days = 28
        self.registry = shared_context_registry()
        self.resolver = PhilippineSeasonResolver()
        self._origin_helper = ExpandedSeasonalBacktester()

    def run(self) -> dict[str, object]:
        datasets = expanded_datasets()
        products = {value.product_id: value for value in PRODUCTS}
        validation: dict[str, object] = {}

        for window in HISTORY_WINDOWS:
            print(f"evaluating validation with {window}-day history", flush=True)
            models = self._validation_models()
            points, counts, observed_days = self._evaluate_split(
                datasets=datasets,
                products=products,
                split_start=VALIDATION_START,
                split_end=VALIDATION_END,
                max_history_days=window,
                models=models,
            )
            validation[str(window)] = self._metrics_report(
                points,
                model_counts=counts,
                origins=self._origins(VALIDATION_START, VALIDATION_END),
                observed_training_days=observed_days,
            )
            print(f"completed {window}-day validation", flush=True)

        selection = self._select_candidate(validation)
        selected_window = int(selection["history_window_days"])
        selected_hyperparameters = str(selection["hyperparameters"])
        selected_model = str(selection["model"])
        selected_ablation = str(selection["matched_ablation"])

        print(
            "validation selection frozen: "
            f"{selected_window} days, {selected_hyperparameters}",
            flush=True,
        )
        final_models = self._final_models(selected_hyperparameters)
        final_points, final_counts, final_observed_days = self._evaluate_split(
            datasets=datasets,
            products=products,
            split_start=TEST_START,
            split_end=TEST_END,
            max_history_days=selected_window,
            models=final_models,
        )
        final_report = self._metrics_report(
            final_points,
            model_counts=final_counts,
            origins=self._origins(TEST_START, TEST_END),
            observed_training_days=final_observed_days,
        )
        recommendation = self._recommendation(
            selection=selection,
            final_report=final_report,
        )
        product_level_comparison = self._product_level_comparison(
            final_report=final_report,
            seasonal_model=selected_model,
            ablation_model=selected_ablation,
        )
        return {
            "evaluation_contract": {
                "stage": "2.3",
                "manifest_version": MANIFEST_VERSION,
                "manifest_sha256": assumptions_sha256(),
                "history_start": HISTORY_START.isoformat(),
                "history_end": HISTORY_END.isoformat(),
                "population": {
                    "expanded_products_evaluated": len(PRODUCTS),
                    "original_products_evaluated": 0,
                    "group_counts": dict(
                        sorted(Counter(value.seasonal_group for value in PRODUCTS).items())
                    ),
                },
                "history_windows_days": list(HISTORY_WINDOWS),
                "hyperparameter_candidates": HYPERPARAMETERS,
                "horizon_days": self.horizon_days,
                "validation_period": [
                    VALIDATION_START.isoformat(),
                    VALIDATION_END.isoformat(),
                ],
                "final_test_period": [TEST_START.isoformat(), TEST_END.isoformat()],
                "selection_policy": (
                    "lowest validation WAPE among candidates with exact-zero never-sold "
                    "forecasts and no more than one percentage point NEUTRAL regression "
                    "versus the same-hyperparameter nonseasonal ablation"
                ),
                "final_test_access_policy": (
                    "final-test models are constructed and evaluated only after history "
                    "window and hyperparameters are frozen from validation"
                ),
                "leakage_controls": [
                    "all validation candidates use identical origins and targets",
                    "training observations end at each origin",
                    "generator parameters, noise, shocks, gates and future demand are withheld",
                    "each model is trained from one product's history only",
                    "season/calendar features are deterministic and known for the target date",
                    "final-test labels are not used for window or hyperparameter selection",
                ],
            },
            "validation_by_history_window": validation,
            "validation_selection": selection,
            "final_test": final_report,
            "product_level_comparison": product_level_comparison,
            "transition_anticipation_examples": self._transition_examples(
                final_points,
                seasonal_model=selected_model,
                ablation_model=selected_ablation,
            ),
            "recommendation": recommendation,
            "unchanged_boundaries": [
                "production LightGBM implementation unchanged",
                "active FastAPI model selection unchanged",
                "no Supabase schema or data changes",
                "no Flutter, replenishment or authentication changes",
                "expanded dataset remains offline and unimported",
            ],
        }

    @staticmethod
    def _product_level_comparison(
        *,
        final_report: dict[str, object],
        seasonal_model: str,
        ablation_model: str,
    ) -> dict[str, object]:
        by_product = final_report["by_product"]
        result: dict[str, object] = {}
        for baseline in ("existing_lightgbm", ablation_model):
            rows: list[dict[str, object]] = []
            for sku, seasonal_metrics in by_product[seasonal_model].items():
                seasonal_wape = seasonal_metrics["wape"]
                baseline_wape = by_product[baseline][sku]["wape"]
                if seasonal_wape is None or baseline_wape is None:
                    continue
                rows.append(
                    {
                        "sku": sku,
                        "seasonal_wape": seasonal_wape,
                        "baseline_wape": baseline_wape,
                        "wape_gain": baseline_wape - seasonal_wape,
                    }
                )
            ordered = sorted(rows, key=lambda value: value["wape_gain"])
            result[baseline] = {
                "comparable_products": len(rows),
                "improved": sum(value["wape_gain"] > 0 for value in rows),
                "regressed": sum(value["wape_gain"] < 0 for value in rows),
                "tied": sum(value["wape_gain"] == 0 for value in rows),
                "largest_regressions": ordered[:5],
                "largest_improvements": list(reversed(ordered[-5:])),
            }
        return result

    def _config(self, name: str) -> LightGBMConfig:
        values = HYPERPARAMETERS[name]
        return LightGBMConfig(
            min_history_days=84,
            min_training_rows=40,
            n_estimators=values["n_estimators"],
            learning_rate=values["learning_rate"],
            num_leaves=values["num_leaves"],
            random_seed=26061110,
        )

    def _validation_models(self) -> dict[str, object]:
        models: dict[str, object] = {
            "existing_lightgbm": LightGBMForecaster(
                config=self._config("production_parity")
            )
        }
        for name in HYPERPARAMETERS:
            config = self._config(name)
            models[f"ablation_{name}"] = ProductSpecificSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=False,
                config=config,
                resolver=self.resolver,
            )
            models[f"seasonal_{name}"] = ProductSpecificSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=True,
                config=config,
                resolver=self.resolver,
            )
        return models

    def _final_models(self, hyperparameters: str) -> dict[str, object]:
        config = self._config(hyperparameters)
        return {
            "existing_lightgbm": LightGBMForecaster(
                config=self._config("production_parity")
            ),
            f"ablation_{hyperparameters}": ProductSpecificSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=False,
                config=config,
                resolver=self.resolver,
            ),
            f"seasonal_{hyperparameters}": ProductSpecificSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=True,
                config=config,
                resolver=self.resolver,
            ),
        }

    def _evaluate_split(
        self,
        *,
        datasets: tuple,
        products: dict[str, object],
        split_start: date,
        split_end: date,
        max_history_days: int,
        models: dict[str, object],
    ) -> tuple[list[_Point], dict[str, dict[str, int]], dict[str, int]]:
        points: list[_Point] = []
        counts: dict[str, Counter[str]] = defaultdict(Counter)
        observed_days: list[int] = []
        for origin in self._origins(split_start, split_end):
            training = tuple(
                bounded_dataset(
                    dataset,
                    origin,
                    max_history_days=max_history_days,
                )
                for dataset in datasets
            )
            for dataset in training:
                if any(value.business_date > origin for value in dataset.observations):
                    raise AssertionError("future demand leaked into product training")
                if dataset.history_start is None:
                    raise AssertionError("expanded training unexpectedly lacks a start date")
                observed_days.append((origin - dataset.history_start).days + 1)
                product = products[dataset.product.product_id]
                for name, model in models.items():
                    forecasts = model.forecast(
                        dataset,
                        horizon_days=self.horizon_days,
                    )
                    counts[name][forecasts[0].metadata.model_name] += 1
                    points.extend(
                        self._points(
                            forecasts,
                            product=product,
                            requested_model=name,
                            origin=origin,
                            split_end=split_end,
                        )
                    )
        return (
            points,
            {
                model: dict(sorted(values.items()))
                for model, values in sorted(counts.items())
            },
            {"minimum": min(observed_days), "maximum": max(observed_days)},
        )

    def _points(
        self,
        forecasts: list,
        *,
        product,
        requested_model: str,
        origin: date,
        split_end: date,
    ) -> list[_Point]:
        result: list[_Point] = []
        for forecast in forecasts:
            if not origin < forecast.forecast_date <= split_end:
                raise AssertionError("forecast target falls outside its split")
            context = self.resolver.resolve(
                forecast.location_id,
                forecast.forecast_date,
            )
            result.append(
                _Point(
                    requested_model=requested_model,
                    actual_model=forecast.metadata.model_name,
                    product_id=forecast.product_id,
                    sku=forecast.sku or product.sku,
                    product_name=forecast.product_name,
                    unit=forecast.unit,
                    demand_pattern=product.demand_pattern,
                    origin=origin,
                    forecast_date=forecast.forecast_date,
                    season=context.season.value,
                    transition=context.transition.value,
                    actual=simulated_quantity(product, forecast.forecast_date),
                    predicted=forecast.quantity,
                )
            )
        return result

    def _metrics_report(
        self,
        points: list[_Point],
        *,
        model_counts: dict[str, dict[str, int]],
        origins: tuple[date, ...],
        observed_training_days: dict[str, int],
    ) -> dict[str, object]:
        metrics = FullInventorySeasonalBacktester
        product_group = {value.sku: value.seasonal_group for value in PRODUCTS}
        grouped_points: dict[str, list[_Point]] = defaultdict(list)
        for point in points:
            grouped_points[product_group[point.sku]].append(point)
        transition_points = [value for value in points if value.transition != "none"]
        pretransition_points = [
            value
            for value in transition_points
            if (value.origin.month == 4 and value.transition == "to_rainy")
            or (value.origin.month == 10 and value.transition == "to_dry")
        ]
        return {
            "origins": [value.isoformat() for value in origins],
            "observed_training_calendar_days": observed_training_days,
            "actual_model_counts": model_counts,
            "overall_mixed_unit_diagnostic": metrics._metrics_by(
                points, lambda value: value.requested_model
            ),
            "by_product": metrics._nested_metrics(
                points,
                lambda value: value.requested_model,
                lambda value: value.sku,
            ),
            "by_seasonal_group": {
                group: metrics._metrics_by(
                    values, lambda point: point.requested_model
                )
                for group, values in sorted(grouped_points.items())
            },
            "by_compatible_unit": metrics._nested_metrics(
                points,
                lambda value: value.requested_model,
                lambda value: value.unit,
            ),
            "by_demand_pattern": metrics._nested_metrics(
                points,
                lambda value: value.requested_model,
                lambda value: value.demand_pattern,
            ),
            "by_philippine_season": metrics._nested_metrics(
                points,
                lambda value: value.requested_model,
                lambda value: value.season,
            ),
            "seasonal_transitions": metrics._nested_metrics(
                transition_points,
                lambda value: value.requested_model,
                lambda value: value.transition,
            ),
            "pretransition_anticipation": metrics._nested_metrics(
                pretransition_points,
                lambda value: value.requested_model,
                lambda value: value.transition,
            ),
        }

    def _origins(self, split_start: date, split_end: date) -> tuple[date, ...]:
        return self._origin_helper._origins(split_start, split_end)

    @staticmethod
    def _select_candidate(validation: dict[str, object]) -> dict[str, object]:
        rows: list[dict[str, object]] = []
        for window in HISTORY_WINDOWS:
            report = validation[str(window)]
            for name in HYPERPARAMETERS:
                seasonal = f"seasonal_{name}"
                ablation = f"ablation_{name}"
                overall = report["overall_mixed_unit_diagnostic"]
                groups = report["by_seasonal_group"]
                patterns = report["by_demand_pattern"]
                neutral_gain = (
                    groups["NEUTRAL"][ablation]["wape"]
                    - groups["NEUTRAL"][seasonal]["wape"]
                )
                no_sales_zero = (
                    patterns[seasonal]["no_sales"]["predicted_total"] == 0
                )
                rows.append(
                    {
                        "history_window_days": window,
                        "hyperparameters": name,
                        "model": seasonal,
                        "matched_ablation": ablation,
                        "validation_wape": overall[seasonal]["wape"],
                        "gain_vs_ablation": (
                            overall[ablation]["wape"] - overall[seasonal]["wape"]
                        ),
                        "gain_vs_existing_lightgbm": (
                            overall["existing_lightgbm"]["wape"]
                            - overall[seasonal]["wape"]
                        ),
                        "neutral_gain_vs_ablation": neutral_gain,
                        "no_sales_zero": no_sales_zero,
                        "eligible": bool(
                            no_sales_zero and neutral_gain >= Decimal("-0.01")
                        ),
                    }
                )
        eligible = [value for value in rows if value["eligible"]]
        selected = min(eligible or rows, key=lambda value: value["validation_wape"])
        return {
            **selected,
            "selection_used_final_test": False,
            "all_validation_candidates": rows,
        }

    @staticmethod
    def _recommendation(
        *,
        selection: dict[str, object],
        final_report: dict[str, object],
    ) -> dict[str, object]:
        seasonal = str(selection["model"])
        ablation = str(selection["matched_ablation"])
        overall = final_report["overall_mixed_unit_diagnostic"]
        groups = final_report["by_seasonal_group"]
        transitions = final_report["seasonal_transitions"]
        pretransition = final_report["pretransition_anticipation"]
        patterns = final_report["by_demand_pattern"]
        group_gains = {
            group: values[ablation]["wape"] - values[seasonal]["wape"]
            for group, values in groups.items()
        }
        transition_gains = {
            transition: transitions[ablation][transition]["wape"]
            - transitions[seasonal][transition]["wape"]
            for transition in transitions[seasonal]
        }
        pretransition_gains = {
            transition: pretransition[ablation][transition]["wape"]
            - pretransition[seasonal][transition]["wape"]
            for transition in pretransition[seasonal]
        }
        overall_gain = overall[ablation]["wape"] - overall[seasonal]["wape"]
        versus_existing = (
            overall["existing_lightgbm"]["wape"] - overall[seasonal]["wape"]
        )
        no_sales_zero = patterns[seasonal]["no_sales"]["predicted_total"] == 0
        acceptance = bool(
            overall_gain > 0
            and versus_existing > 0
            and group_gains["SUMMER"] > 0
            and group_gains["RAINY"] > 0
            and group_gains["NEUTRAL"] >= Decimal("-0.01")
            and all(value >= 0 for value in transition_gains.values())
            and all(value >= 0 for value in pretransition_gains.values())
            and no_sales_zero
        )
        revision_case = bool(
            overall_gain > 0
            and no_sales_zero
            and sum(value > 0 for value in group_gains.values()) >= 2
        )
        decision = "ACCEPT" if acceptance else "REVISE" if revision_case else "REJECT"
        return {
            "decision": decision,
            "integration_recommended": acceptance,
            "active_model_to_retain": (
                seasonal if acceptance else "existing_lightgbm"
            ),
            "selected_history_window_days": selection["history_window_days"],
            "selected_hyperparameters": selection["hyperparameters"],
            "selected_model": seasonal,
            "matched_ablation": ablation,
            "final_wape_gain_vs_ablation": overall_gain,
            "final_wape_gain_vs_existing_lightgbm": versus_existing,
            "group_wape_gains_vs_ablation": group_gains,
            "transition_wape_gains_vs_ablation": transition_gains,
            "pretransition_wape_gains_vs_ablation": pretransition_gains,
            "no_sales_false_positive_free": no_sales_zero,
            "acceptance_checks_all_passed": acceptance,
        }

    def _transition_examples(
        self,
        points: list[_Point],
        *,
        seasonal_model: str,
        ablation_model: str,
    ) -> list[dict[str, object]]:
        cases = (
            (date(2026, 4, 15), "SIM-SUM-001"),
            (date(2026, 4, 15), "SIM-RAIN-001"),
            (date(2026, 10, 15), "SIM-RAIN-006"),
            (date(2026, 10, 15), "SIM-NEU-001"),
        )
        products = {value.sku: value for value in PRODUCTS}
        result: list[dict[str, object]] = []
        for origin, sku in cases:
            selected = [
                value
                for value in points
                if value.origin == origin and value.sku == sku
            ]
            if not selected:
                continue
            totals: dict[str, Decimal] = defaultdict(lambda: Decimal("0"))
            actual_by_date: dict[date, Decimal] = {}
            for point in selected:
                totals[point.requested_model] += point.predicted
                actual_by_date[point.forecast_date] = point.actual
            product = products[sku]
            recent = sum(
                (
                    simulated_quantity(product, origin - timedelta(days=offset))
                    for offset in range(27, -1, -1)
                ),
                Decimal("0"),
            )
            result.append(
                {
                    "origin": origin.isoformat(),
                    "sku": sku,
                    "product_name": product.product_name,
                    "seasonal_group": product.seasonal_group,
                    "recent_28_day_actual": recent,
                    "target_28_day_actual": sum(
                        actual_by_date.values(), Decimal("0")
                    ),
                    "predicted_totals": dict(sorted(totals.items())),
                    "seasonal_minus_ablation": (
                        totals[seasonal_model] - totals[ablation_model]
                    ),
                }
            )
        return result
