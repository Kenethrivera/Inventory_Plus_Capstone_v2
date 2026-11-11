from __future__ import annotations

import unittest
from datetime import date, timedelta
from decimal import Decimal

from app.data.models import DailyDemand
from app.forecasting import (
    AvailabilityEvidence,
    AvailabilityStatus,
    BacktestPoint,
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    ColdStartReason,
    DataProvenance,
    ForecastProduct,
    HistoricalDemandDataset,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    RollingOriginBacktester,
    RollingOriginConfig,
    learn_multiplicative_bias,
    mean_absolute_error,
)


LOCATION = "11111111-1111-4111-8111-111111111111"
PRODUCT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
START = date(2025, 1, 1)


def fixture_product() -> ForecastProduct:
    return ForecastProduct(
        location_id=LOCATION,
        product_id=PRODUCT,
        sku="SYNTH-001",
        product_name="Synthetic test fixture",
        unit="pcs",
    )


def synthetic_quantity(index: int) -> Decimal:
    return Decimal(8 + (index % 7) * 2 + index // 56)


def synthetic_dataset(
    days: int,
    *,
    stockout_indexes: set[int] | None = None,
) -> HistoricalDemandDataset:
    stockouts = stockout_indexes or set()
    observations: list[DailyDemand] = []
    availability: list[AvailabilityEvidence] = []
    for index in range(days):
        business_date = START + timedelta(days=index)
        is_stockout = index in stockouts
        availability.append(
            AvailabilityEvidence(
                business_date=business_date,
                status=(
                    AvailabilityStatus.STOCKOUT
                    if is_stockout
                    else AvailabilityStatus.IN_STOCK
                ),
            )
        )
        if is_stockout:
            continue
        observations.append(
            DailyDemand(
                business_date=business_date,
                location_id=LOCATION,
                product_id=PRODUCT,
                sku="SYNTH-001",
                product_name="Synthetic test fixture",
                unit="pcs",
                quantity=synthetic_quantity(index),
                completed_order_count=1,
            )
        )
    return HistoricalDemandDataset.from_synthetic_observations(
        product=fixture_product(),
        history_start=START,
        history_end=START + timedelta(days=days - 1),
        observations=observations,
        availability_evidence=availability,
    )


def fast_lightgbm() -> LightGBMForecaster:
    return LightGBMForecaster(
        config=LightGBMConfig(
            min_history_days=84,
            min_training_rows=40,
            n_estimators=30,
            learning_rate=0.08,
            num_leaves=12,
            random_seed=2505,
        )
    )


class _UnavailableLightGBM(LightGBMForecaster):
    def _new_regressor(self) -> object:
        raise ImportError("controlled unavailable dependency")


class _InvalidRegressor:
    def fit(self, features: object, targets: object) -> None:
        return None

    def predict(self, features: object) -> list[float]:
        return [float("nan")]


class _InvalidLightGBM(LightGBMForecaster):
    def _new_regressor(self) -> object:
        return _InvalidRegressor()


class LightGBMForecastTests(unittest.TestCase):
    def test_lightgbm_returns_28_structured_nonnegative_forecasts(self) -> None:
        values = fast_lightgbm().forecast(synthetic_dataset(168), horizon_days=28)
        self.assertEqual(len(values), 28)
        self.assertTrue(all(value.quantity.is_finite() for value in values))
        self.assertTrue(all(value.quantity >= 0 for value in values))
        self.assertTrue(all(value.location_id == LOCATION for value in values))
        self.assertTrue(all(value.product_id == PRODUCT for value in values))
        metadata = values[0].metadata
        self.assertEqual(metadata.model_name, "lightgbm")
        self.assertEqual(metadata.model_version, "1")
        self.assertEqual(metadata.forecast_horizon_days, 28)
        self.assertEqual(metadata.data_provenance, DataProvenance.SYNTHETIC)
        self.assertIn(
            "model_trained_only_on_current_product_location_history",
            metadata.data_quality.warnings,
        )

    def test_lightgbm_is_reproducible_for_controlled_history(self) -> None:
        source = synthetic_dataset(112)
        first = fast_lightgbm().forecast(source, horizon_days=7)
        second = fast_lightgbm().forecast(source, horizon_days=7)
        self.assertEqual(first, second)

    def test_insufficient_training_falls_back_to_mean28(self) -> None:
        source = synthetic_dataset(28)
        expected = Mean28Forecaster().forecast(source, horizon_days=2)
        actual = fast_lightgbm().forecast(source, horizon_days=2)
        self.assertEqual(
            [value.quantity for value in actual],
            [value.quantity for value in expected],
        )
        self.assertEqual(actual[0].metadata.model_name, "mean28_fallback")
        self.assertEqual(
            actual[0].metadata.fallback_reason, "insufficient_training_history"
        )

    def test_unavailable_lightgbm_falls_back_without_losing_cold_start_warning(self) -> None:
        configured = _UnavailableLightGBM(
            config=LightGBMConfig(
                min_history_days=29,
                min_training_rows=1,
                n_estimators=1,
            )
        )
        source = synthetic_dataset(29)
        actual = configured.forecast(source, horizon_days=1)[0]
        self.assertEqual(actual.metadata.model_name, "mean28_fallback")
        self.assertEqual(actual.metadata.fallback_reason, "lightgbm_unavailable")

        no_history = HistoricalDemandDataset.from_synthetic_observations(
            product=fixture_product(),
            history_start=None,
            history_end=START,
            observations=[],
        )
        cold = configured.forecast(no_history, horizon_days=1)[0]
        self.assertEqual(cold.metadata.cold_start_reason, ColdStartReason.NO_HISTORY)
        self.assertIn(
            "cold_start_zero_is_not_confirmed_customer_demand",
            cold.metadata.data_quality.warnings,
        )

    def test_stockout_days_are_censored_not_silent_zero_targets(self) -> None:
        source = synthetic_dataset(120, stockout_indexes={100})
        mean = Mean28Forecaster().forecast(source, horizon_days=1)[0]
        ml = fast_lightgbm().forecast(source, horizon_days=1)[0]
        self.assertEqual(mean.metadata.data_quality.stockout_censored_days, 1)
        expected_mean = sum(
            (synthetic_quantity(index) for index in range(92, 120) if index != 100),
            Decimal("0"),
        ) / Decimal("27")
        self.assertEqual(mean.quantity, expected_mean)
        self.assertEqual(ml.metadata.data_quality.stockout_censored_days, 1)
        self.assertIn(
            "stockout_censored_targets_excluded",
            ml.metadata.data_quality.warnings,
        )
        self.assertEqual(ml.metadata.sample_days_used, 91)

    def test_invalid_model_prediction_falls_back_to_mean28(self) -> None:
        configured = _InvalidLightGBM(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=1,
            )
        )
        result = configured.forecast(synthetic_dataset(112), horizon_days=1)[0]
        self.assertEqual(result.metadata.model_name, "mean28_fallback")
        self.assertEqual(
            result.metadata.fallback_reason,
            "lightgbm_training_or_validation_failed",
        )


class BacktestingAndBlendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lightgbm = fast_lightgbm()
        self.mean28 = Mean28Forecaster()

    def test_rolling_origins_are_strictly_chronological(self) -> None:
        report = RollingOriginBacktester(
            lightgbm=self.lightgbm, mean28=self.mean28
        ).run(
            synthetic_dataset(196),
            config=RollingOriginConfig(
                initial_training_days=112,
                horizon_days=28,
                step_days=28,
            ),
        )
        self.assertEqual(len(report.folds), 3)
        for fold in report.folds:
            self.assertLess(fold.training_end, fold.validation_start)
            self.assertEqual(
                fold.validation_start, fold.training_end + timedelta(days=1)
            )
            self.assertTrue(
                all(point.forecast_date > fold.training_end for point in fold.points)
            )

    def test_multiplicative_calibration_uses_50_50_raw_blend(self) -> None:
        points = [
            BacktestPoint(
                origin_date=START,
                forecast_date=START + timedelta(days=index + 1),
                actual_quantity=Decimal("12"),
                lightgbm_quantity=Decimal("8"),
                mean28_quantity=Decimal("4"),
                lightgbm_used=True,
                is_stockout_censored=False,
            )
            for index in range(28)
        ]
        calibration = learn_multiplicative_bias(
            points, config=CalibratedBlendConfig()
        )
        self.assertIsNotNone(calibration)
        assert calibration is not None
        self.assertEqual(calibration.factor, Decimal("2"))
        self.assertEqual(calibration.points_used, 28)
        self.assertFalse(calibration.was_clipped)

    def test_calibrated_blend_has_expected_contract_and_controlled_holdout(self) -> None:
        complete = synthetic_dataset(252)
        training = HistoricalDemandDataset.from_synthetic_observations(
            product=complete.product,
            history_start=complete.history_start,
            history_end=START + timedelta(days=223),
            observations=[
                value
                for value in complete.observations
                if value.business_date <= START + timedelta(days=223)
            ],
            availability_evidence=[
                value
                for value in complete.availability_evidence
                if value.business_date <= START + timedelta(days=223)
            ],
        )
        config = CalibratedBlendConfig(
            minimum_calibration_points=56,
            rolling_origin=RollingOriginConfig(
                initial_training_days=112,
                horizon_days=28,
                step_days=28,
            ),
        )
        candidate = CalibratedBlendForecaster(
            config=config, lightgbm=self.lightgbm, mean28=self.mean28
        )
        predictions = candidate.forecast(training, horizon_days=28)
        actual = [synthetic_quantity(index) for index in range(224, 252)]
        predicted = [value.quantity for value in predictions]
        error = mean_absolute_error(actual, predicted)
        self.assertEqual(len(predictions), 28)
        self.assertEqual(
            predictions[0].metadata.model_name,
            "calibrated_lightgbm_mean28_blend",
        )
        self.assertEqual(predictions[0].metadata.calibration_points, 112)
        self.assertEqual(
            [component.weight for component in predictions[0].metadata.components],
            [Decimal("0.5"), Decimal("0.5")],
        )
        self.assertLess(error, Decimal("6"))
        self.assertIn(
            "synthetic_evaluation_does_not_establish_real_store_accuracy",
            predictions[0].metadata.data_quality.warnings,
        )

    def test_blend_falls_back_when_calibration_history_is_insufficient(self) -> None:
        source = synthetic_dataset(100)
        candidate = CalibratedBlendForecaster(
            config=CalibratedBlendConfig(
                rolling_origin=RollingOriginConfig(
                    initial_training_days=112,
                    horizon_days=28,
                    step_days=28,
                )
            ),
            lightgbm=self.lightgbm,
            mean28=self.mean28,
        )
        value = candidate.forecast(source, horizon_days=1)[0]
        self.assertEqual(value.metadata.model_name, "mean28_fallback")
        self.assertEqual(
            value.metadata.fallback_reason, "insufficient_calibration_history"
        )


if __name__ == "__main__":
    unittest.main()
