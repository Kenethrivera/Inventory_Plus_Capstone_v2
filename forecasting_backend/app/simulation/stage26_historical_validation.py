from __future__ import annotations

import csv
import hashlib
import json
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

from app.data import DailyDemand
from app.forecasting import (
    HistoricalDemandDataset,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver

from .expanded_seasonal_fixture import (
    HISTORY_END,
    HISTORY_START,
    LOCATION_ID,
    MANIFEST_VERSION,
    PRODUCTS,
    TEST_END,
    TEST_START,
    assumptions_sha256,
    bounded_dataset,
    shared_context_registry,
    simulated_quantity,
)
from .product_specific_seasonal_backtest import ProductSpecificSeasonalBacktester


MODEL_NAMES = (
    "mean28",
    "existing_lightgbm",
    "matched_nonseasonal_ablation",
    "product_specific_seasonal_lightgbm",
)
HORIZONS = (7, 28)
MAX_HISTORY_DAYS = 1095


@dataclass(frozen=True)
class DenseHistory:
    source_path: str
    source_sha256: str
    quantities: dict[tuple[date, str], Decimal]
    units: dict[str, str]
    product_names: dict[str, str]
    skus: dict[str, str]
    categories: dict[str, str]
    seasonal_groups: dict[str, str]


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _decimal(value: object, *, field: str, row_number: int) -> Decimal:
    try:
        parsed = Decimal(str(value).strip())
    except Exception as error:
        raise ValueError(f"row {row_number}: {field} is not numeric") from error
    if not parsed.is_finite() or parsed < 0:
        raise ValueError(f"row {row_number}: {field} must be finite and nonnegative")
    return parsed


def load_dense_history(path: Path) -> DenseHistory:
    required = {
        "business_date",
        "product_id",
        "sku",
        "product_name",
        "category",
        "unit",
        "seasonal_group",
        "quantity",
    }
    quantities: dict[tuple[date, str], Decimal] = {}
    units: dict[str, str] = {}
    names: dict[str, str] = {}
    skus: dict[str, str] = {}
    categories: dict[str, str] = {}
    groups: dict[str, str] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = required.difference(reader.fieldnames or ())
        if missing:
            raise ValueError(f"history CSV is missing columns: {sorted(missing)}")
        for row_number, row in enumerate(reader, start=2):
            try:
                business_date = date.fromisoformat(row["business_date"].strip())
            except ValueError as error:
                raise ValueError(
                    f"row {row_number}: business_date is invalid"
                ) from error
            product_id = row["product_id"].strip()
            key = (business_date, product_id)
            if key in quantities:
                raise ValueError(
                    f"row {row_number}: duplicate product/date {product_id} {business_date}"
                )
            quantities[key] = _decimal(
                row["quantity"], field="quantity", row_number=row_number
            )
            metadata = (
                (units, "unit"),
                (names, "product_name"),
                (skus, "sku"),
                (categories, "category"),
                (groups, "seasonal_group"),
            )
            for target, field in metadata:
                value = row[field].strip()
                if product_id in target and target[product_id] != value:
                    raise ValueError(
                        f"row {row_number}: inconsistent {field} for {product_id}"
                    )
                target[product_id] = value
    return DenseHistory(
        source_path=str(path),
        source_sha256=_sha256(path),
        quantities=quantities,
        units=units,
        product_names=names,
        skus=skus,
        categories=categories,
        seasonal_groups=groups,
    )


def _expected_keys() -> set[tuple[date, str]]:
    keys: set[tuple[date, str]] = set()
    current = HISTORY_START
    while current <= HISTORY_END:
        keys.update((current, product.product_id) for product in PRODUCTS)
        current += timedelta(days=1)
    return keys


def verify_frozen_history(history: DenseHistory) -> dict[str, object]:
    expected_keys = _expected_keys()
    actual_keys = set(history.quantities)
    mismatches: list[dict[str, object]] = []
    generator_mismatch_count = 0
    metadata_mismatch_count = 0
    for product in PRODUCTS:
        expected_metadata = {
            "unit": product.unit,
            "product_name": product.product_name,
            "sku": product.sku,
            "category": product.category,
            "seasonal_group": product.seasonal_group,
        }
        actual_metadata = {
            "unit": history.units.get(product.product_id),
            "product_name": history.product_names.get(product.product_id),
            "sku": history.skus.get(product.product_id),
            "category": history.categories.get(product.product_id),
            "seasonal_group": history.seasonal_groups.get(product.product_id),
        }
        for field, expected in expected_metadata.items():
            if actual_metadata[field] != expected:
                metadata_mismatch_count += 1
                if len(mismatches) < 100:
                    mismatches.append(
                        {
                            "type": "metadata",
                            "product_id": product.product_id,
                            "field": field,
                            "expected": expected,
                            "actual": actual_metadata[field],
                        }
                    )
        current = HISTORY_START
        while current <= HISTORY_END:
            actual = history.quantities.get((current, product.product_id))
            expected = simulated_quantity(product, current)
            if actual is not None and actual != expected:
                generator_mismatch_count += 1
                if len(mismatches) < 100:
                    mismatches.append(
                        {
                            "type": "quantity",
                            "business_date": current.isoformat(),
                            "product_id": product.product_id,
                            "sku": product.sku,
                            "expected": str(expected),
                            "actual": str(actual),
                        }
                    )
            current += timedelta(days=1)
    unexpected = actual_keys.difference(expected_keys)
    missing = expected_keys.difference(actual_keys)
    zero_rows = sum(value == 0 for value in history.quantities.values())
    return {
        "status": (
            "PASS"
            if not missing
            and not unexpected
            and generator_mismatch_count == 0
            and metadata_mismatch_count == 0
            else "FAIL"
        ),
        "source_path": history.source_path,
        "source_sha256": history.source_sha256,
        "expected_rows": len(expected_keys),
        "actual_rows": len(actual_keys),
        "expected_products": len(PRODUCTS),
        "actual_products": len(history.units),
        "history_start": HISTORY_START.isoformat(),
        "history_end": HISTORY_END.isoformat(),
        "missing_product_date_rows": len(missing),
        "unexpected_product_date_rows": len(unexpected),
        "sample_missing_product_dates": [
            {
                "business_date": value[0].isoformat(),
                "product_id": value[1],
            }
            for value in sorted(missing)[:100]
        ],
        "sample_unexpected_product_dates": [
            {
                "business_date": value[0].isoformat(),
                "product_id": value[1],
            }
            for value in sorted(unexpected)[:100]
        ],
        "zero_demand_rows": zero_rows,
        "positive_demand_rows": len(history.quantities) - zero_rows,
        "generator_quantity_mismatches": generator_mismatch_count,
        "metadata_mismatches": metadata_mismatch_count,
        "sample_mismatches": mismatches,
    }


def compare_live_history(
    frozen: DenseHistory,
    live: DenseHistory | None,
) -> dict[str, object]:
    if live is None:
        return {
            "status": "NOT_RUN",
            "database_verified": False,
            "blocking_reason": (
                "No read-only live history export was available in this session."
            ),
        }
    frozen_keys = set(frozen.quantities)
    live_keys = set(live.quantities)
    missing = frozen_keys.difference(live_keys)
    unexpected = live_keys.difference(frozen_keys)
    quantity_mismatches: list[dict[str, object]] = []
    quantity_mismatch_count = 0
    for key in sorted(frozen_keys.intersection(live_keys)):
        if frozen.quantities[key] != live.quantities[key]:
            quantity_mismatch_count += 1
            if len(quantity_mismatches) < 100:
                quantity_mismatches.append(
                    {
                        "business_date": key[0].isoformat(),
                        "product_id": key[1],
                        "sku": frozen.skus.get(key[1]),
                        "expected": str(frozen.quantities[key]),
                        "actual": str(live.quantities[key]),
                    }
                )
    metadata_mismatches: list[dict[str, object]] = []
    for product in PRODUCTS:
        product_id = product.product_id
        for name, expected, actual in (
            ("unit", frozen.units[product_id], live.units.get(product_id)),
            ("sku", frozen.skus[product_id], live.skus.get(product_id)),
            (
                "product_name",
                frozen.product_names[product_id],
                live.product_names.get(product_id),
            ),
        ):
            if actual != expected:
                metadata_mismatches.append(
                    {
                        "product_id": product_id,
                        "field": name,
                        "expected": expected,
                        "actual": actual,
                    }
                )
    passed = (
        not missing
        and not unexpected
        and quantity_mismatch_count == 0
        and not metadata_mismatches
    )
    return {
        "status": "PASS" if passed else "FAIL",
        "database_verified": passed,
        "source_path": live.source_path,
        "source_sha256": live.source_sha256,
        "expected_rows": len(frozen_keys),
        "actual_rows": len(live_keys),
        "missing_product_date_rows": len(missing),
        "unexpected_product_date_rows": len(unexpected),
        "sample_missing_product_dates": [
            {
                "business_date": value[0].isoformat(),
                "product_id": value[1],
            }
            for value in sorted(missing)[:100]
        ],
        "sample_unexpected_product_dates": [
            {
                "business_date": value[0].isoformat(),
                "product_id": value[1],
            }
            for value in sorted(unexpected)[:100]
        ],
        "quantity_mismatches": quantity_mismatch_count,
        "metadata_mismatches": len(metadata_mismatches),
        "sample_quantity_mismatches": quantity_mismatches,
        "sample_metadata_mismatches": metadata_mismatches[:100],
    }


def datasets_from_dense_history(
    history: DenseHistory,
) -> tuple[HistoricalDemandDataset, ...]:
    datasets: list[HistoricalDemandDataset] = []
    for product in PRODUCTS:
        observations: list[DailyDemand] = []
        current = HISTORY_START
        while current <= HISTORY_END:
            quantity = history.quantities[(current, product.product_id)]
            if quantity > 0:
                observations.append(
                    DailyDemand(
                        business_date=current,
                        location_id=LOCATION_ID,
                        product_id=product.product_id,
                        sku=product.sku,
                        product_name=product.product_name,
                        unit=product.unit,
                        quantity=quantity,
                        completed_order_count=1,
                    )
                )
            current += timedelta(days=1)
        datasets.append(
            HistoricalDemandDataset.from_real_observations(
                product=product.forecast_product,
                history_start=HISTORY_START,
                history_end=HISTORY_END,
                observations=observations,
            )
        )
    return tuple(datasets)


def _config(*, conservative: bool) -> LightGBMConfig:
    return LightGBMConfig(
        min_history_days=84,
        min_training_rows=40,
        n_estimators=120 if conservative else 80,
        learning_rate=0.03 if conservative else 0.05,
        num_leaves=10 if conservative else 15,
        random_seed=26061110,
    )


def _models() -> dict[str, object]:
    mean = Mean28Forecaster()
    registry = shared_context_registry()
    resolver = PhilippineSeasonResolver()
    return {
        "mean28": mean,
        "existing_lightgbm": LightGBMForecaster(
            config=_config(conservative=False), mean28=mean
        ),
        "matched_nonseasonal_ablation": (
            ProductSpecificSeasonalLightGBMForecaster(
                registry=registry,
                include_seasonal_features=False,
                config=_config(conservative=True),
                mean28=mean,
                resolver=resolver,
                zero_never_sold_forecasts=True,
            )
        ),
        "product_specific_seasonal_lightgbm": (
            ProductSpecificSeasonalLightGBMForecaster(
                registry=registry,
                include_seasonal_features=True,
                config=_config(conservative=True),
                mean28=mean,
                resolver=resolver,
                zero_never_sold_forecasts=True,
            )
        ),
    }


def _metric(rows: Iterable[dict[str, object]]) -> dict[str, object]:
    values = list(rows)
    actual = sum((Decimal(str(row["actual"])) for row in values), Decimal("0"))
    predicted = sum(
        (Decimal(str(row["predicted"])) for row in values), Decimal("0")
    )
    absolute = sum(
        (
            abs(Decimal(str(row["predicted"])) - Decimal(str(row["actual"])))
            for row in values
        ),
        Decimal("0"),
    )
    count = len(values)
    return {
        "observations": count,
        "actual_total": actual,
        "predicted_total": predicted,
        "mae": absolute / Decimal(count) if count else Decimal("0"),
        "wape": absolute / actual if actual > 0 else None,
        "signed_bias": (predicted - actual) / actual if actual > 0 else None,
    }


def _metrics_by(
    rows: Iterable[dict[str, object]], *keys: str
) -> dict[str, object]:
    grouped: dict[tuple[str, ...], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[tuple(str(row[key]) for key in keys)].append(row)
    result: dict[str, object] = {}
    for group, values in sorted(grouped.items()):
        target = result
        for name in group[:-1]:
            target = target.setdefault(name, {})  # type: ignore[assignment]
        target[group[-1]] = _metric(values)
    return result


class Stage26HistoricalValidator:
    def __init__(
        self,
        *,
        frozen_history: DenseHistory,
        live_history: DenseHistory | None,
        stage23_report: dict[str, object],
    ) -> None:
        self.frozen_history = frozen_history
        self.live_history = live_history
        self.stage23_report = stage23_report
        self.resolver = PhilippineSeasonResolver()
        self.products = {product.product_id: product for product in PRODUCTS}

    def run(self) -> tuple[dict[str, object], list[dict[str, object]], list[dict[str, object]]]:
        frozen_verification = verify_frozen_history(self.frozen_history)
        live_verification = compare_live_history(
            self.frozen_history, self.live_history
        )
        if frozen_verification["status"] != "PASS":
            raise ValueError("the frozen daily-demand CSV failed integrity validation")
        if live_verification["status"] == "FAIL":
            return (
                self._verification_only_report(
                    frozen_verification, live_verification
                ),
                [],
                [],
            )

        evaluation_history = self.live_history or self.frozen_history
        datasets = datasets_from_dense_history(evaluation_history)
        points, model_counts, origins = self._evaluate(datasets, evaluation_history)
        metrics = self._metrics_report(points)
        replay = self._replay(datasets, evaluation_history)
        comparison = self._stage23_comparison(metrics)
        model_recommendation = self._model_recommendation(metrics)
        database_verified = bool(live_verification["database_verified"])
        stage_decision = "PASS" if database_verified else "REVISE"
        report = {
            "stage": "2.6",
            "decision": stage_decision,
            "database_verification": live_verification,
            "frozen_dataset_verification": frozen_verification,
            "evaluation_contract": {
                "manifest_version": MANIFEST_VERSION,
                "manifest_sha256": assumptions_sha256(),
                "evaluation_source": (
                    "verified_live_export" if database_verified else "frozen_csv_only"
                ),
                "products": len(PRODUCTS),
                "original_products_in_metrics": 0,
                "original_products_preserved_separately": True,
                "history_start": HISTORY_START.isoformat(),
                "history_end": HISTORY_END.isoformat(),
                "history_window_days": MAX_HISTORY_DAYS,
                "origins": [value.isoformat() for value in origins],
                "horizons_days": list(HORIZONS),
                "models": list(MODEL_NAMES),
                "leakage_controls": [
                    "every training dataset ends exactly at its forecast origin",
                    "no training observation may be later than the origin",
                    "every target date is strictly later than the origin",
                    "actual target quantities are joined only after forecasts are frozen",
                    "all models use identical origins, targets and maximum history",
                    "season and transition features are deterministic future-known calendar context",
                    "simulation amplitudes, random streams and future quantities are not model inputs",
                    "Stage 2.3 hyperparameters and 1095-day window are frozen without Stage 2.6 retuning",
                ],
            },
            "actual_model_counts": model_counts,
            "metrics": metrics,
            "stage23_comparison": comparison,
            "historical_replay": replay,
            "seasonal_learning_assessment": self._seasonal_assessment(metrics),
            "model_recommendation": model_recommendation,
            "illustrative_hammer_overprediction": {
                "status": "constructed_arithmetic_example_not_model_output",
                "product": "Illustrative Claw Hammer",
                "forecast_units": 20,
                "actual_units": 5,
                "signed_error_predicted_minus_actual": 15,
                "absolute_error": 15,
                "next_forecast_units": None,
                "note": (
                    "No next forecast is invented. The real replay below retrains only "
                    "from newly revealed sales and applies no explicit error subtraction."
                ),
            },
            "limitations": [
                "Synthetic results do not establish real Philippine hardware retail effects.",
                "Frozen SUMMER/RAINY/NEUTRAL labels are supplied context, not independently discovered labels.",
                "The candidate relearns from appended sales; explicit residual/error calibration is not implemented.",
                "A later forecast is not guaranteed to improve after every prior error.",
                (
                    "Live Supabase equality remains unverified in this run."
                    if not database_verified
                    else "The live export matched the frozen fixture exactly."
                ),
            ],
        }
        return report, points, replay["rows"]  # type: ignore[return-value]

    @staticmethod
    def _verification_only_report(
        frozen: dict[str, object], live: dict[str, object]
    ) -> dict[str, object]:
        return {
            "stage": "2.6",
            "decision": "FAIL",
            "database_verification": live,
            "frozen_dataset_verification": frozen,
            "accuracy_evaluation": "NOT_RUN_DUE_TO_HISTORY_MISMATCH",
        }

    def _evaluate(
        self,
        datasets: tuple[HistoricalDemandDataset, ...],
        history: DenseHistory,
    ) -> tuple[list[dict[str, object]], dict[str, dict[str, int]], tuple[date, ...]]:
        origins = ProductSpecificSeasonalBacktester()._origins(TEST_START, TEST_END)
        models = _models()
        points: list[dict[str, object]] = []
        model_counts: dict[str, Counter[str]] = defaultdict(Counter)
        for origin in origins:
            for source_dataset in datasets:
                training = bounded_dataset(
                    source_dataset,
                    origin,
                    max_history_days=MAX_HISTORY_DAYS,
                )
                if training.history_end != origin:
                    raise AssertionError("training end does not equal forecast origin")
                if any(row.business_date > origin for row in training.observations):
                    raise AssertionError("future sales leaked into training")
                product = self.products[training.product.product_id]
                for model_name, model in models.items():
                    forecasts = model.forecast(training, horizon_days=max(HORIZONS))
                    model_counts[model_name][forecasts[0].metadata.model_name] += 1
                    frozen_predictions = tuple(forecasts)
                    for horizon in HORIZONS:
                        for forecast in frozen_predictions[:horizon]:
                            if not origin < forecast.forecast_date <= TEST_END:
                                raise AssertionError(
                                    "forecast target is outside the untouched test split"
                                )
                            context = self.resolver.resolve(
                                forecast.location_id, forecast.forecast_date
                            )
                            actual = history.quantities[
                                (forecast.forecast_date, product.product_id)
                            ]
                            points.append(
                                {
                                    "horizon_days": horizon,
                                    "origin": origin,
                                    "forecast_date": forecast.forecast_date,
                                    "requested_model": model_name,
                                    "actual_model": forecast.metadata.model_name,
                                    "product_id": product.product_id,
                                    "sku": product.sku,
                                    "product_name": product.product_name,
                                    "unit": product.unit,
                                    "seasonal_group": product.seasonal_group,
                                    "demand_pattern": product.demand_pattern,
                                    "season": context.season.value,
                                    "transition": context.transition.value,
                                    "actual": actual,
                                    "predicted": forecast.quantity,
                                    "signed_error": forecast.quantity - actual,
                                    "absolute_error": abs(forecast.quantity - actual),
                                }
                            )
        return (
            points,
            {
                name: dict(sorted(counts.items()))
                for name, counts in sorted(model_counts.items())
            },
            origins,
        )

    def _metrics_report(self, points: list[dict[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for horizon in HORIZONS:
            rows = [row for row in points if row["horizon_days"] == horizon]
            transition_rows = [row for row in rows if row["transition"] != "none"]
            pretransition_rows = [
                row
                for row in transition_rows
                if (
                    row["transition"] == "to_rainy"
                    and row["origin"].month == 4  # type: ignore[union-attr]
                )
                or (
                    row["transition"] == "to_dry"
                    and row["origin"].month == 10  # type: ignore[union-attr]
                )
            ]
            result[str(horizon)] = {
                "overall_mixed_unit_diagnostic": _metrics_by(
                    rows, "requested_model"
                ),
                "by_product": _metrics_by(rows, "requested_model", "sku"),
                "by_seasonal_group": _metrics_by(
                    rows, "seasonal_group", "requested_model"
                ),
                "by_compatible_unit": _metrics_by(
                    rows, "requested_model", "unit"
                ),
                "by_philippine_season": _metrics_by(
                    rows, "requested_model", "season"
                ),
                "by_demand_pattern": _metrics_by(
                    rows, "requested_model", "demand_pattern"
                ),
                "seasonal_transitions": _metrics_by(
                    transition_rows, "requested_model", "transition"
                ),
                "pretransition_anticipation": _metrics_by(
                    pretransition_rows, "requested_model", "transition"
                ),
                "forecast_vs_actual_examples": self._examples(rows),
            }
        return result

    @staticmethod
    def _examples(rows: list[dict[str, object]]) -> list[dict[str, object]]:
        seven = [row for row in rows if row["requested_model"] == MODEL_NAMES[-1]]
        ordered = sorted(
            seven,
            key=lambda row: Decimal(str(row["absolute_error"])),
            reverse=True,
        )
        return ordered[:12]

    def _replay(
        self,
        datasets: tuple[HistoricalDemandDataset, ...],
        history: DenseHistory,
    ) -> dict[str, object]:
        dataset_by_sku = {dataset.product.sku: dataset for dataset in datasets}
        representatives = (
            "SIM-SUM-001",
            "SIM-RAIN-006",
            "SIM-NEU-002",
            "SIM-RAIN-007",
        )
        model = _models()["product_specific_seasonal_lightgbm"]
        rows: list[dict[str, object]] = []
        start = date(2026, 3, 31)
        for sku in representatives:
            dataset = dataset_by_sku[sku]
            product = next(value for value in PRODUCTS if value.sku == sku)
            previous_forecast: Decimal | None = None
            previous_absolute_error: Decimal | None = None
            for period in range(10):
                origin = start + timedelta(days=period * 7)
                training = bounded_dataset(
                    dataset, origin, max_history_days=MAX_HISTORY_DAYS
                )
                if any(value.business_date > origin for value in training.observations):
                    raise AssertionError("future sales leaked into replay training")
                forecasts = model.forecast(training, horizon_days=7)
                forecast_total = sum(
                    (value.quantity for value in forecasts), Decimal("0")
                )
                actual_total = sum(
                    (
                        history.quantities[(origin + timedelta(days=offset), product.product_id)]
                        for offset in range(1, 8)
                    ),
                    Decimal("0"),
                )
                signed_error = forecast_total - actual_total
                absolute_error = abs(signed_error)
                rows.append(
                    {
                        "sku": sku,
                        "product_name": product.product_name,
                        "seasonal_group": product.seasonal_group,
                        "demand_pattern": product.demand_pattern,
                        "period": period + 1,
                        "origin": origin,
                        "training_end": training.history_end,
                        "forecast_start": origin + timedelta(days=1),
                        "forecast_end": origin + timedelta(days=7),
                        "forecast_total": forecast_total,
                        "actual_total": actual_total,
                        "signed_error_predicted_minus_actual": signed_error,
                        "absolute_error": absolute_error,
                        "forecast_change_from_previous_period": (
                            None
                            if previous_forecast is None
                            else forecast_total - previous_forecast
                        ),
                        "absolute_error_change_from_previous_period": (
                            None
                            if previous_absolute_error is None
                            else absolute_error - previous_absolute_error
                        ),
                        "explicit_error_correction_applied": False,
                    }
                )
                previous_forecast = forecast_total
                previous_absolute_error = absolute_error
        real_overpredictions = [
            row
            for row in rows
            if Decimal(str(row["signed_error_predicted_minus_actual"])) > 0
        ]
        largest = max(
            real_overpredictions,
            key=lambda row: Decimal(str(row["signed_error_predicted_minus_actual"])),
            default=None,
        )
        improved = sum(
            Decimal(str(row["absolute_error_change_from_previous_period"])) < 0
            for row in rows
            if row["absolute_error_change_from_previous_period"] is not None
        )
        worsened = sum(
            Decimal(str(row["absolute_error_change_from_previous_period"])) > 0
            for row in rows
            if row["absolute_error_change_from_previous_period"] is not None
        )
        return {
            "rows": rows,
            "representative_skus": list(representatives),
            "periods_per_product": 10,
            "largest_observed_overprediction": largest,
            "period_to_period_absolute_error_improved": improved,
            "period_to_period_absolute_error_worsened": worsened,
            "interpretation": (
                "Each next forecast is refit with seven newly revealed sales days. "
                "No previous error is subtracted and no residual calibration exists."
            ),
        }

    def _stage23_comparison(self, metrics: dict[str, object]) -> dict[str, object]:
        current = metrics["28"]["overall_mixed_unit_diagnostic"]  # type: ignore[index]
        previous = self.stage23_report["final_test"][  # type: ignore[index]
            "overall_mixed_unit_diagnostic"
        ]
        mapping = {
            "existing_lightgbm": "existing_lightgbm",
            "matched_nonseasonal_ablation": "ablation_conservative",
            "product_specific_seasonal_lightgbm": "seasonal_conservative",
        }
        return {
            name: {
                "stage26_wape": current[name]["wape"],
                "stage23_wape": previous[old_name]["wape"],
                "difference": current[name]["wape"]
                - Decimal(str(previous[old_name]["wape"])),
            }
            for name, old_name in mapping.items()
        }

    @staticmethod
    def _model_recommendation(metrics: dict[str, object]) -> dict[str, object]:
        overall = metrics["28"]["overall_mixed_unit_diagnostic"]  # type: ignore[index]
        seasonal = overall["product_specific_seasonal_lightgbm"]["wape"]
        ablation = overall["matched_nonseasonal_ablation"]["wape"]
        existing = overall["existing_lightgbm"]["wape"]
        decision = (
            "ACCEPT"
            if seasonal < ablation and seasonal < existing
            else "REVISE"
            if seasonal < existing
            else "REJECT"
        )
        return {
            "decision": decision,
            "seasonal_wape_gain_vs_ablation": ablation - seasonal,
            "seasonal_wape_gain_vs_existing_lightgbm": existing - seasonal,
            "note": "This is synthetic validation only and cannot prove real-store accuracy.",
        }

    @staticmethod
    def _seasonal_assessment(metrics: dict[str, object]) -> dict[str, object]:
        pretransition = metrics["28"]["pretransition_anticipation"]  # type: ignore[index]
        seasonal = pretransition["product_specific_seasonal_lightgbm"]
        ablation = pretransition["matched_nonseasonal_ablation"]
        gains = {
            transition: ablation[transition]["wape"] - values["wape"]
            for transition, values in seasonal.items()
        }
        return {
            "pretransition_wape_gains_vs_ablation": gains,
            "all_pretransition_directions_improve": all(
                value >= 0 for value in gains.values()
            ),
            "labels_independently_discovered": False,
            "numerical_seasonal_multiplier_applied": False,
        }


def jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    return value


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    key: (
                        value.isoformat()
                        if isinstance(value, date)
                        else str(value)
                        if isinstance(value, Decimal)
                        else value
                    )
                    for key, value in row.items()
                }
            )


def metric_rows(report: dict[str, object], grouping: str) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for horizon, values in report["metrics"].items():  # type: ignore[union-attr]
        grouped = values[grouping]
        for first, nested in grouped.items():
            if nested and "observations" in nested:
                rows.append(
                    {"horizon_days": horizon, "group": first, **nested}
                )
                continue
            for second, metrics in nested.items():
                rows.append(
                    {
                        "horizon_days": horizon,
                        "group": first,
                        "model_or_subgroup": second,
                        **metrics,
                    }
                )
    return rows

