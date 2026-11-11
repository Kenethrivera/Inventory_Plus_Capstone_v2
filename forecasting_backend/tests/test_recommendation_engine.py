from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

from app.data.models import DailyDemand
from app.forecasting import (
    ForecastProduct,
    HistoricalDemandDataset,
    Mean28Forecaster,
)
from app.recommendations import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    ManualDemandEstimate,
    RecommendationEngine,
    RecommendationPolicy,
    RecommendationStatus,
    SafetyStockInput,
    SafetyStockSource,
    SupplierAvailability,
    SupplierPolicySnapshot,
    UnitConversion,
)


LOCATION = "11111111-1111-4111-8111-111111111111"
OTHER_LOCATION = "22222222-2222-4222-8222-222222222222"
PRODUCT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
HISTORY_END = date(2026, 1, 28)
NOW = datetime(2026, 1, 28, 12, tzinfo=timezone.utc)


def product(*, unit: str = "pcs") -> ForecastProduct:
    return ForecastProduct(
        location_id=LOCATION,
        product_id=PRODUCT,
        sku="REC-001",
        product_name="Recommendation fixture",
        unit=unit,
    )


def forecast_snapshot(
    *, quantity: Decimal = Decimal("10"), unit: str = "pcs"
) -> DemandForecastSnapshot:
    observations = [
        DailyDemand(
            business_date=HISTORY_END - timedelta(days=offset),
            location_id=LOCATION,
            product_id=PRODUCT,
            sku="REC-001",
            product_name="Recommendation fixture",
            unit=unit,
            quantity=quantity,
            completed_order_count=1,
        )
        for offset in range(28)
    ]
    history = HistoricalDemandDataset.from_synthetic_observations(
        product=product(unit=unit),
        history_start=HISTORY_END - timedelta(days=27),
        history_end=HISTORY_END,
        observations=observations,
    )
    return DemandForecastSnapshot(
        forecasts=tuple(Mean28Forecaster().forecast(history, horizon_days=28)),
        generated_at=NOW,
        source_data_as_of=NOW,
    )


def no_history_forecast() -> DemandForecastSnapshot:
    history = HistoricalDemandDataset.from_synthetic_observations(
        product=product(),
        history_start=None,
        history_end=HISTORY_END,
        observations=[],
    )
    return DemandForecastSnapshot(
        forecasts=tuple(Mean28Forecaster().forecast(history, horizon_days=28)),
        generated_at=NOW,
        source_data_as_of=NOW,
    )


def inventory(
    *,
    on_hand: Decimal | None = Decimal("100"),
    on_order: Decimal | None = Decimal("0"),
    reservations: Decimal | None = Decimal("0"),
    backorders: Decimal | None = Decimal("0"),
    capacity: Decimal | None = Decimal("300"),
    basis: InventoryBalanceBasis = InventoryBalanceBasis.NET_OF_RESERVATIONS,
    location_id: str = LOCATION,
    unit: str = "pcs",
) -> InventorySnapshot:
    return InventorySnapshot(
        location_id=location_id,
        product_id=PRODUCT,
        unit=unit,
        saleable_on_hand=on_hand,
        confirmed_on_order=on_order,
        unfulfilled_reservations=reservations,
        backorders=backorders,
        max_capacity=capacity,
        balance_basis=basis,
        captured_at=NOW,
    )


def supplier(
    *,
    lead_time: int | None = 5,
    moq: Decimal | None = Decimal("0"),
    pack: Decimal | None = Decimal("1"),
    order_unit: str = "pcs",
    availability: SupplierAvailability = SupplierAvailability.AVAILABLE,
) -> SupplierPolicySnapshot:
    return SupplierPolicySnapshot(
        supplier_id="supplier-fixture",
        order_unit=order_unit,
        lead_time_days=lead_time,
        minimum_order_quantity=moq,
        pack_size=pack,
        availability=availability,
        captured_at=NOW,
    )


def safety(quantity: Decimal = Decimal("20")) -> SafetyStockInput:
    return SafetyStockInput(
        quantity=quantity,
        unit="pcs",
        source=SafetyStockSource.CONFIGURED,
        captured_at=NOW,
    )


POLICY = RecommendationPolicy(
    version="stage5c-v1",
    review_period_days=7,
    max_forecast_age=timedelta(days=2),
    max_inventory_age=timedelta(days=1),
    max_supplier_age=timedelta(days=30),
    max_safety_stock_age=timedelta(days=30),
)


class RecommendationEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = RecommendationEngine()

    def recommend(self, **overrides: object):
        arguments = {
            "forecast": forecast_snapshot(),
            "inventory": inventory(),
            "supplier": supplier(),
            "safety_stock": safety(),
            "policy": POLICY,
            "recommendation_at": NOW,
        }
        arguments.update(overrides)
        return self.engine.recommend(**arguments)  # type: ignore[arg-type]

    def test_sufficient_inventory_has_exact_zero_recommendation(self) -> None:
        result = self.recommend(inventory=inventory(on_hand=Decimal("150")))
        self.assertEqual(result.status, RecommendationStatus.SUFFICIENT_INVENTORY)
        self.assertEqual(result.calculation.inventory_position, Decimal("150"))
        self.assertEqual(result.calculation.reorder_point, Decimal("70"))
        self.assertEqual(result.calculation.target_inventory, Decimal("140"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("0"))
        self.assertFalse(result.requires_human_approval)

    def test_low_inventory_calculates_known_answer(self) -> None:
        result = self.recommend()
        self.assertEqual(result.status, RecommendationStatus.RECOMMEND_ORDER)
        self.assertEqual(result.calculation.expected_lead_time_demand, Decimal("50"))
        self.assertEqual(result.calculation.protection_period_days, 12)
        self.assertEqual(
            result.calculation.forecasted_protection_period_demand, Decimal("120")
        )
        self.assertEqual(result.calculation.preliminary_quantity_inventory_units, Decimal("40"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("40"))
        self.assertTrue(result.requires_human_approval)
        self.assertFalse(result.purchase_order_created)
        self.assertEqual(result.audit.policy_version, "stage5c-v1")
        self.assertEqual(result.audit.forecast_model, "mean28")
        self.assertEqual(result.inventory_snapshot, inventory())

    def test_zero_inventory_recommends_target_inventory(self) -> None:
        result = self.recommend(inventory=inventory(on_hand=Decimal("0")))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("140"))

    def test_existing_inbound_orders_reduce_recommendation(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("50"), on_order=Decimal("50"))
        )
        self.assertEqual(result.calculation.inventory_position, Decimal("100"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("40"))

    def test_backorders_reduce_inventory_position(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("100"), backorders=Decimal("15"))
        )
        self.assertEqual(result.calculation.inventory_position, Decimal("85"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("55"))

    def test_missing_balance_component_needs_review_instead_of_assuming_zero(self) -> None:
        result = self.recommend(inventory=inventory(on_order=None))
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIn("confirmed_on_order_missing", result.warnings)

    def test_concrete_blocks_fixture_reports_every_missing_blocker(self) -> None:
        result = self.recommend(
            inventory=inventory(on_order=None, backorders=None),
            supplier=supplier(lead_time=None),
            policy=replace(POLICY, review_period_days=None),
        )

        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIsNone(result.calculation.inventory_position)
        self.assertTrue(result.requires_human_approval)
        for warning in (
            "confirmed_on_order_missing",
            "backorders_missing",
            "supplier_lead_time_missing",
            "review_period_missing",
        ):
            self.assertIn(warning, result.warnings)

    def test_confirmed_zero_balances_are_known_values_not_missing(self) -> None:
        result = self.recommend(
            inventory=inventory(
                on_hand=Decimal("100"),
                on_order=Decimal("0"),
                backorders=Decimal("0"),
            )
        )

        self.assertEqual(result.calculation.inventory_position, Decimal("100"))
        self.assertNotIn("confirmed_on_order_missing", result.warnings)
        self.assertNotIn("backorders_missing", result.warnings)

    def test_missing_review_period_is_not_silently_defaulted(self) -> None:
        result = self.recommend(
            policy=replace(POLICY, review_period_days=None),
        )

        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.calculation.protection_period_days)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIn("review_period_missing", result.warnings)

    def test_invalid_review_period_blocks_calculation(self) -> None:
        result = self.recommend(
            policy=replace(POLICY, review_period_days=-1),
        )

        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.calculation.target_inventory)
        self.assertIn("review_period_invalid", result.warnings)

    def test_reservations_are_not_double_counted_for_current_net_stock(self) -> None:
        result = self.recommend(
            inventory=inventory(
                on_hand=Decimal("80"),
                reservations=Decimal("20"),
                basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
            )
        )
        self.assertEqual(result.calculation.gross_on_hand_equivalent, Decimal("100"))
        self.assertEqual(result.calculation.inventory_position, Decimal("80"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("60"))

    def test_gross_stock_subtracts_reservations_once(self) -> None:
        result = self.recommend(
            inventory=inventory(
                on_hand=Decimal("100"),
                reservations=Decimal("20"),
                basis=InventoryBalanceBasis.GROSS_BEFORE_RESERVATIONS,
            )
        )
        self.assertEqual(result.calculation.inventory_position, Decimal("80"))

    def test_moq_then_pack_size_rounding(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("97")),
            supplier=supplier(moq=Decimal("50"), pack=Decimal("12")),
        )
        self.assertEqual(result.calculation.preliminary_quantity_inventory_units, Decimal("43"))
        self.assertEqual(result.recommended_quantity_order_units, Decimal("60"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("60"))

    def test_valid_supplier_unit_conversion(self) -> None:
        result = self.recommend(
            supplier=supplier(
                moq=Decimal("2"), pack=Decimal("1"), order_unit="box"
            ),
            conversions=(
                UnitConversion(
                    from_unit="box", to_unit="pcs", factor=Decimal("12")
                ),
            ),
        )
        self.assertEqual(result.recommended_quantity_order_units, Decimal("4"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("48"))

    def test_capacity_constraint_returns_explicit_review_warning(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("85"), capacity=Decimal("133")),
            supplier=supplier(moq=Decimal("24"), pack=Decimal("12")),
        )
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("48"))
        self.assertIn("capacity_limits_recommendation", result.warnings)

    def test_capacity_moq_conflict_returns_no_exact_quantity(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("100"), capacity=Decimal("140")),
            supplier=supplier(moq=Decimal("50"), pack=Decimal("10")),
        )
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIn("capacity_conflicts_with_supplier_constraints", result.warnings)

    def test_no_history_requires_manual_demand_estimate(self) -> None:
        result = self.recommend(forecast=no_history_forecast())
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIn("no_history_demand_unknown", result.warnings)

    def test_manual_demand_estimate_supports_cold_start_but_requires_review(self) -> None:
        result = self.recommend(
            forecast=no_history_forecast(),
            inventory=inventory(on_hand=Decimal("0")),
            manual_demand=ManualDemandEstimate(
                daily_quantity=Decimal("5"),
                unit="pcs",
                captured_at=NOW,
                rationale="New product launch estimate approved for review",
            ),
        )
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertEqual(result.calculation.expected_lead_time_demand, Decimal("25"))
        self.assertEqual(result.calculation.target_inventory, Decimal("80"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("80"))
        self.assertIn("cold_start_manual_demand_estimate_used", result.warnings)

    def test_missing_supplier_lead_time_needs_review(self) -> None:
        result = self.recommend(supplier=supplier(lead_time=None))
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.calculation.reorder_point)
        self.assertIn("supplier_lead_time_missing", result.warnings)

    def test_missing_safety_stock_needs_review(self) -> None:
        result = self.recommend(safety_stock=None)
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIn("safety_stock_missing", result.warnings)

    def test_negative_inventory_input_needs_review(self) -> None:
        result = self.recommend(inventory=inventory(on_hand=Decimal("-1")))
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIsNone(result.recommended_quantity_inventory_units)
        self.assertIn("saleable_on_hand_invalid", result.warnings)

    def test_incompatible_units_need_review(self) -> None:
        result = self.recommend(forecast=forecast_snapshot(unit="kg"))
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIn("forecast_unit_incompatible", result.warnings)

    def test_stale_forecast_keeps_math_but_requires_review(self) -> None:
        stale = replace(
            forecast_snapshot(),
            generated_at=NOW - timedelta(days=3),
            source_data_as_of=NOW - timedelta(days=3),
        )
        result = self.recommend(forecast=stale)
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("40"))
        self.assertIn("forecast_stale", result.warnings)

    def test_different_lead_times_change_protection_period(self) -> None:
        result = self.recommend(supplier=supplier(lead_time=10))
        self.assertEqual(result.calculation.expected_lead_time_demand, Decimal("100"))
        self.assertEqual(result.calculation.protection_period_days, 17)
        self.assertEqual(result.calculation.target_inventory, Decimal("190"))
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("90"))

    def test_long_protection_period_uses_documented_average_rate_approximation(self) -> None:
        result = self.recommend(supplier=supplier(lead_time=30))
        self.assertEqual(result.calculation.protection_period_days, 37)
        self.assertEqual(result.calculation.target_inventory, Decimal("390"))
        self.assertIn(
            "protection_period_exceeds_forecast_horizon_average_rate_scaling",
            result.warnings,
        )
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)

    def test_supplier_unavailable_needs_review(self) -> None:
        result = self.recommend(
            supplier=supplier(availability=SupplierAvailability.UNAVAILABLE)
        )
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIn("supplier_unavailable_or_unknown", result.warnings)

    def test_zero_quantity_needs_review_still_requires_human_review(self) -> None:
        result = self.recommend(
            inventory=inventory(on_hand=Decimal("200")),
            supplier=supplier(availability=SupplierAvailability.UNKNOWN),
        )

        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertEqual(result.recommended_quantity_inventory_units, Decimal("0"))
        self.assertTrue(result.requires_human_approval)

    def test_product_location_mismatch_is_rejected(self) -> None:
        result = self.recommend(inventory=inventory(location_id=OTHER_LOCATION))
        self.assertEqual(result.status, RecommendationStatus.NEEDS_REVIEW)
        self.assertIn("forecast_identity_mismatch", result.warnings)


if __name__ == "__main__":
    unittest.main()
