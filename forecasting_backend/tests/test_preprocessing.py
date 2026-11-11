from __future__ import annotations

import unittest
from datetime import date, datetime, timezone
from decimal import Decimal

from app.data.preprocessing import aggregate_completed_orders, fill_missing_days
from app.data.validation import DemandDataError


LOCATION_A = "11111111-1111-4111-8111-111111111111"
LOCATION_B = "22222222-2222-4222-8222-222222222222"
PRODUCT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def order(
    order_id: str,
    *,
    status: str = "completed",
    location_id: str = LOCATION_A,
    completed_at: str | None = "2026-01-02T16:30:00+00:00",
    returned_at: str | None = None,
    quantity: object = 2,
    created_at: str = "2026-01-01T00:00:00+00:00",
    snapshot_updated_at: str = "2026-01-03T00:00:00+00:00",
) -> dict[str, object]:
    return {
        "order_id": order_id,
        "status": status,
        "location_id": location_id,
        "completed_at": completed_at,
        "returned_at": returned_at,
        "created_at": created_at,
        "snapshot_updated_at": snapshot_updated_at,
        "items": [
            {
                "product_id": PRODUCT_A,
                "product_name": "Claw Hammer",
                "quantity": quantity,
                "unit": "pcs",
            }
        ],
    }


class AggregateCompletedOrdersTests(unittest.TestCase):
    def test_uses_completion_time_and_philippine_business_date(self) -> None:
        values = aggregate_completed_orders([order("order-1")])
        self.assertEqual(values[0].business_date, date(2026, 1, 3))
        self.assertEqual(values[0].quantity, Decimal("2"))
        self.assertEqual(values[0].unit, "pcs")

    def test_excludes_pending_cancelled_and_returned_orders(self) -> None:
        rows = [
            order("pending", status="pending"),
            order("cancelled", status="cancelled"),
            order("returned", returned_at="2026-01-04T00:00:00+00:00"),
            order("completed"),
        ]
        values = aggregate_completed_orders(rows)
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0].completed_order_count, 1)

    def test_does_not_double_count_duplicate_order_rows(self) -> None:
        row = order("same-order", quantity="3.5")
        values = aggregate_completed_orders([row, dict(row)])
        self.assertEqual(values[0].quantity, Decimal("3.5"))
        self.assertEqual(values[0].completed_order_count, 1)

    def test_rejects_conflicting_duplicate_order_rows(self) -> None:
        first = order("same-order", quantity=1)
        second = order("same-order", quantity=2)
        with self.assertRaises(DemandDataError):
            aggregate_completed_orders([first, second])

    def test_keeps_locations_separate(self) -> None:
        values = aggregate_completed_orders(
            [order("a", location_id=LOCATION_A), order("b", location_id=LOCATION_B)]
        )
        self.assertEqual(len(values), 2)
        self.assertEqual({value.location_id for value in values}, {LOCATION_A, LOCATION_B})

    def test_rejects_nonpositive_quantities(self) -> None:
        with self.assertRaises(DemandDataError):
            aggregate_completed_orders([order("bad", quantity=0)])

    def test_rejects_inconsistent_units_for_one_product(self) -> None:
        first = order("first")
        second = order("second")
        second["items"][0]["unit"] = "box"  # type: ignore[index]
        with self.assertRaises(DemandDataError):
            aggregate_completed_orders([first, second])

    def test_rejects_completed_order_without_completion_timestamp(self) -> None:
        with self.assertRaises(DemandDataError):
            aggregate_completed_orders([order("bad", completed_at=None)])

    def test_rejects_undated_completed_order_that_may_overlap_window(self) -> None:
        with self.assertRaises(DemandDataError):
            aggregate_completed_orders(
                [order("bad", completed_at=None)],
                period_start=datetime(2026, 1, 2, tzinfo=timezone.utc),
                period_end=datetime(2026, 1, 4, tzinfo=timezone.utc),
            )

    def test_ignores_undated_completed_order_proven_outside_window(self) -> None:
        values = aggregate_completed_orders(
            [
                order(
                    "old-undated",
                    completed_at=None,
                    created_at="2025-01-01T00:00:00+00:00",
                    snapshot_updated_at="2025-01-02T00:00:00+00:00",
                ),
                order("in-window"),
            ],
            period_start=datetime(2026, 1, 2, tzinfo=timezone.utc),
            period_end=datetime(2026, 1, 4, tzinfo=timezone.utc),
        )
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0].completed_order_count, 1)

    def test_uses_half_open_window_for_known_completion_timestamp(self) -> None:
        values = aggregate_completed_orders(
            [
                order("included", completed_at="2026-01-02T00:00:00+00:00"),
                order("excluded-end", completed_at="2026-01-03T00:00:00+00:00"),
            ],
            period_start=datetime(2026, 1, 2, tzinfo=timezone.utc),
            period_end=datetime(2026, 1, 3, tzinfo=timezone.utc),
        )
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0].completed_order_count, 1)

    def test_zero_fills_calendar_gaps(self) -> None:
        values = aggregate_completed_orders([order("order-1")])
        series = fill_missing_days(
            values, start=date(2026, 1, 2), end=date(2026, 1, 4)
        )
        result = next(iter(series.values()))
        self.assertEqual([value.quantity for value in result], [0, 2, 0])
        self.assertEqual([value.completed_order_count for value in result], [0, 1, 0])


if __name__ == "__main__":
    unittest.main()

