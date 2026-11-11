from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

from app.data.models import DailyDemand
from app.forecasting import ForecastProduct, HistoricalDemandDataset, Mean28Forecaster
from app.recommendations import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    PreliminaryInsightStatus,
    PreliminaryRestockingInsightCalculator,
)


LOCATION_ID = "11111111-1111-4111-8111-111111111111"
PRODUCT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
HISTORY_END = date(2026, 11, 10)
NOW = datetime(2026, 11, 10, 12, tzinfo=timezone.utc)


def _forecast(daily_quantity: Decimal, *, no_history: bool = False):
    product = ForecastProduct(
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        product_name="Insight fixture",
        unit="pcs",
    )
    observations = () if no_history else tuple(
        DailyDemand(
            business_date=HISTORY_END - timedelta(days=offset),
            location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            product_name=product.product_name,
            unit=product.unit,
            quantity=daily_quantity,
            completed_order_count=1,
        )
        for offset in range(28)
    )
    history = HistoricalDemandDataset.from_synthetic_observations(
        product=product,
        history_start=None if no_history else HISTORY_END - timedelta(days=27),
        history_end=HISTORY_END,
        observations=observations,
    )
    values = Mean28Forecaster().forecast(history, horizon_days=28)
    return DemandForecastSnapshot(
        forecasts=tuple(values),
        generated_at=NOW,
        source_data_as_of=NOW,
    )


def _inventory(on_hand: Decimal | None):
    return InventorySnapshot(
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        unit="pcs",
        saleable_on_hand=on_hand,
        confirmed_on_order=None,
        unfulfilled_reservations=None,
        backorders=None,
        max_capacity=None,
        balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
        captured_at=NOW,
    )


class PreliminaryRestockingInsightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calculator = PreliminaryRestockingInsightCalculator()

    def test_missing_supplier_inputs_do_not_block_demand_minus_stock(self) -> None:
        result = self.calculator.calculate(
            forecast=_forecast(Decimal("3")),
            inventory=_inventory(Decimal("44")),
        )
        self.assertEqual(result.status, PreliminaryInsightStatus.AVAILABLE)
        self.assertEqual(result.predicted_demand, Decimal("84"))
        self.assertEqual(result.available_inventory, Decimal("44"))
        self.assertEqual(result.suggested_restock_quantity, Decimal("40"))
        self.assertTrue(result.requires_owner_review)
        self.assertTrue(any("not interpreted" in value for value in result.assumptions))

    def test_positive_fractional_shortfall_is_rounded_up(self) -> None:
        snapshot = _forecast(Decimal("3"))
        fractional = tuple(
            replace(value, quantity=Decimal("3.007142857142857"))
            for value in snapshot.forecasts
        )
        result = self.calculator.calculate(
            forecast=replace(snapshot, forecasts=fractional),
            inventory=_inventory(Decimal("44")),
        )
        self.assertGreater(result.predicted_demand, Decimal("84"))
        self.assertEqual(result.suggested_restock_quantity, Decimal("41"))

    def test_inventory_above_demand_returns_zero(self) -> None:
        result = self.calculator.calculate(
            forecast=_forecast(Decimal("1")),
            inventory=_inventory(Decimal("100")),
        )
        self.assertEqual(result.suggested_restock_quantity, Decimal("0"))

    def test_missing_inventory_preserves_demand_but_not_quantity(self) -> None:
        result = self.calculator.calculate(
            forecast=_forecast(Decimal("2")), inventory=_inventory(None)
        )
        self.assertEqual(result.status, PreliminaryInsightStatus.LIMITED)
        self.assertEqual(result.predicted_demand, Decimal("56"))
        self.assertIsNone(result.available_inventory)
        self.assertIsNone(result.suggested_restock_quantity)
        self.assertTrue(any("saleable inventory" in value for value in result.limitations))

    def test_no_history_zero_is_unknown_not_zero_demand(self) -> None:
        result = self.calculator.calculate(
            forecast=_forecast(Decimal("0"), no_history=True),
            inventory=_inventory(Decimal("10")),
        )
        self.assertEqual(result.status, PreliminaryInsightStatus.LIMITED)
        self.assertIsNone(result.predicted_demand)
        self.assertIsNone(result.suggested_restock_quantity)
        self.assertTrue(any("unknown demand" in value for value in result.limitations))

    def test_invalid_inventory_is_not_used(self) -> None:
        result = self.calculator.calculate(
            forecast=_forecast(Decimal("2")),
            inventory=_inventory(Decimal("-1")),
        )
        self.assertIsNone(result.available_inventory)
        self.assertIsNone(result.suggested_restock_quantity)


if __name__ == "__main__":
    unittest.main()
