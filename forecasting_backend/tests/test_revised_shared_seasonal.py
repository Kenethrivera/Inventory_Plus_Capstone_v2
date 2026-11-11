from __future__ import annotations

import unittest
from datetime import date

from app.forecasting import (
    RelatedActivitySeasonalLightGBMForecaster,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
)
from app.simulation.expanded_seasonal_fixture import (
    PRODUCTS,
    bounded_dataset,
    expanded_datasets,
    shared_context_registry,
)


class RevisedSharedSeasonalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = shared_context_registry()
        cls.datasets = tuple(
            bounded_dataset(value, date(2026, 3, 31), max_history_days=365)
            for value in expanded_datasets()
        )
        cls.config = SharedSeasonalLightGBMConfig(
            n_estimators=12,
            learning_rate=0.06,
            num_leaves=12,
            max_depth=5,
            min_child_samples=20,
        )

    def test_registry_subset_is_closed_and_versioned(self) -> None:
        product_ids = tuple(value.product_id for value in PRODUCTS[:8])
        subset = self.registry.subset(product_ids, version_suffix="test-pool")
        self.assertEqual(set(subset.product_ids), set(product_ids))
        self.assertTrue(subset.version.endswith("+test-pool"))
        with self.assertRaisesRegex(ValueError, "no shared product context"):
            subset.require(PRODUCTS[8].product_id)

    def test_never_sold_is_zero_but_intermittent_is_not_gated(self) -> None:
        forecasts = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            config=self.config,
        ).forecast_many(self.datasets, horizon_days=3)
        by_id: dict[str, list] = {}
        for forecast in forecasts:
            by_id.setdefault(forecast.product_id, []).append(forecast)

        never_sold = next(value for value in PRODUCTS if value.demand_pattern == "no_sales")
        intermittent = next(
            value for value in PRODUCTS if value.demand_pattern == "intermittent"
        )
        self.assertTrue(
            all(value.quantity == 0 for value in by_id[never_sold.product_id])
        )
        self.assertTrue(
            any(
                warning.startswith("never_sold_zero_forecast_gate:")
                for warning in by_id[never_sold.product_id][0]
                .metadata.data_quality.warnings
            )
        )
        self.assertFalse(
            any(
                warning.startswith("never_sold_zero_forecast_gate:")
                for warning in by_id[intermittent.product_id][0]
                .metadata.data_quality.warnings
            )
        )

    def test_related_activity_pool_is_deterministic_and_complete(self) -> None:
        model = RelatedActivitySeasonalLightGBMForecaster(
            registry=self.registry,
            config=self.config,
        )
        first = model.forecast_many(self.datasets, horizon_days=2)
        second = model.forecast_many(self.datasets, horizon_days=2)
        self.assertEqual(first, second)
        self.assertEqual(len(first), len(PRODUCTS) * 2)
        self.assertEqual({value.product_id for value in first}, set(self.registry.product_ids))
        self.assertTrue(
            all(value.metadata.model_name == model.model_name for value in first)
        )
        self.assertTrue(
            all(
                any(
                    warning.startswith("controlled_pool:industry_activity_group:")
                    for warning in value.metadata.data_quality.warnings
                )
                for value in first
            )
        )


if __name__ == "__main__":
    unittest.main()
