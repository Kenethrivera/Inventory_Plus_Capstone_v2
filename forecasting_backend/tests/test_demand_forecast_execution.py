from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from typing import Any

from app.forecasting import (
    DataProvenance,
    ForecastProduct,
    HistoricalDemandDataset,
    Mean28Forecaster,
)
from app.forecasting.execution import (
    DemandForecastExecutionInput,
    DemandForecastExecutor,
)


LOCATION_ID = "11111111-1111-4111-8111-111111111111"
PRODUCT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
AS_OF = datetime(2026, 11, 13, 8, tzinfo=timezone.utc)
SOURCE_AS_OF = datetime(2026, 11, 13, 0, tzinfo=timezone(timedelta(hours=8)))


def frozen_history(*, days: int = 180) -> HistoricalDemandDataset:
    product = ForecastProduct(
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        product_name="Frozen execution fixture",
        unit="pcs",
        sku="FIXTURE-1",
    )
    end = date(2026, 11, 12)
    return HistoricalDemandDataset(
        product=product,
        history_start=end - timedelta(days=days - 1),
        history_end=end,
        observations=(),
        provenance=DataProvenance.REAL,
    )


class _RecordingForecaster:
    def __init__(self, model_name: str, *, result_name: str | None = None) -> None:
        self.model_name = model_name
        self.result_name = result_name or model_name
        self.calls: list[tuple[HistoricalDemandDataset, int]] = []

    def forecast(
        self, dataset: HistoricalDemandDataset, *, horizon_days: int
    ) -> list[Any]:
        self.calls.append((dataset, horizon_days))
        values = Mean28Forecaster().forecast(dataset, horizon_days=horizon_days)
        return [
            replace(
                value,
                metadata=replace(
                    value.metadata,
                    model_name=self.result_name,
                    fallback_reason=(
                        "controlled_fallback"
                        if self.result_name == "mean28_fallback"
                        else None
                    ),
                ),
            )
            for value in values
        ]


class DemandForecastExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mean28 = _RecordingForecaster("mean28")
        self.lightgbm = _RecordingForecaster("lightgbm")
        self.blend = _RecordingForecaster("blend")
        self.seasonal = _RecordingForecaster(
            "product_specific_seasonal_lightgbm_experimental"
        )
        self.executor = DemandForecastExecutor(
            mean28=self.mean28,  # type: ignore[arg-type]
            lightgbm=self.lightgbm,  # type: ignore[arg-type]
            blend=self.blend,  # type: ignore[arg-type]
            seasonal_experimental=self.seasonal,  # type: ignore[arg-type]
        )
        self.history = frozen_history()

    def execute(self, model: str, horizon: int) -> Any:
        return self.executor.execute(
            DemandForecastExecutionInput(
                history=self.history,
                model=model,
                horizon_days=horizon,
                as_of=AS_OF,
                source_data_as_of=SOURCE_AS_OF,
                preliminary_horizon_days=28,
            )
        )

    def test_mean28_keeps_separate_preliminary_lightgbm_output(self) -> None:
        expected_requested = tuple(self.mean28.forecast(self.history, horizon_days=7))
        expected_preliminary = tuple(
            self.lightgbm.forecast(self.history, horizon_days=28)
        )
        self.mean28.calls.clear()
        self.lightgbm.calls.clear()

        result = self.execute("mean28", 7)

        self.assertEqual(self.mean28.calls, [(self.history, 7)])
        self.assertEqual(self.lightgbm.calls, [(self.history, 28)])
        self.assertEqual(result.requested_forecasts, expected_requested)
        self.assertEqual(result.recommendation_forecasts, result.requested_forecasts)
        self.assertEqual(result.preliminary_forecasts, expected_preliminary)
        self.assertEqual(result.as_of, AS_OF)
        self.assertEqual(result.source_data_as_of, SOURCE_AS_OF)

    def test_lightgbm_28_day_output_is_reused_for_both_auxiliary_paths(self) -> None:
        expected = tuple(self.lightgbm.forecast(self.history, horizon_days=28))
        self.lightgbm.calls.clear()

        result = self.execute("lightgbm", 28)

        self.assertEqual(self.lightgbm.calls, [(self.history, 28)])
        self.assertEqual(result.requested_forecasts, expected)
        self.assertEqual(result.recommendation_forecasts, expected)
        self.assertEqual(result.preliminary_forecasts, expected)

    def test_blend_keeps_requested_output_and_lightgbm_preliminary_output(self) -> None:
        expected_requested = tuple(self.blend.forecast(self.history, horizon_days=7))
        expected_preliminary = tuple(
            self.lightgbm.forecast(self.history, horizon_days=28)
        )
        self.blend.calls.clear()
        self.lightgbm.calls.clear()

        result = self.execute("blend", 7)

        self.assertEqual(self.blend.calls, [(self.history, 7)])
        self.assertEqual(self.lightgbm.calls, [(self.history, 28)])
        self.assertEqual(result.requested_forecasts, expected_requested)
        self.assertEqual(result.preliminary_forecasts, expected_preliminary)

    def test_seasonal_success_uses_bounded_lightgbm_recommendation_history(self) -> None:
        self.history = frozen_history(days=500)
        expected_requested = tuple(
            self.seasonal.forecast(self.history, horizon_days=28)
        )
        bounded_history = self._legacy_bounded_history(self.history, 365)
        expected_recommendation = tuple(
            self.lightgbm.forecast(bounded_history, horizon_days=28)
        )
        self.seasonal.calls.clear()
        self.lightgbm.calls.clear()

        result = self.execute("seasonal_experimental", 28)

        self.assertEqual(self.seasonal.calls, [(self.history, 28)])
        self.assertEqual(result.requested_forecasts, expected_requested)
        self.assertEqual(bounded_history.history_end, self.history.history_end)
        self.assertEqual(
            bounded_history.history_start,
            self.history.history_end - timedelta(days=364),
        )
        self.assertEqual(self.lightgbm.calls, [(bounded_history, 28)])
        self.assertEqual(result.recommendation_forecasts, expected_recommendation)
        self.assertEqual(result.recommendation_forecasts, result.preliminary_forecasts)
        self.assertIsNone(result.experimental_fallback_reason)

    def test_seasonal_fallback_preserves_existing_lightgbm_auxiliary_calls(self) -> None:
        self.seasonal.result_name = "mean28_fallback"
        self.history = frozen_history(days=500)
        expected_candidate = tuple(
            self.seasonal.forecast(self.history, horizon_days=7)
        )
        bounded_history = self._legacy_bounded_history(self.history, 365)
        expected_requested = tuple(
            self.lightgbm.forecast(bounded_history, horizon_days=7)
        )
        expected_recommendation = tuple(
            self.lightgbm.forecast(bounded_history, horizon_days=7)
        )
        expected_preliminary = tuple(
            self.lightgbm.forecast(bounded_history, horizon_days=28)
        )
        self.seasonal.calls.clear()
        self.lightgbm.calls.clear()

        result = self.execute("seasonal_experimental", 7)

        self.assertEqual(
            self.lightgbm.calls,
            [
                (bounded_history, 7),
                (bounded_history, 7),
                (bounded_history, 28),
            ],
        )
        self.assertEqual(
            result.experimental_fallback_reason, "controlled_fallback"
        )
        self.assertEqual(result.requested_forecasts, expected_requested)
        self.assertEqual(result.recommendation_forecasts, expected_recommendation)
        self.assertEqual(result.preliminary_forecasts, expected_preliminary)
        self.assertNotEqual(result.requested_forecasts, expected_candidate)

    @staticmethod
    def _legacy_bounded_history(
        history: HistoricalDemandDataset, history_days: int
    ) -> HistoricalDemandDataset:
        if history.history_start is None:
            return history
        start = max(
            history.history_start,
            history.history_end - timedelta(days=history_days - 1),
        )
        return replace(
            history,
            history_start=start,
            observations=tuple(
                value
                for value in history.observations
                if start <= value.business_date <= history.history_end
            ),
            availability_evidence=tuple(
                value
                for value in history.availability_evidence
                if start <= value.business_date <= history.history_end
            ),
        )


if __name__ == "__main__":
    unittest.main()
