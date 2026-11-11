from __future__ import annotations

import unittest
from datetime import date

from app.forecasting import (
    LightGBMConfig,
    LightGBMForecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.simulation.expanded_seasonal_fixture import (
    PRODUCTS,
    bounded_dataset,
    expanded_datasets,
    shared_context_registry,
)


class ProductSpecificSeasonalLightGBMTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = shared_context_registry()
        cls.datasets = tuple(
            bounded_dataset(value, date(2026, 4, 20), max_history_days=365)
            for value in expanded_datasets()
        )
        cls.config = LightGBMConfig(
            min_history_days=84,
            min_training_rows=40,
            n_estimators=12,
            learning_rate=0.06,
            num_leaves=10,
            random_seed=26061110,
        )

    def test_ablation_uses_exact_production_feature_vector(self) -> None:
        model = ProductSpecificSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=False,
            config=self.config,
        )
        values = [float(index % 5) for index in range(80)]
        target_date = date(2026, 4, 21)
        context = self.registry.require(PRODUCTS[0].product_id)
        actual = model._feature_row(
            values=values,
            index=len(values),
            target_date=target_date,
            location_id=PRODUCTS[0].forecast_product.location_id,
            context=context,
        )
        expected = LightGBMForecaster._feature_row(
            values,
            len(values),
            target_date,
        )
        self.assertEqual(actual, expected)

    def test_seasonal_features_resolve_each_target_date(self) -> None:
        model = ProductSpecificSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=True,
            config=self.config,
        )
        values = [float(index % 5) for index in range(80)]
        context = self.registry.require(PRODUCTS[0].product_id)
        april = model._feature_row(
            values=values,
            index=len(values),
            target_date=date(2026, 4, 30),
            location_id=PRODUCTS[0].forecast_product.location_id,
            context=context,
        )
        may = model._feature_row(
            values=values,
            index=len(values),
            target_date=date(2026, 5, 1),
            location_id=PRODUCTS[0].forecast_product.location_id,
            context=context,
        )
        self.assertGreater(len(april), len(LightGBMForecaster._feature_row(values, 80, date(2026, 4, 30))))
        self.assertNotEqual(april, may)

    def test_never_sold_gate_does_not_suppress_intermittent_products(self) -> None:
        model = ProductSpecificSeasonalLightGBMForecaster(
            registry=self.registry,
            include_seasonal_features=True,
            config=self.config,
        )
        forecasts = model.forecast_many(self.datasets, horizon_days=3)
        by_id: dict[str, list] = {}
        for forecast in forecasts:
            by_id.setdefault(forecast.product_id, []).append(forecast)
        never_sold = next(value for value in PRODUCTS if value.demand_pattern == "no_sales")
        intermittent = next(value for value in PRODUCTS if value.demand_pattern == "intermittent")
        self.assertTrue(all(value.quantity == 0 for value in by_id[never_sold.product_id]))
        self.assertTrue(
            any(
                warning.startswith("never_sold_zero_forecast_gate:")
                for warning in by_id[never_sold.product_id][0].metadata.data_quality.warnings
            )
        )
        self.assertFalse(
            any(
                warning.startswith("never_sold_zero_forecast_gate:")
                for warning in by_id[intermittent.product_id][0].metadata.data_quality.warnings
            )
        )


if __name__ == "__main__":
    unittest.main()
