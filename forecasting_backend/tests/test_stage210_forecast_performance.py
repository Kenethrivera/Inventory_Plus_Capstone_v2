from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Mapping
from uuid import UUID

from fastapi.testclient import TestClient

from app.api import create_app
from app.api.contracts import DataUnavailableError, SessionProfile
from app.api.forecast_performance import ForecastPerformanceEvaluator
from app.data import DailyDemand

from .test_api import settings


PRODUCT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
LOCATION_ID = "11111111-1111-4111-8111-111111111111"
NOW = datetime(2026, 11, 11, 2, 0, tzinfo=timezone.utc)


class DemandAdapter:
    def __init__(self, rows=(), failure: Exception | None = None) -> None:
        self.rows = tuple(rows)
        self.failure = failure
        self.calls: list[tuple[datetime, datetime, str]] = []

    def load_daily_demand(
        self,
        *,
        profile,
        session_token,
        period_start,
        period_end,
        business_timezone="Asia/Manila",
    ):
        self.calls.append((period_start, period_end, business_timezone))
        if self.failure is not None:
            raise self.failure
        return tuple(
            row
            for row in self.rows
            if period_start.date() <= row.business_date < period_end.date()
        )


class ApiDemandAdapter(DemandAdapter):
    def authenticate(self, session_token: str) -> SessionProfile:
        if session_token != "session":
            raise AssertionError("unexpected session")
        return SessionProfile(
            profile_id="admin",
            role="admin",
            location_id=LOCATION_ID,
            name="Admin",
        )


class ReadOnlyTrackingAdapter:
    def __init__(self, rows: list[Mapping[str, object]]) -> None:
        self.rows = rows
        self.tracking_calls = 0
        self.write_calls = 0

    def tracking(self, *, session_token: str, product_id: UUID | None):
        self.tracking_calls += 1
        return self.rows

    def snapshot_by_request(self, **kwargs):
        self.write_calls += 1
        raise AssertionError("not used")

    def save_snapshot(self, **kwargs):
        self.write_calls += 1
        raise AssertionError("not used")

    def match_receipt(self, **kwargs):
        self.write_calls += 1
        raise AssertionError("not used")

    def reconcile(self, **kwargs):
        self.write_calls += 1
        raise AssertionError("not used")


def tracking_row(
    recommendation_id: int,
    *,
    start: str,
    end: str,
    predicted: str,
    sku: str = "SIM-SUM-001",
    unit: str = "pcs",
) -> dict[str, object]:
    return {
        "recommendation_id": recommendation_id,
        "product_id_snapshot": PRODUCT_ID,
        "product_name_snapshot": "Test product",
        "product_sku_snapshot": sku,
        "inventory_unit": unit,
        "recommendation_date": f"{start}T00:00:00+08:00",
        "forecast_period_start": start,
        "forecast_period_end": end,
        "predicted_demand": predicted,
    }


def demand(day: str, quantity: str, *, unit: str = "pcs") -> DailyDemand:
    return DailyDemand(
        business_date=date.fromisoformat(day),
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        product_name="Test product",
        unit=unit,
        quantity=Decimal(quantity),
        completed_order_count=1,
        sku="SIM-SUM-001",
    )


class ForecastPerformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = SessionProfile(
            profile_id="admin",
            role="admin",
            location_id=LOCATION_ID,
            name="Admin",
        )

    def evaluate(self, adapter: DemandAdapter, rows):
        return ForecastPerformanceEvaluator(adapter).evaluate(
            profile=self.profile,
            session_token="session",
            product_id=PRODUCT_ID,
            tracking_rows=rows,
            now=NOW,
        )

    def test_pending_period_does_not_read_or_leak_future_sales(self) -> None:
        adapter = DemandAdapter([demand("2026-11-12", "999")])
        report = self.evaluate(
            adapter,
            [tracking_row(1, start="2026-11-01", end="2026-11-28", predicted="20")],
        )
        item = report["items"][0]
        self.assertEqual(item["evaluation_status"], "awaiting_completion")
        self.assertIsNone(item["actual_completed_sales"])
        self.assertEqual(adapter.calls, [])

    def test_duplicate_snapshots_count_as_one_accuracy_observation(self) -> None:
        adapter = DemandAdapter([demand("2026-08-10", "5")])
        rows = [
            tracking_row(9, start="2026-08-01", end="2026-08-28", predicted="50"),
            tracking_row(3, start="2026-08-01", end="2026-08-28", predicted="20"),
            tracking_row(5, start="2026-08-01", end="2026-08-28", predicted="20"),
        ]
        rows[0]["recommendation_date"] = "2026-08-02T00:00:00+08:00"
        report = self.evaluate(adapter, rows)
        self.assertEqual(report["saved_recommendation_count"], 3)
        self.assertEqual(report["unique_forecast_window_count"], 1)
        self.assertEqual(len(report["items"]), 1)
        item = report["items"][0]
        self.assertEqual(item["recommendation_id"], 3)
        self.assertEqual(item["source_recommendation_count"], 3)
        self.assertTrue(item["prediction_conflict"])
        self.assertEqual(item["first_eligible_evaluation_date"], date(2026, 8, 29))
        summary = report["summaries_by_unit"][0]
        self.assertEqual(summary["evaluation_count"], 1)
        self.assertEqual(summary["actual_total"], Decimal("5"))
        self.assertEqual(summary["absolute_error_total"], Decimal("15"))
        self.assertEqual(summary["wape"], Decimal("300"))
        self.assertEqual(summary["forecast_bias"], Decimal("300"))

    def test_distinct_windows_and_units_remain_distinct(self) -> None:
        adapter = DemandAdapter([demand("2026-08-20", "5")])
        report = self.evaluate(adapter, [
            tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="10"),
            tracking_row(2, start="2026-08-15", end="2026-09-11", predicted="10"),
            tracking_row(3, start="2026-08-01", end="2026-08-28", predicted="10", unit="box"),
        ])
        self.assertEqual(report["unique_forecast_window_count"], 3)
        self.assertEqual(len(report["items"]), 3)
        self.assertEqual(len(adapter.calls), 1)
        by_id = {item["recommendation_id"]: item for item in report["items"]}
        self.assertEqual(by_id[3]["evaluation_status"], "insufficient_sales_data")
        self.assertEqual(report["summaries_by_unit"][0]["evaluation_count"], 2)

    def test_duplicate_pending_window_has_one_row_and_future_eligibility(self) -> None:
        adapter = DemandAdapter([demand("2026-11-10", "999")])
        report = self.evaluate(adapter, [
            tracking_row(4, start="2026-11-23", end="2026-12-20", predicted="20"),
            tracking_row(5, start="2026-11-23", end="2026-12-20", predicted="20"),
            tracking_row(6, start="2026-11-23", end="2026-12-20", predicted="20"),
            tracking_row(7, start="2026-11-23", end="2026-12-20", predicted="20"),
        ])
        self.assertEqual(report["saved_recommendation_count"], 4)
        self.assertEqual(report["unique_forecast_window_count"], 1)
        self.assertEqual(report["items"][0]["first_eligible_evaluation_date"], date(2026, 12, 21))
        self.assertEqual(report["items"][0]["evaluation_status"], "awaiting_completion")
        self.assertEqual(report["summaries_by_unit"], [])
        self.assertEqual(adapter.calls, [])

    def test_duplicate_completed_zero_sales_is_one_eligible_evaluation(self) -> None:
        report = self.evaluate(DemandAdapter(), [
            tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="4"),
            tracking_row(2, start="2026-08-01", end="2026-08-28", predicted="4"),
        ])
        self.assertEqual(report["items"][0]["evaluation_status"], "completed_zero_sales")
        self.assertEqual(report["summaries_by_unit"][0]["evaluation_count"], 1)
        self.assertIsNone(report["summaries_by_unit"][0]["wape"])

    def test_model_and_version_are_part_of_observation_identity(self) -> None:
        rows = [
            tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="10"),
            tracking_row(2, start="2026-08-01", end="2026-08-28", predicted="10"),
            tracking_row(3, start="2026-08-01", end="2026-08-28", predicted="10"),
        ]
        rows[1]["forecast_version"] = "2"
        rows[2]["forecast_model"] = "mean28"
        report = self.evaluate(DemandAdapter([demand("2026-08-10", "5")]), rows)
        self.assertEqual(report["unique_forecast_window_count"], 3)
        self.assertEqual(report["summaries_by_unit"][0]["evaluation_count"], 3)

    def test_unexpected_location_is_rejected_before_aggregation(self) -> None:
        row = tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="10")
        row["location_id_snapshot"] = "22222222-2222-4222-8222-222222222222"
        with self.assertRaises(DataUnavailableError):
            self.evaluate(DemandAdapter(), [row])

    def test_completed_over_under_and_zero_sales_with_unit_wape(self) -> None:
        adapter = DemandAdapter(
            [
                demand("2026-08-10", "5"),
                demand("2026-09-10", "30"),
                # Outside every requested period and must never be counted.
                demand("2026-11-10", "500"),
            ]
        )
        report = self.evaluate(
            adapter,
            [
                tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="20"),
                tracking_row(2, start="2026-09-01", end="2026-09-28", predicted="20"),
                tracking_row(3, start="2026-10-01", end="2026-10-28", predicted="4"),
            ],
        )
        by_id = {item["recommendation_id"]: item for item in report["items"]}
        self.assertEqual(by_id[1]["signed_forecast_error"], Decimal("15"))
        self.assertEqual(by_id[1]["error_direction"], "overprediction")
        self.assertEqual(by_id[2]["signed_forecast_error"], Decimal("-10"))
        self.assertEqual(by_id[2]["error_direction"], "underprediction")
        self.assertEqual(by_id[3]["evaluation_status"], "completed_zero_sales")
        self.assertIsNone(by_id[3]["percentage_error"])
        summary = report["summaries_by_unit"][0]
        self.assertEqual(summary["actual_total"], Decimal("35"))
        self.assertEqual(summary["absolute_error_total"], Decimal("29"))
        self.assertAlmostEqual(float(summary["wape"]), 82.857142, places=5)
        self.assertAlmostEqual(float(summary["forecast_bias"]), 25.714285, places=5)
        self.assertTrue(all(item["synthetic_sales"] for item in report["items"]))

    def test_overlapping_windows_are_fetched_once_with_manila_boundaries(self) -> None:
        adapter = DemandAdapter([demand("2026-08-10", "5")])
        self.evaluate(
            adapter,
            [
                tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="20"),
                tracking_row(2, start="2026-08-15", end="2026-09-11", predicted="20"),
            ],
        )
        self.assertEqual(len(adapter.calls), 1)
        start, end, timezone_name = adapter.calls[0]
        self.assertEqual(start.isoformat(), "2026-08-01T00:00:00+08:00")
        self.assertEqual(end.isoformat(), "2026-09-12T00:00:00+08:00")
        self.assertEqual(timezone_name, "Asia/Manila")

    def test_unavailable_sales_are_not_interpreted_as_zero(self) -> None:
        adapter = DemandAdapter(failure=DataUnavailableError("offline"))
        report = self.evaluate(
            adapter,
            [tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="20")],
        )
        item = report["items"][0]
        self.assertEqual(item["evaluation_status"], "insufficient_sales_data")
        self.assertIsNone(item["actual_completed_sales"])
        self.assertEqual(report["summaries_by_unit"], [])
        self.assertFalse(report["data_source_available"])

    def test_incompatible_sales_unit_is_not_combined(self) -> None:
        adapter = DemandAdapter([demand("2026-08-10", "5", unit="box")])
        report = self.evaluate(
            adapter,
            [tracking_row(1, start="2026-08-01", end="2026-08-28", predicted="20")],
        )
        self.assertEqual(
            report["items"][0]["evaluation_status"],
            "insufficient_sales_data",
        )
        self.assertIsNone(report["items"][0]["actual_completed_sales"])

    def test_non_simulation_sku_uses_live_supabase_provenance_label(self) -> None:
        adapter = DemandAdapter([demand("2026-08-10", "5")])
        report = self.evaluate(
            adapter,
            [
                tracking_row(
                    1,
                    start="2026-08-01",
                    end="2026-08-28",
                    predicted="5",
                    sku="HDW-001",
                )
            ],
        )
        item = report["items"][0]
        self.assertFalse(item["synthetic_sales"])
        self.assertEqual(item["sales_provenance"], "live_supabase_completed_sales")

    def test_read_only_api_contract_does_not_call_persistence_writes(self) -> None:
        adapter = ApiDemandAdapter([demand("2026-08-10", "5")])
        persistence = ReadOnlyTrackingAdapter(
            [
                tracking_row(
                    1,
                    start="2026-08-01",
                    end="2026-08-28",
                    predicted="20",
                )
            ]
        )
        configured = replace(
            settings(),
            recommendation_persistence_enabled=True,
            supabase_secret_key="test-server-only-secret",
        )
        client = TestClient(
            create_app(
                adapter=adapter,
                recommendation_persistence_adapter=persistence,
                settings=configured,
                clock=lambda: NOW,
            )
        )
        response = client.get(
            "/v1/forecasting/forecast-performance",
            headers={"Authorization": "Bearer session"},
            params={"product_id": PRODUCT_ID, "location_id": LOCATION_ID},
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["items"][0]["actual_completed_sales"], "5")
        self.assertEqual(persistence.tracking_calls, 1)
        self.assertEqual(persistence.write_calls, 0)


if __name__ == "__main__":
    unittest.main()
