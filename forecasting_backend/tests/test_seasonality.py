from __future__ import annotations

import unittest
from datetime import date, timedelta
from decimal import Decimal

from app.forecasting import LightGBMConfig, SeasonAwareLightGBMForecaster
from app.seasonality import (
    BINAN_LOCATION_ID,
    EvidenceLevel,
    PhilippineSeason,
    PhilippineSeasonResolver,
    ProductSeasonalProfileRegistry,
    SeasonTransition,
)
from app.simulation.full_inventory_fixture import (
    HISTORY_END,
    HISTORY_START,
    PRODUCTS,
    bounded_dataset,
    full_inventory_datasets,
    simulated_quantity,
)


class PhilippineSeasonResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.resolver = PhilippineSeasonResolver()

    def test_type_i_calendar_resolves_core_seasons_and_transitions(self) -> None:
        cases = (
            (date(2026, 4, 30), PhilippineSeason.DRY, SeasonTransition.NONE),
            (
                date(2026, 5, 1),
                PhilippineSeason.TRANSITION,
                SeasonTransition.TO_RAINY,
            ),
            (date(2026, 6, 1), PhilippineSeason.RAINY, SeasonTransition.NONE),
            (
                date(2026, 11, 1),
                PhilippineSeason.TRANSITION,
                SeasonTransition.TO_DRY,
            ),
            (date(2026, 12, 1), PhilippineSeason.DRY, SeasonTransition.NONE),
        )
        for business_date, expected_season, expected_transition in cases:
            with self.subTest(business_date=business_date):
                actual = self.resolver.resolve(BINAN_LOCATION_ID, business_date)
                self.assertEqual(actual.season, expected_season)
                self.assertEqual(actual.transition, expected_transition)
                self.assertEqual(len(actual.feature_vector()), 5)

    def test_forecast_horizon_is_resolved_one_date_at_a_time(self) -> None:
        contexts = [
            self.resolver.resolve(
                BINAN_LOCATION_ID, date(2026, 4, 29) + timedelta(days=offset)
            )
            for offset in range(5)
        ]
        self.assertEqual(
            [value.season for value in contexts],
            [
                PhilippineSeason.DRY,
                PhilippineSeason.DRY,
                PhilippineSeason.TRANSITION,
                PhilippineSeason.TRANSITION,
                PhilippineSeason.TRANSITION,
            ],
        )

    def test_unknown_location_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "no verified climate profile"):
            self.resolver.resolve("unknown-location", date(2026, 7, 1))


class ProductSeasonalRegistryTests(unittest.TestCase):
    def test_registry_exactly_covers_current_thirteen_product_fixture(self) -> None:
        registry = ProductSeasonalProfileRegistry.load_default()
        products = tuple(value.forecast_product for value in PRODUCTS)
        registry.validate_catalog(products)
        self.assertEqual(len(registry.profiles), 13)
        self.assertTrue(
            all(not value.numerical_adjustment_allowed for value in registry.profiles)
        )
        self.assertTrue(all(value.source_ids for value in registry.profiles))

    def test_test_products_remain_unknown_not_fabricated(self) -> None:
        registry = ProductSeasonalProfileRegistry.load_default()
        test_profiles = [
            value for value in registry.profiles if value.sku in {"SKU-4W6D3LVI", "SKU-69QAUJ4Z"}
        ]
        self.assertEqual(len(test_profiles), 2)
        self.assertTrue(
            all(value.evidence_level is EvidenceLevel.UNKNOWN for value in test_profiles)
        )


class FullInventoryFixtureTests(unittest.TestCase):
    def test_fixture_has_exact_676_day_contract_and_known_last_28_totals(self) -> None:
        self.assertEqual((HISTORY_END - HISTORY_START).days + 1, 676)
        expected = {
            "SKU-001": Decimal("189"),
            "SKU-002": Decimal("196"),
            "SKU-1004": Decimal("69"),
            "SKU-1005": Decimal("188"),
            "SKU-1006": Decimal("89"),
            "SKU-1007": Decimal("4"),
            "SKU-1008": Decimal("65"),
            "SKU-1009": Decimal("269"),
            "SKU-1010": Decimal("131"),
            "SKU-3UWPD0GN": Decimal("36"),
            "SKU-K1CB7XQV": Decimal("17"),
        }
        # The verified 2026-11-09 Mean28 window is 2026-10-12 through
        # 2026-11-08. SQL 02 ends on 2026-11-07, so 2026-11-08 is the one
        # explicit zero-sale calendar day in that window.
        start = date(2026, 10, 12)
        by_sku = {value.sku: value for value in PRODUCTS}
        for sku, total in expected.items():
            product = by_sku[sku]
            actual = sum(
                (
                    simulated_quantity(product, start + timedelta(days=offset))
                    for offset in range(27)
                ),
                Decimal("0"),
            )
            self.assertEqual(actual, total, sku)

    def test_bounded_dataset_contains_no_future_observation(self) -> None:
        origin = date(2025, 8, 31)
        source = full_inventory_datasets()[0]
        bounded = bounded_dataset(source, origin)
        self.assertEqual(bounded.history_end, origin)
        self.assertTrue(
            all(value.business_date <= origin for value in bounded.observations)
        )

    def test_bounded_dataset_can_match_deployed_365_day_history_window(self) -> None:
        source = full_inventory_datasets()[0]
        bounded = bounded_dataset(source, HISTORY_END, max_history_days=365)
        self.assertEqual((bounded.history_end - bounded.history_start).days + 1, 365)
        self.assertTrue(
            all(
                bounded.history_start <= value.business_date <= bounded.history_end
                for value in bounded.observations
            )
        )


class SeasonAwareLightGBMTests(unittest.TestCase):
    def test_candidate_is_deterministic_and_metadata_marks_it_experimental(self) -> None:
        origin = date(2025, 10, 31)
        source = bounded_dataset(full_inventory_datasets()[1], origin)
        model = SeasonAwareLightGBMForecaster(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=20,
                learning_rate=0.06,
                num_leaves=12,
                random_seed=26061108,
            )
        )
        first = model.forecast(source, horizon_days=28)
        second = model.forecast(source, horizon_days=28)
        self.assertEqual(first, second)
        self.assertEqual(first[0].metadata.model_name, "seasonal_lightgbm_experimental")
        self.assertTrue(all(value.forecast_date > origin for value in first))
        self.assertIn(
            "experimental_candidate_not_active_for_normal_replenishment",
            first[0].metadata.data_quality.warnings,
        )
        self.assertIn(
            "seasonal_profile_contains_no_numeric_multiplier",
            first[0].metadata.data_quality.warnings,
        )

    def test_insufficient_history_falls_back_without_numeric_seasonal_prior(self) -> None:
        source = bounded_dataset(
            full_inventory_datasets()[0], HISTORY_START + timedelta(days=27)
        )
        value = SeasonAwareLightGBMForecaster().forecast(
            source, horizon_days=1
        )[0]
        self.assertEqual(value.metadata.model_name, "mean28_fallback")
        self.assertEqual(
            value.metadata.fallback_reason, "insufficient_training_history"
        )
        self.assertIn(
            "seasonal_profile_contains_no_numeric_multiplier",
            value.metadata.data_quality.warnings,
        )


if __name__ == "__main__":
    unittest.main()
