from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta
from decimal import Decimal

from app.forecasting import (
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    RelatedActivitySeasonalLightGBMForecaster,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
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
MODELS = (
    "mean28",
    "existing_lightgbm",
    "unrestricted_ablation",
    "unrestricted_seasonal",
    "related_ablation",
    "related_seasonal",
)
SEASONAL_CANDIDATES = (
    ("unrestricted_seasonal", "unrestricted_ablation"),
    ("related_seasonal", "related_ablation"),
)


class RevisedSeasonalBacktester:
    """Stage 2.2 offline evaluation; never used by the application API."""

    def __init__(self) -> None:
        self.horizon_days = 28
        self.registry = shared_context_registry()
        self.resolver = PhilippineSeasonResolver()
        self._origin_helper = ExpandedSeasonalBacktester()

    def run(self) -> dict[str, object]:
        datasets = expanded_datasets()
        products = {value.product_id: value for value in PRODUCTS}
        by_window: dict[str, object] = {}
        validation_points: dict[int, list[_Point]] = {}
        final_points: dict[int, list[_Point]] = {}

        for window in HISTORY_WINDOWS:
            print(f"evaluating {window}-day history window", flush=True)
            models = self._models()
            split_reports: dict[str, object] = {}
            for split_name, split_start, split_end in (
                ("validation", VALIDATION_START, VALIDATION_END),
                ("final_test", TEST_START, TEST_END),
            ):
                origins = self._origins(split_start, split_end)
                points, counts, observed_days = self._evaluate_split(
                    datasets=datasets,
                    products=products,
                    split_start=split_start,
                    split_end=split_end,
                    max_history_days=window,
                    models=models,
                )
                split_reports[split_name] = self._metrics_report(
                    points,
                    model_counts=counts,
                    origins=origins,
                    observed_training_days=observed_days,
                )
                if split_name == "validation":
                    validation_points[window] = points
                else:
                    final_points[window] = points
                print(
                    f"completed {window}-day {split_name}: {len(origins)} origins",
                    flush=True,
                )
            by_window[str(window)] = split_reports

        selection = self._select_candidate(by_window)
        selected_window = int(selection["history_window_days"])
        selected_model = str(selection["model"])
        final_report = by_window[str(selected_window)]["final_test"]
        recommendation = self._recommendation(
            selection=selection,
            final_report=final_report,
        )
        return {
            "evaluation_contract": {
                "manifest_version": MANIFEST_VERSION,
                "manifest_sha256": assumptions_sha256(),
                "history_start": HISTORY_START.isoformat(),
                "history_end": HISTORY_END.isoformat(),
                "population": {
                    "expanded_products_evaluated": len(PRODUCTS),
                    "original_products_evaluated": 0,
                    "combined_population": False,
                    "reason": (
                        "the expanded fixture contains exactly 24 new products; the original "
                        "13-product fixture remains a separate frozen 676-day benchmark and "
                        "cannot support 730/1095-day comparisons without fabricating history"
                    ),
                },
                "history_windows_days": list(HISTORY_WINDOWS),
                "horizon_days": self.horizon_days,
                "models": list(MODELS),
                "model_roles": {
                    "existing_lightgbm": (
                        "product-specific model with lag, trend, weekday, and annual "
                        "sine/cosine features"
                    ),
                    "unrestricted_seasonal": "all 24 products in one pool",
                    "related_seasonal": (
                        "three independently known industry-activity pools of eight products"
                    ),
                },
                "selection_policy": (
                    "choose the lowest validation WAPE seasonal candidate whose never-sold "
                    "prediction is zero and whose NEUTRAL WAPE regression versus its matched "
                    "ablation is at most one percentage point; final-test labels are not used"
                ),
                "leakage_controls": [
                    "all window/model variants use identical origins and 28-day targets",
                    "every training dataset ends at its forecast origin",
                    "validation selects the candidate before final-test metrics are inspected",
                    "generator amplitudes, noise streams, shocks, gates and future demand are withheld",
                    "only versioned product context and deterministic future calendar features are known",
                    "the related-pool assignment comes from pre-existing intended-use/activity context",
                ],
            },
            "by_history_window": by_window,
            "validation_selection": selection,
            "selected_final_test": final_report,
            "selected_transition_examples": self._transition_examples(
                final_points[selected_window], selected_model=selected_model
            ),
            "diagnosis": self._diagnosis(by_window),
            "recommendation": recommendation,
            "unchanged_boundaries": [
                "no Supabase schema or data changes",
                "no expanded-dataset import",
                "no Flutter, authentication or replenishment changes",
                "no active forecasting API or model-selection changes",
                "no synthetic seasonal effects were strengthened",
            ],
        }

    def _models(self) -> dict[str, object]:
        mean28 = Mean28Forecaster()
        existing = LightGBMForecaster(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=80,
                learning_rate=0.05,
                num_leaves=15,
                random_seed=26061110,
            ),
            mean28=mean28,
        )
        shared_config = SharedSeasonalLightGBMConfig(
            min_history_days=84,
            min_training_rows=400,
            n_estimators=80,
            learning_rate=0.04,
            num_leaves=20,
            max_depth=6,
            min_child_samples=30,
            reg_alpha=0.1,
            reg_lambda=0.7,
            feature_fraction=0.85,
            bagging_fraction=0.85,
            random_seed=26061110,
            zero_never_sold_forecasts=True,
        )
        return {
            "mean28": mean28,
            "existing_lightgbm": existing,
            "unrestricted_ablation": SharedSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=False,
                config=shared_config,
                resolver=self.resolver,
            ),
            "unrestricted_seasonal": SharedSeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=True,
                config=shared_config,
                resolver=self.resolver,
            ),
            "related_ablation": RelatedActivitySeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=False,
                config=shared_config,
                resolver=self.resolver,
            ),
            "related_seasonal": RelatedActivitySeasonalLightGBMForecaster(
                registry=self.registry,
                include_seasonal_features=True,
                config=shared_config,
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
                    raise AssertionError("future demand leaked into expanded training")
                if dataset.history_start is None:
                    raise AssertionError("expanded training unexpectedly lacks a start date")
                observed_days.append((origin - dataset.history_start).days + 1)
                product = products[dataset.product.product_id]
                for name in ("mean28", "existing_lightgbm"):
                    forecasts = models[name].forecast(
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
            for name in (
                "unrestricted_ablation",
                "unrestricted_seasonal",
                "related_ablation",
                "related_seasonal",
            ):
                forecasts = models[name].forecast_many(
                    training,
                    horizon_days=self.horizon_days,
                )
                grouped: dict[str, list] = defaultdict(list)
                for forecast in forecasts:
                    grouped[forecast.product_id].append(forecast)
                for product_id, values in grouped.items():
                    counts[name][values[0].metadata.model_name] += 1
                    points.extend(
                        self._points(
                            values,
                            product=products[product_id],
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
        }

    def _origins(self, split_start: date, split_end: date) -> tuple[date, ...]:
        return self._origin_helper._origins(split_start, split_end)

    @staticmethod
    def _select_candidate(by_window: dict[str, object]) -> dict[str, object]:
        rows: list[dict[str, object]] = []
        for window in HISTORY_WINDOWS:
            report = by_window[str(window)]["validation"]
            for seasonal, ablation in SEASONAL_CANDIDATES:
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
                        "model": seasonal,
                        "matched_ablation": ablation,
                        "validation_wape": overall[seasonal]["wape"],
                        "validation_gain_vs_ablation": (
                            overall[ablation]["wape"] - overall[seasonal]["wape"]
                        ),
                        "neutral_gain_vs_ablation": neutral_gain,
                        "no_sales_zero": no_sales_zero,
                        "eligible": bool(no_sales_zero and neutral_gain >= Decimal("-0.01")),
                    }
                )
        eligible = [value for value in rows if value["eligible"]]
        pool = eligible or rows
        selected = min(pool, key=lambda value: value["validation_wape"])
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
        overall_gain = overall[ablation]["wape"] - overall[seasonal]["wape"]
        versus_existing = (
            overall["existing_lightgbm"]["wape"] - overall[seasonal]["wape"]
        )
        no_sales_zero = patterns[seasonal]["no_sales"]["predicted_total"] == 0
        acceptance = bool(
            overall_gain > 0
            and versus_existing >= Decimal("-0.005")
            and group_gains["SUMMER"] > 0
            and group_gains["RAINY"] > 0
            and group_gains["NEUTRAL"] >= Decimal("-0.01")
            and all(value >= 0 for value in transition_gains.values())
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
            "activation_allowed": False,
            "selected_history_window_days": selection["history_window_days"],
            "selected_model": seasonal,
            "matched_ablation": ablation,
            "final_wape_gain_vs_ablation": overall_gain,
            "final_wape_gain_vs_existing_lightgbm": versus_existing,
            "group_wape_gains_vs_ablation": group_gains,
            "transition_wape_gains_vs_ablation": transition_gains,
            "no_sales_false_positive_free": no_sales_zero,
            "acceptance_checks_all_passed": acceptance,
            "reason": (
                "the candidate remains an offline experiment and must pass accuracy, "
                "group, transition, neutral-regression, and never-sold checks together"
            ),
        }

    def _transition_examples(
        self,
        points: list[_Point],
        *,
        selected_model: str,
    ) -> list[dict[str, object]]:
        cases = (
            (date(2026, 2, 15), "SIM-SUM-001"),
            (date(2026, 4, 30), "SIM-RAIN-001"),
            (date(2026, 10, 15), "SIM-RAIN-006"),
            (date(2026, 4, 30), "SIM-NEU-001"),
        )
        result: list[dict[str, object]] = []
        for origin, sku in cases:
            selected = [
                value
                for value in points
                if value.origin == origin
                and value.sku == sku
                and value.requested_model
                in {"mean28", "existing_lightgbm", selected_model}
            ]
            if not selected:
                continue
            totals: dict[str, Decimal] = defaultdict(lambda: Decimal("0"))
            actual_by_date: dict[date, Decimal] = {}
            for point in selected:
                totals[point.requested_model] += point.predicted
                actual_by_date[point.forecast_date] = point.actual
            result.append(
                {
                    "origin": origin.isoformat(),
                    "sku": sku,
                    "product_name": selected[0].product_name,
                    "seasonal_group": next(
                        value.seasonal_group for value in PRODUCTS if value.sku == sku
                    ),
                    "target_actual": sum(actual_by_date.values(), Decimal("0")),
                    "predicted_totals": dict(sorted(totals.items())),
                }
            )
        return result

    @staticmethod
    def _diagnosis(by_window: dict[str, object]) -> dict[str, object]:
        stage21 = by_window["1095"]["final_test"]
        groups = stage21["by_seasonal_group"]
        actual_totals = {
            group: values["mean28"]["actual_total"]
            for group, values in groups.items()
        }
        unrestricted_gains = {
            group: values["unrestricted_ablation"]["wape"]
            - values["unrestricted_seasonal"]["wape"]
            for group, values in groups.items()
        }
        related_gains = {
            group: values["related_ablation"]["wape"]
            - values["related_seasonal"]["wape"]
            for group, values in groups.items()
        }
        return {
            "final_test_actual_totals_by_group_mixed_unit_diagnostic": actual_totals,
            "unrestricted_1095_group_wape_gains": unrestricted_gains,
            "related_1095_group_wape_gains": related_gains,
            "findings": [
                "unrestricted L1 pooling weights high-volume products more heavily and can transfer their calendar response into unrelated products",
                "RAINY contains intermittent and deliberately overlapping-use products, so one group-level relationship is less uniform than SUMMER",
                "NEUTRAL products have no designed annual direction; extra seasonal interactions add variance without a stable signal",
                "related-activity pooling isolates transfer by pre-existing use context while its matched ablation keeps that comparison fair",
                "existing LightGBM is the product-specific alternative and already includes annual sine/cosine context",
            ],
        }
