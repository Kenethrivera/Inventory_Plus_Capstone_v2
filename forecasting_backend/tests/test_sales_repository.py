from __future__ import annotations

import unittest
from datetime import datetime, timezone
from decimal import Decimal

from app.data.sales_repository import SalesRepository


class _Response:
    data = [
        {
            "business_date": "2026-02-01",
            "location_id": "11111111-1111-4111-8111-111111111111",
            "product_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "sku": "HAM-001",
            "product_name": "Claw Hammer",
            "unit": "pcs",
            "quantity": "4.5",
            "completed_order_count": 2,
        }
    ]


class _Request:
    def execute(self) -> _Response:
        return _Response()


class _Client:
    def __init__(self) -> None:
        self.function_name = ""
        self.params: dict[str, object] = {}

    def rpc(self, function_name: str, params: dict[str, object]) -> _Request:
        self.function_name = function_name
        self.params = params
        return _Request()


class SalesRepositoryTests(unittest.TestCase):
    def test_calls_scoped_rpc_and_validates_response(self) -> None:
        client = _Client()
        repository = SalesRepository(client, "session-token")
        values = repository.daily_demand(
            period_start=datetime(2026, 2, 1, tzinfo=timezone.utc),
            period_end=datetime(2026, 3, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(client.function_name, "forecast_daily_demand_v1")
        self.assertEqual(client.params["p_business_timezone"], "Asia/Manila")
        self.assertEqual(values[0].quantity, Decimal("4.5"))
        self.assertEqual(values[0].sku, "HAM-001")

    def test_rejects_naive_period_bounds(self) -> None:
        with self.assertRaises(ValueError):
            SalesRepository(_Client(), "token").daily_demand(
                period_start=datetime(2026, 2, 1),
                period_end=datetime(2026, 3, 1),
            )


if __name__ == "__main__":
    unittest.main()

