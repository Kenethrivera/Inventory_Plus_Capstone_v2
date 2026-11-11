from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta
from decimal import Decimal
from statistics import mean

from app.forecasting import (
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    SharedProductContextRegistry,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver

from .expanded_seasonal_fixture import (
    HISTORY_END,
    HISTORY_START,
    MANIFEST,
    MANIFEST_VERSION,
    PRODUCTS,
    TEST_END,
    TEST_START,
    TRAINING_END,
    VALIDATION_END,
    VALIDATION_START,
    assumptions_sha256,
    bounded_dataset,
    expanded_datasets,
    shared_context_registry,
    simulated_quantity,
)
from .full_inventory_fixture import (
    PRODUCTS as ORIGINAL_PRODUCTS,
    simulated_quantity as original_quantity,
)
from .seasonal_backtest import FullInventorySeasonalBacktester, _Point


MODELS = (
    "mean28",
    "lightgbm",
    "shared_nonseasonal_ablation",
    "shared_seasonal_lightgbm",
)


class ExpandedSeasonalBacktester:
    """Frozen four-year experiment; never used by the application API."""

    def __init__(self) -> None:
        self.horizon_days = 28
        self.max_history_days = 1095
        self.resolver = PhilippineSeasonResolver()
        self.registry = shared_context_registry()
        mean28 = Mean28Forecaster()
        self.mean28 = mean28
        self.lightgbm = LightGBMForecaster(
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
        )
        self.shared_seasonal = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=True,
            config=shared_config,
            resolver=self.resolver,
        )
        self.shared_ablation = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=False,
            config=shared_config,
            resolver=self.resolver,
        )

    def run(self) -> dict[str, object]:
        datasets = expanded_datasets()
        products = {value.product_id: value for value in PRODUCTS}
        split_reports: dict[str, object] = {}
        all_points: dict[str, list[_Point]] = {}
        for split_name, split_start, split_end in (
            ("validation", VALIDATION_START, VALIDATION_END),
            ("final_test", TEST_START, TEST_END),
        ):
            points, model_counts = self._evaluate_split(
                datasets=datasets,
                products=products,
                split_start=split_start,
                split_end=split_end,
            )
            all_points[split_name] = points
            split_reports[split_name] = self._metrics_report(
                points,
                model_counts=model_counts,
                origins=self._origins(split_start, split_end),
            )

        final_report = split_reports["final_test"]
        recommendation = self._recommendation(final_report)
        return {
            "evaluation_contract": {
                "manifest_version": MANIFEST_VERSION,
                "manifest_sha256": assumptions_sha256(),
                "history_start": HISTORY_START.isoformat(),
                "history_end": HISTORY_END.isoformat(),
                "calendar_days": (HISTORY_END - HISTORY_START).days + 1,
                "product_count": len(PRODUCTS),
                "group_counts": dict(
                    sorted(Counter(value.seasonal_group for value in PRODUCTS).items())
                ),
                "training_period": [HISTORY_START.isoformat(), TRAINING_END.isoformat()],
                "validation_period": [
                    VALIDATION_START.isoformat(),
                    VALIDATION_END.isoformat(),
                ],
                "final_test_period": [TEST_START.isoformat(), TEST_END.isoformat()],
                "horizon_days": self.horizon_days,
                "maximum_training_calendar_days": self.max_history_days,
                "models": list(MODELS),
                "leakage_controls": [
                    "simulation manifest and generator assumptions are frozen before evaluation",
                    "all models use identical origins and target dates within each split",
                    "training observations end at the origin and never include target dates",
                    "generator amplitudes, random streams, shocks and intermittency gates are unavailable to models",
                    "only product classification and deterministic future calendar context are future-known",
                    "actual target demand is evaluated only after all forecasts are generated",
                    "validation and final-test periods are chronologically disjoint",
                ],
            },
            "product_manifest": [
                {
                    "sku": value.sku,
                    "product_name": value.product_name,
                    "category": value.category,
                    "unit": value.unit,
                    "product_type": value.product_type,
                    "intended_use_group": value.intended_use_group,
                    "seasonal_group": value.seasonal_group,
                    "baseline_daily": value.baseline_daily,
                    "primary_amplitude": value.primary_amplitude,
                    "secondary_amplitude": value.secondary_amplitude,
                    "trend_per_year": value.trend_per_year,
                    "intermittency_probability": value.intermittency_probability,
                    "evidence_level": value.evidence_level,
                    "rationale": value.rationale,
                    "source_ids": value.source_ids,
                }
                for value in PRODUCTS
            ],
            "original_dataset_signal_audit": original_dataset_signal_audit(),
            "expanded_dataset_signal_audit": expanded_dataset_signal_audit(),
            "validation": split_reports["validation"],
            "final_test": final_report,
            "transition_anticipation_examples": self._transition_examples(
                all_points["final_test"]
            ),
            "recommendation": recommendation,
            "database_assessment": {
                "schema_change_required": False,
                "reason": (
                    "products already stores identity/category/unit/description and order_history "
                    "stores dated completed item snapshots consumed by forecast_daily_demand_v1"
                ),
                "runtime_change_if_later_integrated": (
                    "the experimental API request window would need more than the current 365-day "
                    "application history setting; the deployed RPC already allows up to five years"
                ),
                "import_recommended_now": False,
                "import_reason": (
                    "offline evidence must be reviewed first and the pooled model still requires "
                    "a no-sales safeguard before adding 24 products to operational staging"
                ),
            },
            "limitations": [
                "SUMMER, RAINY and NEUTRAL are frozen simulation hypotheses, not observed Philippine retail effects.",
                "PAGASA climatology supplies future-known dates, not actual or forecast rainfall observations.",
                "PIDS evidence supports a general outdoor-work mechanism, not any product coefficient.",
                "The same deterministic generator cannot substitute for evaluation on independent real stores.",
                "Compatible-unit and product-level results are decision-safe; mixed-unit totals are diagnostic only.",
            ],
        }

    def _evaluate_split(
        self,
        *,
        datasets: tuple,
        products: dict[str, object],
        split_start: date,
        split_end: date,
    ) -> tuple[list[_Point], dict[str, dict[str, int]]]:
        points: list[_Point] = []
        counts: dict[str, Counter[str]] = defaultdict(Counter)
        for origin in self._origins(split_start, split_end):
            training = tuple(
                bounded_dataset(
                    dataset,
                    origin,
                    max_history_days=self.max_history_days,
                )
                for dataset in datasets
            )
            for dataset in training:
                if any(value.business_date > origin for value in dataset.observations):
                    raise AssertionError("future demand leaked into expanded training")
                product = products[dataset.product.product_id]
                for name, model in (
                    ("mean28", self.mean28),
                    ("lightgbm", self.lightgbm),
                ):
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
            for name, model in (
                ("shared_nonseasonal_ablation", self.shared_ablation),
                ("shared_seasonal_lightgbm", self.shared_seasonal),
            ):
                forecasts = model.forecast_many(
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
        return points, {
            model: dict(sorted(values.items()))
            for model, values in sorted(counts.items())
        }

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
    ) -> dict[str, object]:
        metrics = FullInventorySeasonalBacktester
        product_group = {value.sku: value.seasonal_group for value in PRODUCTS}
        grouped_points: dict[str, list[_Point]] = defaultdict(list)
        for point in points:
            grouped_points[product_group[point.sku]].append(point)
        by_group: dict[str, object] = {}
        for group, values in sorted(grouped_points.items()):
            by_group[group] = metrics._metrics_by(
                values,
                lambda point: point.requested_model,
            )
        transition_points = [value for value in points if value.transition != "none"]
        return {
            "origins": [value.isoformat() for value in origins],
            "actual_model_counts": model_counts,
            "overall_mixed_unit_diagnostic": metrics._metrics_by(
                points,
                lambda value: value.requested_model,
            ),
            "by_product": metrics._nested_metrics(
                points,
                lambda value: value.requested_model,
                lambda value: value.sku,
            ),
            "by_seasonal_group": by_group,
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
        values: set[date] = set()
        origin = split_start - timedelta(days=1)
        while origin + timedelta(days=self.horizon_days) <= split_end:
            values.add(origin)
            origin += timedelta(days=self.horizon_days)
        values.add(split_end - timedelta(days=self.horizon_days))
        for year in range(split_start.year, split_end.year + 1):
            for month, day in (
                (2, 15),
                (4, 15),
                (4, 30),
                (5, 15),
                (10, 15),
                (10, 31),
            ):
                candidate = date(year, month, day)
                if (
                    candidate >= split_start - timedelta(days=1)
                    and candidate + timedelta(days=self.horizon_days) <= split_end
                ):
                    values.add(candidate)
        return tuple(sorted(values))

    def _transition_examples(self, points: list[_Point]) -> list[dict[str, object]]:
        cases = (
            (date(2026, 2, 15), "SIM-RAIN-001"),
            (date(2026, 4, 30), "SIM-RAIN-006"),
            (date(2026, 10, 12), "SIM-SUM-006"),
            (date(2026, 4, 30), "SIM-NEU-001"),
        )
        by_sku = {value.sku: value for value in PRODUCTS}
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
            daily: dict[str, list[dict[str, object]]] = defaultdict(list)
            actual_by_date: dict[date, Decimal] = {}
            for point in selected:
                totals[point.requested_model] += point.predicted
                actual_by_date[point.forecast_date] = point.actual
                daily[point.requested_model].append(
                    {
                        "date": point.forecast_date.isoformat(),
                        "predicted": point.predicted,
                        "actual": point.actual,
                    }
                )
            product = by_sku[sku]
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
                        totals["shared_seasonal_lightgbm"]
                        - totals["shared_nonseasonal_ablation"]
                    ),
                    "daily": dict(sorted(daily.items())),
                }
            )
        return result

    @staticmethod
    def _recommendation(final_report: dict[str, object]) -> dict[str, object]:
        overall = final_report["overall_mixed_unit_diagnostic"]
        groups = final_report["by_seasonal_group"]
        transitions = final_report["seasonal_transitions"]
        patterns = final_report["by_demand_pattern"]
        seasonal = "shared_seasonal_lightgbm"
        ablation = "shared_nonseasonal_ablation"
        overall_gain = overall[ablation]["wape"] - overall[seasonal]["wape"]
        group_gains = {
            group: values[ablation]["wape"] - values[seasonal]["wape"]
            for group, values in groups.items()
        }
        transition_gains = {
            transition: transitions[ablation][transition]["wape"]
            - transitions[seasonal][transition]["wape"]
            for transition in transitions[seasonal]
        }
        no_sales_zero = patterns[seasonal]["no_sales"]["predicted_total"] == 0
        neutral_regression_ok = group_gains["NEUTRAL"] >= Decimal("-0.01")
        seasonal_groups_improve = (
            group_gains["SUMMER"] > 0 and group_gains["RAINY"] > 0
        )
        transitions_improve = all(value > 0 for value in transition_gains.values())
        if (
            overall_gain > 0
            and seasonal_groups_improve
            and transitions_improve
            and neutral_regression_ok
            and no_sales_zero
        ):
            decision = "ACCEPT"
        elif overall_gain > 0 and seasonal_groups_improve:
            decision = "REVISE"
        else:
            decision = "REJECT"
        return {
            "decision": decision,
            "activation_allowed": False,
            "overall_wape_gain_vs_ablation": overall_gain,
            "group_wape_gains_vs_ablation": group_gains,
            "transition_wape_gains_vs_ablation": transition_gains,
            "seasonal_groups_both_improve": seasonal_groups_improve,
            "all_transitions_improve": transitions_improve,
            "neutral_regression_within_one_percentage_point": neutral_regression_ok,
            "no_sales_false_positive_free": no_sales_zero,
        }


def _signal_row(
    *,
    sku: str,
    product_name: str,
    expected_direction: str,
    values: list[tuple[date, Decimal]],
    resolver: PhilippineSeasonResolver,
) -> dict[str, object]:
    season_values: dict[str, list[float]] = defaultdict(list)
    month_values: dict[int, list[float]] = defaultdict(list)
    numeric_values: list[float] = []
    for business_date, quantity in values:
        number = float(quantity)
        numeric_values.append(number)
        context = resolver.resolve(
            "11111111-1111-1111-1111-111111111111",
            business_date,
        )
        season_values[context.season.value].append(number)
        month_values[business_date.month].append(number)
    season_means = {
        key: mean(group) if group else 0.0
        for key, group in sorted(season_values.items())
    }
    month_means = {
        str(key): mean(group) if group else 0.0
        for key, group in sorted(month_values.items())
    }
    overall_mean = mean(numeric_values)
    total_variation = sum((value - overall_mean) ** 2 for value in numeric_values)
    between_month_variation = sum(
        len(month_values[month])
        * (mean(month_values[month]) - overall_mean) ** 2
        for month in month_values
    )
    eta_squared = (
        between_month_variation / total_variation if total_variation > 0 else 0.0
    )
    nonzero_months = [value for value in month_means.values() if value > 0]
    peak_trough_ratio = (
        max(nonzero_months) / min(nonzero_months)
        if nonzero_months and min(nonzero_months) > 0
        else None
    )
    strongest = max(season_means, key=season_means.get) if season_means else "none"
    aligned = (
        expected_direction == "unknown"
        or expected_direction == "neutral"
        or strongest == expected_direction
        or (expected_direction == "summer" and strongest == "dry")
    )
    return {
        "sku": sku,
        "product_name": product_name,
        "expected_direction": expected_direction,
        "season_daily_means": season_means,
        "month_daily_means": month_means,
        "monthly_eta_squared": eta_squared,
        "peak_to_trough_month_ratio": peak_trough_ratio,
        "strongest_calendar_season": strongest,
        "direction_aligned": aligned,
        "meaningful_calendar_signal": bool(
            overall_mean > 0
            and eta_squared >= 0.05
            and peak_trough_ratio is not None
            and peak_trough_ratio >= 1.15
        ),
    }


def original_dataset_signal_audit() -> dict[str, object]:
    resolver = PhilippineSeasonResolver()
    explicit_month_patterns = {
        "high_seasonal",
        "seasonal_medium",
        "growing_seasonal",
        "intermittent_seasonal",
    }
    registry = SharedProductContextRegistry.from_catalog(ORIGINAL_PRODUCTS)
    rows: list[dict[str, object]] = []
    for product in ORIGINAL_PRODUCTS:
        context = registry.require(product.product_id)
        values: list[tuple[date, Decimal]] = []
        current = date(2025, 1, 1)
        while current <= date(2026, 11, 7):
            values.append((current, original_quantity(product, current)))
            current += timedelta(days=1)
        row = _signal_row(
            sku=product.sku,
            product_name=product.product_name,
            expected_direction=context.seasonal_relevance,
            values=values,
            resolver=resolver,
        )
        row["generator_has_explicit_month_effect"] = (
            product.demand_pattern in explicit_month_patterns
        )
        row["demand_pattern"] = product.demand_pattern
        rows.append(row)
    return {
        "products": rows,
        "products_with_explicit_month_effect": sum(
            bool(value["generator_has_explicit_month_effect"]) for value in rows
        ),
        "products_meeting_signal_threshold": sum(
            bool(value["meaningful_calendar_signal"]) for value in rows
        ),
        "products_with_direction_mismatch": [
            value["sku"]
            for value in rows
            if value["expected_direction"] not in {"unknown", "neutral"}
            and not value["direction_aligned"]
        ],
        "audit_conclusion": (
            "The fixture contains a few learnable calendar patterns, but it is not a "
            "controlled seasonal-class experiment: only four formulas contain explicit "
            "month effects, programmed peaks are heterogeneous, and the 365-day model "
            "window provides at most one annual cycle."
        ),
    }


def expanded_dataset_signal_audit() -> dict[str, object]:
    resolver = PhilippineSeasonResolver()
    rows: list[dict[str, object]] = []
    for product in PRODUCTS:
        values: list[tuple[date, Decimal]] = []
        current = HISTORY_START
        while current <= HISTORY_END:
            values.append((current, simulated_quantity(product, current)))
            current += timedelta(days=1)
        rows.append(
            _signal_row(
                sku=product.sku,
                product_name=product.product_name,
                expected_direction=product.seasonal_group.casefold(),
                values=values,
                resolver=resolver,
            )
        )
    return {
        "products": rows,
        "products_meeting_signal_threshold": sum(
            bool(value["meaningful_calendar_signal"]) for value in rows
        ),
        "by_group": {
            group: {
                "products": len(
                    [
                        value
                        for value in PRODUCTS
                        if value.seasonal_group == group
                    ]
                ),
                "meaningful_signals": sum(
                    bool(row["meaningful_calendar_signal"])
                    for row, product in zip(rows, PRODUCTS, strict=True)
                    if product.seasonal_group == group
                ),
            }
            for group in ("SUMMER", "RAINY", "NEUTRAL")
        },
    }
