from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from app.api.contracts import DataUnavailableError, SessionProfile
from app.api.restock_priorities import StoreRestockPriorityReader, _unavailable_reason


class _Snapshots:
    def __init__(self) -> None:
        self.overview_calls = 0
        self.product_calls = 0
        self.last_scope = None

    def overview(self, **kwargs):
        self.overview_calls += 1
        self.last_scope = (kwargs["unit"], kwargs["category"], kwargs["product_id"])
        assert kwargs["model_key"] == "lightgbm"
        rows = []
        for number in range(12):
            status = "stale" if number == 10 else "no_forecast" if number == 11 else "completed"
            rows.append({
                "status": status,
                "job": {"status": "queued"} if number == 11 else {},
                "snapshot": {} if status == "completed" else None,
                "product": {
                    "product_id": f"product-{number:02d}", "location_id": "store-1",
                    "name": f"Product {number:02d}", "sku": f"SKU-{number:02d}",
                    "category": "Paint", "unit": "piece",
                },
            })
        return {"items": rows, "total_count": 12, "page_count": 1}

    def product(self, **kwargs):
        self.product_calls += 1
        assert kwargs["model_key"] == "lightgbm"
        return {"items": [{"status": "completed", "snapshot": {},
                           "product": {"location_id": kwargs["location_id"],
                                       "product_id": kwargs["product_id"]}}]}


class _Adapter:
    def load_operational_context(self, **kwargs):
        return SimpleNamespace(product_id=kwargs["product_id"])


class StoreRestockPriorityReaderTests(unittest.TestCase):
    def test_insufficient_history_reason_is_safe_and_specific(self):
        code, message = _unavailable_reason(
            "recommendation", DataUnavailableError("Insufficient history for this product")
        )
        self.assertEqual(code, "sales_history_insufficient")
        self.assertIn("reliable demand", message)

    def test_ranks_whole_scope_then_paginates_without_refitting(self):
        snapshots = _Snapshots()
        reader = StoreRestockPriorityReader(
            snapshots=snapshots, adapter=_Adapter(), service=object(),
        )
        profile = SessionProfile(profile_id="1", role="admin", location_id="store-1", name="Admin")

        def guidance(**kwargs):
            number = int(kwargs["context"].product_id[-2:])
            return {"recommendation": {
                "forecast_basis": {"model": "lightgbm"},
                "status": "recommend_order" if number < 8 else "sufficient_inventory",
                "suggested_quantity": {"inventory_units": 20 - number},
                "reorder_alert": {"at_or_below_reorder_point": number < 4},
                "inventory_position": 10,
                "reorder_point": 20 - number,
                "target_inventory": 25 - number,
            }}

        with patch("app.api.restock_priorities.current_stock_analysis", side_effect=guidance):
            arguments = dict(profile=profile, session_token="token",
                             now=datetime(2026, 11, 22, tzinfo=timezone.utc),
                             page_size=5, unit="piece", category=None,
                             product_id=None, search=None)
            first = reader.page(page=1, **arguments)
            second = reader.page(page=2, **arguments)

        self.assertEqual(first["total_products"], 12)
        self.assertEqual(first["total_count"], 8)
        self.assertEqual(first["missing_count"], 1)
        self.assertEqual(first["stale_count"], 1)
        self.assertEqual(first["unavailable_items"], [])
        self.assertEqual(first["current_count"], 10)
        self.assertEqual(first["active_count"], 1)
        self.assertEqual(first["page_count"], 2)
        self.assertEqual([row["product_id"] for row in first["items"]],
                         [f"product-{number:02d}" for number in range(5)])
        self.assertEqual(len(second["items"]), 3)
        self.assertEqual(second["unavailable_items"], [])
        self.assertEqual(snapshots.overview_calls, 1)
        self.assertEqual(snapshots.product_calls, 10)
        self.assertEqual(snapshots.last_scope, ("piece", None, None))

    def test_coverage_poll_does_not_evaluate_recommendations(self):
        snapshots = _Snapshots()
        reader = StoreRestockPriorityReader(
            snapshots=snapshots, adapter=_Adapter(), service=object(),
        )
        profile = SessionProfile(profile_id="1", role="admin", location_id="store-1", name="Admin")
        with patch("app.api.restock_priorities.current_stock_analysis",
                   side_effect=AssertionError("Coverage must not calculate guidance")):
            coverage = reader.coverage(profile=profile, unit=None, category=None,
                                       product_id=None, search=None)
        self.assertEqual(coverage, {"total_products": 12, "active_count": 1,
                                    "current_count": 10, "stale_count": 1})
        self.assertEqual(snapshots.product_calls, 0)

    def test_other_model_output_is_unavailable_and_never_substituted(self):
        reader = StoreRestockPriorityReader(
            snapshots=_Snapshots(), adapter=_Adapter(), service=object(),
        )
        profile = SessionProfile(profile_id="1", role="admin", location_id="store-1", name="Admin")
        with patch("app.api.restock_priorities.current_stock_analysis", return_value={
            "recommendation": {"forecast_basis": {"model": "mean28"}},
        }):
            result = reader.page(profile=profile, session_token="token",
                                 now=datetime(2026, 11, 22, tzinfo=timezone.utc),
                                 page=1, page_size=5, unit=None,
                                 category="Paint", product_id=None, search=None)
            unavailable = reader.page(profile=profile, session_token="token",
                                      now=datetime(2026, 11, 22, tzinfo=timezone.utc),
                                      page=1, page_size=5, unit=None,
                                      category="Paint", product_id=None, search=None,
                                      view="unavailable")
        self.assertEqual(result["unavailable_count"], 10)
        self.assertEqual(result["total_count"], 0)
        self.assertEqual(result["unavailable_items"], [])
        self.assertEqual(unavailable["page_count"], 2)
        self.assertEqual(len(unavailable["unavailable_items"]), 5)
        self.assertTrue(all(item["reason_code"] == "recommendation_inputs_invalid"
                            for item in unavailable["unavailable_items"]))

    def test_explicit_refresh_recomputes_global_order(self):
        snapshots = _Snapshots()
        reader = StoreRestockPriorityReader(
            snapshots=snapshots, adapter=_Adapter(), service=object(),
        )
        profile = SessionProfile(profile_id="1", role="admin", location_id="store-1", name="Admin")

        def guidance(**kwargs):
            number = int(kwargs["context"].product_id[-2:])
            reorder = 100 - number if snapshots.overview_calls == 1 else 100 + number
            return {"recommendation": {
                "forecast_basis": {"model": "lightgbm"},
                "status": "recommend_order",
                "suggested_quantity": {"inventory_units": reorder},
                "reorder_alert": {"at_or_below_reorder_point": True},
                "inventory_position": 10, "reorder_point": reorder,
                "target_inventory": reorder,
            }}

        with patch("app.api.restock_priorities.current_stock_analysis", side_effect=guidance):
            arguments = dict(profile=profile, session_token="token",
                             now=datetime(2026, 11, 22, tzinfo=timezone.utc),
                             page=1, page_size=5, unit=None,
                             category=None, product_id=None, search=None)
            first = reader.page(**arguments)
            refreshed = reader.page(refresh=True, **arguments)
        self.assertEqual(first["items"][0]["product_id"], "product-00")
        self.assertEqual(refreshed["items"][0]["product_id"], "product-09")
        self.assertEqual(snapshots.overview_calls, 2)


if __name__ == "__main__":
    unittest.main()
