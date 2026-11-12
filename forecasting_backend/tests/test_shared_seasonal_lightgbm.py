from __future__ import annotations

import unittest
from datetime import date

from app.data.validation import DemandDataError
from app.forecasting import (
    SharedProductContextRegistry,
    SharedSeasonalLightGBMConfig,
    SharedSeasonalLightGBMForecaster,
)
from app.simulation.full_inventory_fixture import (
    PRODUCTS,
    bounded_dataset,
    full_inventory_datasets,
)


class SharedSeasonalLightGBMTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = SharedProductContextRegistry.from_catalog(PRODUCTS)
        cls.config = SharedSeasonalLightGBMConfig(
            n_estimators=20,
            learning_rate=0.06,
            num_leaves=12,
            max_depth=5,
            min_child_samples=20,
        )

    def test_context_registry_covers_catalog_with_versioned_classification(self) -> None:
        self.assertEqual(len(self.registry.contexts), 13)
        self.assertIn("hardware-seasonal-knowledge-v2", self.registry.version)
        concrete = self.registry.require(
            "22222222-2222-2222-2222-222222222222"
        )
        self.assertEqual(concrete.product_type, "concrete_nails")
        self.assertEqual(concrete.seasonal_relevance, "dry")
        self.assertNotEqual(concrete.evidence_level, "verified_record")

    def test_pooled_candidate_is_deterministic_and_future_only(self) -> None:
        origin = date(2026, 10, 10)
        datasets = tuple(
            bounded_dataset(value, origin, max_history_days=365)
            for value in full_inventory_datasets()
        )
        model = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            config=self.config,
        )
        first = model.forecast_many(datasets, horizon_days=7)
        second = model.forecast_many(datasets, horizon_days=7)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 13 * 7)
        self.assertTrue(all(value.forecast_date > origin for value in first))
        self.assertTrue(all(value.quantity >= 0 for value in first))
        self.assertTrue(
            all(
                value.metadata.model_name
                == "shared_seasonal_lightgbm_experimental"
                for value in first
            )
        )
        self.assertIn(
            "experimental_shared_candidate_not_active_for_normal_application",
            first[0].metadata.data_quality.warnings,
        )

    def test_nonseasonal_ablation_uses_same_pool_without_seasonal_features(self) -> None:
        origin = date(2026, 10, 10)
        datasets = tuple(
            bounded_dataset(value, origin, max_history_days=365)
            for value in full_inventory_datasets()
        )
        model = SharedSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=False,
            config=self.config,
        )
        forecasts = model.forecast_many(datasets, horizon_days=3)
        self.assertEqual(len(forecasts), 39)
        self.assertTrue(
            all(
                value.metadata.model_name
                == "shared_lightgbm_nonseasonal_ablation_experimental"
                for value in forecasts
            )
        )
        self.assertIn(
            "seasonal_features_removed_for_ablation",
            forecasts[0].metadata.data_quality.warnings,
        )

    def test_single_series_entrypoint_is_intentionally_unavailable(self) -> None:
        model = SharedSeasonalLightGBMForecaster(registry=self.registry)
        with self.assertRaisesRegex(DemandDataError, "requires forecast_many"):
            model.forecast(full_inventory_datasets()[0], horizon_days=1)


if __name__ == "__main__":
    unittest.main()
