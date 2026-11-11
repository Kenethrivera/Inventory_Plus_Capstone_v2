from __future__ import annotations

import unittest
from datetime import date, timedelta
from decimal import Decimal

from app.data.models import DailyDemand
from app.data.validation import DemandDataError
from app.forecasting import (
    ColdStartReason,
    ColdStartStrategy,
    DataProvenance,
    DatasetRole,
    ForecastProduct,
    HistoricalDemandDataset,
    Mean28Forecaster,
)


LOCATION_A = "11111111-1111-4111-8111-111111111111"
LOCATION_B = "22222222-2222-4222-8222-222222222222"
PRODUCT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
PRODUCT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
END = date(2026, 6, 30)


def product(
    *, location_id: str = LOCATION_A, product_id: str = PRODUCT_A
) -> ForecastProduct:
    return ForecastProduct(
        location_id=location_id,
        product_id=product_id,
        sku="SKU-001",
        product_name="Controlled fixture product",
        unit="pcs",
    )


def demand(
    business_date: date,
    quantity: object,
    *,
    location_id: str = LOCATION_A,
    product_id: str = PRODUCT_A,
) -> DailyDemand:
    number = Decimal(str(quantity))
    return DailyDemand(
        business_date=business_date,
        location_id=location_id,
        product_id=product_id,
        sku="SKU-001",
        product_name="Controlled fixture product",
        unit="pcs",
        quantity=number,
        completed_order_count=0 if number == 0 else 1,
    )


def dataset(
    observations: list[DailyDemand],
    *,
    item: ForecastProduct | None = None,
    history_start: date | None = END - timedelta(days=27),
    history_end: date = END,
    provenance: DataProvenance = DataProvenance.SYNTHETIC,
) -> HistoricalDemandDataset:
    constructor = (
        HistoricalDemandDataset.from_real_observations
        if provenance is DataProvenance.REAL
        else HistoricalDemandDataset.from_synthetic_observations
    )
    return constructor(
        product=item or product(),
        history_start=history_start,
        history_end=history_end,
        observations=observations,
    )


class Mean28ForecasterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.forecaster = Mean28Forecaster()

    def test_mean28_uses_latest_28_calendar_days_and_repeats_baseline(self) -> None:
        observations = [
            demand(END - timedelta(days=offset), offset + 1) for offset in range(28)
        ]
        forecasts = self.forecaster.forecast(
            dataset(observations), horizon_days=3
        )
        self.assertEqual([value.quantity for value in forecasts], [Decimal("14.5")] * 3)
        self.assertEqual(
            [value.forecast_date for value in forecasts],
            [date(2026, 7, 1), date(2026, 7, 2), date(2026, 7, 3)],
        )
        self.assertFalse(forecasts[0].metadata.is_cold_start)
        self.assertEqual(forecasts[0].metadata.sample_days_used, 28)

    def test_older_observations_do_not_change_latest_28_day_mean(self) -> None:
        observations = [demand(END - timedelta(days=40), 1000), demand(END, 28)]
        result = self.forecaster.forecast(
            dataset(observations, history_start=END - timedelta(days=40)),
            horizon_days=1,
        )[0]
        self.assertEqual(result.quantity, Decimal("1"))

    def test_missing_contract_rows_are_zero_demand_calendar_days(self) -> None:
        result = self.forecaster.forecast(
            dataset([demand(END, 28)]), horizon_days=1
        )[0]
        self.assertEqual(result.quantity, Decimal("1"))
        self.assertEqual(result.metadata.nonzero_demand_days, 1)

    def test_partial_history_uses_available_day_mean_and_marks_cold_start(self) -> None:
        result = self.forecaster.forecast(
            dataset(
                [demand(END, 14)], history_start=END - timedelta(days=6)
            ),
            horizon_days=1,
        )[0]
        self.assertEqual(result.quantity, Decimal("2"))
        self.assertTrue(result.metadata.is_cold_start)
        self.assertEqual(
            result.metadata.cold_start_reason,
            ColdStartReason.INSUFFICIENT_HISTORY,
        )
        self.assertEqual(
            result.metadata.cold_start_strategy,
            ColdStartStrategy.AVAILABLE_DAY_MEAN,
        )
        self.assertEqual(result.metadata.history_days_available, 7)

    def test_no_history_product_gets_explicit_zero_cold_start(self) -> None:
        result = self.forecaster.forecast(
            dataset([], history_start=None), horizon_days=1
        )[0]
        self.assertEqual(result.quantity, Decimal("0"))
        self.assertEqual(result.metadata.sample_days_used, 0)
        self.assertEqual(
            result.metadata.cold_start_reason, ColdStartReason.NO_HISTORY
        )
        self.assertEqual(
            result.metadata.cold_start_strategy, ColdStartStrategy.ZERO
        )

    def test_known_28_day_zero_history_is_not_cold_start(self) -> None:
        result = self.forecaster.forecast(dataset([]), horizon_days=1)[0]
        self.assertEqual(result.quantity, Decimal("0"))
        self.assertFalse(result.metadata.is_cold_start)
        self.assertIsNone(result.metadata.cold_start_strategy)

    def test_forecast_many_separates_products_and_locations(self) -> None:
        second_product = product(product_id=PRODUCT_B)
        second_location = product(location_id=LOCATION_B)
        forecasts = self.forecaster.forecast_many(
            [
                dataset([demand(END, 28)]),
                dataset(
                    [demand(END, 56, product_id=PRODUCT_B)], item=second_product
                ),
                dataset(
                    [demand(END, 84, location_id=LOCATION_B)], item=second_location
                ),
            ],
            horizon_days=1,
        )
        by_key = {value.series_key: value.quantity for value in forecasts}
        self.assertEqual(len(by_key), 3)
        self.assertEqual(by_key[product().series_key], Decimal("1"))
        self.assertEqual(by_key[second_product.series_key], Decimal("2"))
        self.assertEqual(by_key[second_location.series_key], Decimal("3"))

    def test_rejects_duplicate_product_location_datasets(self) -> None:
        with self.assertRaises(DemandDataError):
            self.forecaster.forecast_many([dataset([]), dataset([])], horizon_days=1)

    def test_rejects_mixed_real_and_synthetic_forecast_batch(self) -> None:
        with self.assertRaises(DemandDataError):
            self.forecaster.forecast_many(
                [
                    dataset([]),
                    dataset(
                        [],
                        item=product(product_id=PRODUCT_B),
                        provenance=DataProvenance.REAL,
                    ),
                ],
                horizon_days=1,
            )

    def test_rejects_nonfinite_and_negative_history(self) -> None:
        for invalid in (Decimal("NaN"), Decimal("Infinity"), Decimal("-1")):
            with self.subTest(invalid=invalid):
                with self.assertRaises(DemandDataError):
                    self.forecaster.forecast(
                        dataset([demand(END, invalid)]), horizon_days=1
                    )

    def test_rejects_mismatched_product_or_location(self) -> None:
        with self.assertRaises(DemandDataError):
            self.forecaster.forecast(
                dataset([demand(END, 1, product_id=PRODUCT_B)]), horizon_days=1
            )

    def test_metadata_keeps_historical_role_and_synthetic_provenance(self) -> None:
        synthetic = self.forecaster.forecast(dataset([]), horizon_days=1)[0]
        self.assertEqual(synthetic.metadata.dataset_role, DatasetRole.HISTORICAL)
        self.assertEqual(
            synthetic.metadata.data_provenance, DataProvenance.SYNTHETIC
        )
        self.assertEqual(synthetic.metadata.model_name, "mean28")
        self.assertEqual(synthetic.metadata.model_version, "1")

    def test_results_are_reproducible_and_contain_no_runtime_timestamp(self) -> None:
        source = dataset([demand(END, Decimal("2.8"))])
        first = self.forecaster.forecast(source, horizon_days=2)
        second = self.forecaster.forecast(source, horizon_days=2)
        self.assertEqual(first, second)

    def test_rejects_invalid_horizon_and_out_of_bounds_history(self) -> None:
        with self.assertRaises(DemandDataError):
            self.forecaster.forecast(dataset([]), horizon_days=0)
        with self.assertRaises(DemandDataError):
            self.forecaster.forecast(
                dataset([demand(END - timedelta(days=30), 1)]), horizon_days=1
            )


if __name__ == "__main__":
    unittest.main()
