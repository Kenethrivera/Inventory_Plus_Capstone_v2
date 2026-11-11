from __future__ import annotations

import unittest
from collections import Counter
from datetime import date
from decimal import Decimal

from app.simulation.expanded_seasonal_backtest import (
    expanded_dataset_signal_audit,
    original_dataset_signal_audit,
)
from app.simulation.expanded_seasonal_fixture import (
    HISTORY_END,
    HISTORY_START,
    PRODUCTS,
    assumptions_sha256,
    expanded_datasets,
    shared_context_registry,
    simulated_quantity,
)


class ExpandedSeasonalFixtureTests(unittest.TestCase):
    def test_manifest_is_frozen_four_year_balanced_catalog(self) -> None:
        self.assertEqual((HISTORY_END - HISTORY_START).days + 1, 1461)
        self.assertEqual(len(PRODUCTS), 24)
        self.assertEqual(
            Counter(value.seasonal_group for value in PRODUCTS),
            {"SUMMER": 8, "RAINY": 8, "NEUTRAL": 8},
        )
        self.assertEqual(len({value.product_id for value in PRODUCTS}), 24)
        self.assertEqual(len({value.sku for value in PRODUCTS}), 24)
        self.assertEqual(len(assumptions_sha256()), 64)

    def test_generator_is_deterministic_and_preserves_no_sales_control(self) -> None:
        target = date(2026, 5, 1)
        first = [simulated_quantity(value, target) for value in PRODUCTS]
        second = [simulated_quantity(value, target) for value in PRODUCTS]
        self.assertEqual(first, second)
        control = next(value for value in PRODUCTS if value.sku == "SIM-NEU-008")
        self.assertEqual(simulated_quantity(control, target), Decimal("0"))

    def test_dataset_and_context_registry_cover_exact_same_products(self) -> None:
        datasets = expanded_datasets()
        registry = shared_context_registry()
        self.assertEqual(len(datasets), 24)
        registry.validate_datasets(datasets)
        self.assertTrue(all(value.history_start == HISTORY_START for value in datasets))
        self.assertTrue(all(value.history_end == HISTORY_END for value in datasets))

    def test_signal_qualification_precedes_model_evaluation(self) -> None:
        expanded = expanded_dataset_signal_audit()
        self.assertGreaterEqual(expanded["by_group"]["SUMMER"]["meaningful_signals"], 6)
        self.assertGreaterEqual(expanded["by_group"]["RAINY"]["meaningful_signals"], 5)
        self.assertEqual(expanded["by_group"]["NEUTRAL"]["meaningful_signals"], 0)
        original = original_dataset_signal_audit()
        self.assertEqual(original["products_with_explicit_month_effect"], 4)


if __name__ == "__main__":
    unittest.main()
