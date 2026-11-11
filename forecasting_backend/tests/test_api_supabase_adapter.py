from __future__ import annotations

import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from threading import Event, Lock
from typing import Any, Mapping

import httpx

from app.api.adapters import SupabaseForecastAdapter, SupabaseRestClient
from app.api.contracts import (
    DataUnavailableError,
    ReplenishmentConfigurationUnavailableError,
)
from app.api.service import ForecastAnalysisService
from app.api.settings import ApiSettings
from app.data.preprocessing import parse_rpc_daily_demand
from app.forecasting import ForecastProduct, HistoricalDemandDataset, Mean28Forecaster


NOW = datetime(2026, 11, 4, 8, tzinfo=timezone.utc)
LOCATION_ID = "11111111-1111-4111-8111-111111111111"
PRODUCT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


class _Result:
    def __init__(self, data: list[Mapping[str, Any]]) -> None:
        self.data = data


class _Request:
    def __init__(self, data: list[Mapping[str, Any]]) -> None:
        self._data = data

    def execute(self) -> _Result:
        return _Result(self._data)


class ControlledSupabaseClient:
    """Read-only fake for the production adapter; it has no write methods."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, Mapping[str, Any]]] = []
        self.product_context: dict[str, Any] = {
            "id": PRODUCT_ID,
            "sku": "NEW-001",
            "product_name": "New hardware product",
            "unit": "pcs",
            "product_quantity": 20,
            "max_quantity": 100,
            "location_id": LOCATION_ID,
            "created_at": "2026-11-04T00:00:00+08:00",
            "updated_at": "2026-11-04T07:00:00+08:00",
            "is_active": True,
        }
        self.replenishment_config: dict[str, Any] = {
            "configured": False,
            "product_id": PRODUCT_ID,
            "location_id": LOCATION_ID,
            "inventory_unit": "pcs",
            "supplier_lead_time_days": None,
            "review_period_days": None,
            "safety_stock": None,
            "minimum_order_quantity": None,
            "supplier_pack_size": None,
            "supplier_order_unit": None,
            "unit_conversion_factor": None,
            "confirmed_incoming_quantity": None,
            "incoming_quantity_verified": False,
            "backorder_quantity": None,
            "backorder_quantity_verified": False,
            "supplier_availability": None,
            "data_source": None,
            "source_captured_at": None,
            "rationale": None,
            "updated_at": None,
            "updated_by_profile_id": None,
        }
        self.replenishment_dependency_available = True
        self.history_rpc_calls = 0

    def call_rpc(
        self,
        function_name: str,
        params: Mapping[str, Any],
        *,
        authentication_rpc: bool = False,
    ) -> Any:
        self.calls.append((function_name, dict(params)))
        if function_name == "profile_restore_session_v1" and authentication_rpc:
            return {
                "profile": {
                    "id": "admin-1",
                    "role": "Admin",
                    "location_id": LOCATION_ID,
                    "name": "Controlled Admin",
                }
            }
        if function_name == "forecast_product_context_v1":
            return dict(self.product_context)
        if function_name == "forecast_replenishment_config_v1":
            if not self.replenishment_dependency_available:
                raise ReplenishmentConfigurationUnavailableError(
                    "Task 3 replenishment configuration migration is unavailable"
                )
            return dict(self.replenishment_config)
        raise AssertionError("Unexpected direct RPC")

    def rpc(self, function_name: str, params: Mapping[str, Any]) -> _Request:
        self.calls.append((function_name, dict(params)))
        if function_name != "forecast_daily_demand_v1":
            raise AssertionError("Unexpected history RPC")
        self.history_rpc_calls += 1
        return _Request([])


class CoalescingSupabaseClient(ControlledSupabaseClient):
    def __init__(self) -> None:
        super().__init__()
        self.history_started = Event()
        self.release_history = Event()
        self.second_product_context_seen = Event()
        self._counter_lock = Lock()
        self._product_context_calls = 0

    def call_rpc(
        self,
        function_name: str,
        params: Mapping[str, Any],
        *,
        authentication_rpc: bool = False,
    ) -> Any:
        if function_name == "forecast_product_context_v1":
            with self._counter_lock:
                self._product_context_calls += 1
                if self._product_context_calls >= 2:
                    self.second_product_context_seen.set()
        return super().call_rpc(
            function_name,
            params,
            authentication_rpc=authentication_rpc,
        )

    def rpc(self, function_name: str, params: Mapping[str, Any]):
        self.calls.append((function_name, dict(params)))
        if function_name != "forecast_daily_demand_v1":
            raise AssertionError("Unexpected history RPC")
        with self._counter_lock:
            self.history_rpc_calls += 1
        owner = self

        class BlockingRequest:
            def execute(self) -> _Result:
                owner.history_started.set()
                if not owner.release_history.wait(timeout=2):
                    raise AssertionError("Controlled history load was not released")
                return _Result([])

        return BlockingRequest()


def production_settings() -> ApiSettings:
    return ApiSettings(
        mode="supabase",
        supabase_url="https://controlled.invalid",
        supabase_publishable_key="controlled-publishable-key",
        request_timeout_seconds=1,
        review_period_days=7,
        policy_version="stage5e-controlled-policy",
        synthetic_session_token="",
        deployment_environment="production",
        synthetic_mode_enabled=False,
    )


class SupabaseColdStartAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.upstream = ControlledSupabaseClient()
        self.adapter = SupabaseForecastAdapter(production_settings())
        self.adapter._client = self.upstream  # controlled dependency, no network
        self.service = ForecastAnalysisService(self.adapter)

    def test_empty_rpc_history_is_no_history_without_writes(self) -> None:
        body = self.service.analyze(
            session_token="opaque-app-session",
            requested_location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            model="mean28",
            horizon_days=28,
            now=NOW,
        )

        self.assertEqual(body["forecast"]["total_quantity"], 0.0)
        self.assertEqual(body["forecast"]["provenance"], "real")
        self.assertEqual(body["forecast"]["cold_start"]["reason"], "no_history")
        self.assertTrue(
            body["forecast"]["cold_start"]["zero_is_unknown_demand"]
        )
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIsNone(
            body["recommendation"]["suggested_quantity"]["inventory_units"]
        )
        self.assertEqual(
            [name for name, _ in self.upstream.calls],
            [
                "profile_restore_session_v1",
                "forecast_product_context_v1",
                "forecast_daily_demand_v1",
                "forecast_replenishment_config_v1",
            ],
        )
        history_params = self.upstream.calls[-2][1]
        self.assertEqual(history_params["p_session_token"], "opaque-app-session")
        self.assertIn(
            "review_period_missing", body["recommendation"]["warnings"]
        )

    def test_unconfigured_review_period_is_not_replaced_by_api_default(self) -> None:
        profile = self.adapter.authenticate("opaque-app-session")
        context = self.adapter.load_analysis_context(
            profile=profile,
            session_token="opaque-app-session",
            product_id=PRODUCT_ID,
            now=NOW,
        )

        self.assertIsNone(context.replenishment_configuration.review_period_days)
        self.assertIsNone(context.policy.review_period_days)

    def test_adapter_requests_full_1095_day_experimental_window(self) -> None:
        profile = self.adapter.authenticate("opaque-app-session")
        self.adapter.load_analysis_context(
            profile=profile,
            session_token="opaque-app-session",
            product_id=PRODUCT_ID,
            now=NOW,
            history_days=1095,
        )

        history_params = next(
            params
            for name, params in self.upstream.calls
            if name == "forecast_daily_demand_v1"
        )
        period_start = datetime.fromisoformat(
            str(history_params["p_period_start"])
        )
        period_end = datetime.fromisoformat(str(history_params["p_period_end"]))
        self.assertEqual((period_end - period_start).days, 1095)

    def test_identical_product_analyses_reuse_location_wide_history(self) -> None:
        profile = self.adapter.authenticate("opaque-app-session")

        for _ in range(2):
            self.adapter.load_analysis_context(
                profile=profile,
                session_token="opaque-app-session",
                product_id=PRODUCT_ID,
                now=NOW,
                history_days=1095,
            )

        self.assertEqual(self.upstream.history_rpc_calls, 1)
        self.assertEqual(
            [name for name, _ in self.upstream.calls].count(
                "forecast_product_context_v1"
            ),
            2,
        )

    def test_concurrent_analyses_coalesce_one_history_rpc(self) -> None:
        upstream = CoalescingSupabaseClient()
        adapter = SupabaseForecastAdapter(production_settings())
        adapter._client = upstream
        profile = adapter.authenticate("opaque-app-session")

        def load():
            return adapter.load_analysis_context(
                profile=profile,
                session_token="opaque-app-session",
                product_id=PRODUCT_ID,
                now=NOW,
                history_days=1095,
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(load)
            self.assertTrue(upstream.history_started.wait(timeout=1))
            second = executor.submit(load)
            self.assertTrue(upstream.second_product_context_seen.wait(timeout=1))
            self.assertEqual(upstream.history_rpc_calls, 1)
            upstream.release_history.set()
            first.result(timeout=2)
            second.result(timeout=2)

        self.assertEqual(upstream.history_rpc_calls, 1)

    def test_missing_config_rpc_keeps_analysis_available_and_needs_review(self) -> None:
        self.upstream.replenishment_dependency_available = False

        body = self.service.analyze(
            session_token="opaque-app-session",
            requested_location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            model="mean28",
            horizon_days=28,
            now=NOW,
        )

        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertFalse(
            body["replenishment_configuration"]["persistence_available"]
        )
        self.assertFalse(body["replenishment_configuration"]["configured"])

    def test_product_context_must_match_authenticated_location(self) -> None:
        self.upstream.product_context["location_id"] = (
            "22222222-2222-4222-8222-222222222222"
        )

        with self.assertRaisesRegex(
            DataUnavailableError, "outside the session location"
        ):
            self.service.analyze(
                session_token="opaque-app-session",
                requested_location_id=LOCATION_ID,
                product_id=PRODUCT_ID,
                model="mean28",
                horizon_days=28,
                now=NOW,
            )

        self.assertNotIn(
            "forecast_daily_demand_v1",
            [name for name, _ in self.upstream.calls],
        )

    def test_product_context_does_not_invent_missing_units(self) -> None:
        self.upstream.product_context["unit"] = None

        with self.assertRaisesRegex(DataUnavailableError, "identity is incomplete"):
            self.service.analyze(
                session_token="opaque-app-session",
                requested_location_id=LOCATION_ID,
                product_id=PRODUCT_ID,
                model="mean28",
                horizon_days=28,
                now=NOW,
            )

    def test_replenishment_configuration_must_match_authorized_scope(self) -> None:
        self.upstream.replenishment_config["location_id"] = (
            "22222222-2222-4222-8222-222222222222"
        )

        with self.assertRaisesRegex(
            DataUnavailableError, "outside the authorized scope"
        ):
            self.service.analyze(
                session_token="opaque-app-session",
                requested_location_id=LOCATION_ID,
                product_id=PRODUCT_ID,
                model="mean28",
                horizon_days=28,
                now=NOW,
            )

    def test_confirmed_manual_input_is_metadata_not_sales_history(self) -> None:
        body = self.service.analyze(
            session_token="opaque-app-session",
            requested_location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            model="mean28",
            horizon_days=28,
            now=NOW,
            manual_daily_demand=Decimal("2.5"),
            manual_unit="pcs",
            manual_rationale="Opening-week shelf plan",
            manual_confirmed=True,
        )

        self.assertEqual(body["forecast"]["total_quantity"], 0.0)
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        manual = body["recommendation"]["manual_demand_estimate"]
        self.assertEqual(manual["daily_quantity"], 2.5)
        self.assertTrue(manual["staff_confirmed"])
        self.assertFalse(manual["creates_historical_sales"])
        self.assertEqual(
            [name for name, _ in self.upstream.calls].count(
                "forecast_daily_demand_v1"
            ),
            1,
        )

    def test_configured_inputs_flow_into_existing_recommendation_engine(self) -> None:
        self.upstream.replenishment_config.update(
            {
                "configured": True,
                "supplier_lead_time_days": 5,
                "review_period_days": 7,
                "safety_stock": 5,
                "minimum_order_quantity": 2,
                "supplier_pack_size": 2,
                "supplier_order_unit": "box",
                "unit_conversion_factor": 2,
                "confirmed_incoming_quantity": 10,
                "incoming_quantity_verified": True,
                "backorder_quantity": 2,
                "backorder_quantity_verified": True,
                "supplier_availability": "available",
                "data_source": "admin_estimate",
                "source_captured_at": NOW.isoformat(),
                "rationale": "Reviewed supplier estimate",
                "updated_at": NOW.isoformat(),
                "updated_by_profile_id": "admin-1",
            }
        )

        body = self.service.analyze(
            session_token="opaque-app-session",
            requested_location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            model="mean28",
            horizon_days=28,
            now=NOW,
            manual_daily_demand=Decimal("2.5"),
            manual_unit="pcs",
            manual_rationale="Opening-week estimate",
            manual_confirmed=True,
        )

        recommendation = body["recommendation"]
        self.assertEqual(recommendation["inventory_position"], 28.0)
        self.assertEqual(recommendation["protection_period_days"], 12)
        self.assertEqual(
            recommendation["suggested_quantity"]["order_units"], 4.0
        )
        self.assertEqual(
            recommendation["suggested_quantity"]["inventory_units"], 8.0
        )
        self.assertEqual(
            body["replenishment_configuration"]["data_source"],
            "admin_estimate",
        )

    def test_stale_configuration_remains_needs_review(self) -> None:
        old = NOW - timedelta(days=31)
        self.upstream.replenishment_config.update(
            {
                "configured": True,
                "supplier_lead_time_days": 5,
                "review_period_days": 7,
                "safety_stock": 5,
                "minimum_order_quantity": 2,
                "supplier_pack_size": 2,
                "supplier_order_unit": "pcs",
                "unit_conversion_factor": None,
                "confirmed_incoming_quantity": 0,
                "incoming_quantity_verified": True,
                "backorder_quantity": 0,
                "backorder_quantity_verified": True,
                "supplier_availability": "available",
                "data_source": "verified_record",
                "source_captured_at": old.isoformat(),
                "rationale": "Supplier record captured last month",
                "updated_at": old.isoformat(),
                "updated_by_profile_id": "admin-1",
            }
        )

        body = self.service.analyze(
            session_token="opaque-app-session",
            requested_location_id=LOCATION_ID,
            product_id=PRODUCT_ID,
            model="mean28",
            horizon_days=28,
            now=NOW,
            manual_daily_demand=Decimal("2.5"),
            manual_unit="pcs",
            manual_rationale="Opening-week estimate",
            manual_confirmed=True,
        )

        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIn(
            "supplier_snapshot_stale", body["recommendation"]["warnings"]
        )
        self.assertIn(
            "safety_stock_stale", body["recommendation"]["warnings"]
        )
        self.assertIn(
            "inventory_snapshot_stale", body["recommendation"]["warnings"]
        )


class SupabaseRestClientDependencyTests(unittest.TestCase):
    def test_failed_rpc_records_function_and_page_stage(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                503,
                json={"message": "controlled upstream overload"},
            )

        client = SupabaseRestClient(
            url="https://controlled.invalid",
            publishable_key="controlled-publishable-key",
            timeout_seconds=1,
        )
        client._client.close()
        client._client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client._client.close)

        with self.assertRaises(DataUnavailableError) as raised:
            client.call_rpc(
                "forecast_daily_demand_v1",
                {},
                row_offset=2000,
                row_limit=1000,
            )

        self.assertEqual(
            raised.exception.stage,
            "supabase_rpc:forecast_daily_demand_v1:page_offset=2000",
        )

    def test_set_returning_rpc_reads_past_supabase_row_cap(self) -> None:
        source_rows = [{"row_number": index} for index in range(1001)]
        requested_offsets: list[int] = []

        def handler(request: httpx.Request) -> httpx.Response:
            offset = int(request.url.params["offset"])
            limit = int(request.url.params["limit"])
            requested_offsets.append(offset)
            return httpx.Response(
                200,
                json=source_rows[offset : offset + limit],
            )

        client = SupabaseRestClient(
            url="https://controlled.invalid",
            publishable_key="controlled-publishable-key",
            timeout_seconds=1,
        )
        client._client.close()
        client._client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client._client.close)

        response = client.rpc("forecast_daily_demand_v1", {}).execute()

        self.assertEqual(response.data, source_rows)
        self.assertEqual(requested_offsets, [0, 1000])

    def test_set_returning_rpc_paginates_four_year_multi_product_history(self) -> None:
        source_rows = [{"row_number": index} for index in range(35064)]
        requested_offsets: list[int] = []

        def handler(request: httpx.Request) -> httpx.Response:
            offset = int(request.url.params["offset"])
            limit = int(request.url.params["limit"])
            requested_offsets.append(offset)
            return httpx.Response(
                200,
                json=source_rows[offset : offset + limit],
            )

        client = SupabaseRestClient(
            url="https://controlled.invalid",
            publishable_key="controlled-publishable-key",
            timeout_seconds=1,
        )
        client._client.close()
        client._client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client._client.close)

        response = client.rpc("forecast_daily_demand_v1", {}).execute()

        self.assertEqual(len(response.data), 35064)
        self.assertEqual(requested_offsets[0], 0)
        self.assertEqual(requested_offsets[-1], 35000)
        self.assertEqual(len(requested_offsets), 36)

    def test_paginated_rpc_rows_reach_mean28_for_all_staging_products(self) -> None:
        location_id = "11111111-1111-1111-1111-111111111111"
        products = (
            ("22222222-2222-2222-2222-222222222221", "SKU-001", "pcs", 189),
            ("22222222-2222-2222-2222-222222222222", "SKU-002", "kl", 196),
            ("7019350c-b165-4d15-ae39-b0ab49341387", "SKU-1004", "pcs", 69),
            ("082643c4-0215-4a9a-a6aa-b99c070bddb7", "SKU-1005", "pcs", 188),
            ("52ab3702-b00b-4969-9fe7-a41f96bd3441", "SKU-1006", "pcs", 89),
            ("d9e9be8f-11be-4487-a46e-751d6c26f0ed", "SKU-1007", "pcs", 4),
            ("c9b9ee63-6c49-46b5-97e9-e0227391eda4", "SKU-1008", "pcs", 65),
            ("f9bac670-bd17-43c7-8416-78e386239a89", "SKU-1009", "roll", 269),
            ("fb9f102b-c418-40c1-9e4e-52e4d963d4fa", "SKU-1010", "pcs", 131),
            ("ab0af441-e26b-4d9c-95b3-7b5fd0e42be1", "SKU-3UWPD0GN", "pcs", 36),
            ("90a2f7df-01a5-40a4-abaf-7e1615949f28", "SKU-4W6D3LVI", "pcs", 0),
            ("e1b81338-b56e-46c6-bbfe-fa6eab25f394", "SKU-69QAUJ4Z", "pcs", 0),
            ("a2df295b-5fbc-4dd3-bd49-f3737627dd00", "SKU-K1CB7XQV", "kl", 17),
        )
        source_rows: list[dict[str, object]] = []
        older_start = date(2025, 11, 9)
        for day_offset in range(337):
            for product_id, sku, unit, _ in products[:4]:
                source_rows.append(
                    {
                        "business_date": (
                            older_start + timedelta(days=day_offset)
                        ).isoformat(),
                        "location_id": location_id,
                        "product_id": product_id,
                        "sku": sku,
                        "product_name": sku,
                        "unit": unit,
                        "quantity": "1",
                        "completed_order_count": 1,
                    }
                )
        for product_id, sku, unit, last_28_quantity in products:
            if last_28_quantity > 0:
                source_rows.append(
                    {
                        "business_date": "2026-11-07",
                        "location_id": location_id,
                        "product_id": product_id,
                        "sku": sku,
                        "product_name": sku,
                        "unit": unit,
                        "quantity": str(last_28_quantity),
                        "completed_order_count": 1,
                    }
                )
            elif sku == "SKU-4W6D3LVI":
                source_rows.append(
                    {
                        "business_date": "2026-01-01",
                        "location_id": location_id,
                        "product_id": product_id,
                        "sku": sku,
                        "product_name": sku,
                        "unit": unit,
                        "quantity": "1",
                        "completed_order_count": 1,
                    }
                )
        source_rows.sort(key=lambda row: (row["business_date"], row["product_id"]))

        def handler(request: httpx.Request) -> httpx.Response:
            offset = int(request.url.params["offset"])
            limit = int(request.url.params["limit"])
            return httpx.Response(200, json=source_rows[offset : offset + limit])

        client = SupabaseRestClient(
            url="https://controlled.invalid",
            publishable_key="controlled-publishable-key",
            timeout_seconds=1,
        )
        client._client.close()
        client._client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client._client.close)
        parsed = parse_rpc_daily_demand(
            client.rpc("forecast_daily_demand_v1", {}).execute().data
        )

        forecaster = Mean28Forecaster()
        for product_id, sku, unit, last_28_quantity in products:
            observations = [row for row in parsed if row.product_id == product_id]
            dataset = HistoricalDemandDataset.from_real_observations(
                product=ForecastProduct(
                    location_id=location_id,
                    product_id=product_id,
                    sku=sku,
                    product_name=sku,
                    unit=unit,
                ),
                history_start=(older_start if observations else None),
                history_end=date(2026, 11, 8),
                observations=observations,
            )
            forecasts = forecaster.forecast(dataset, horizon_days=28)
            self.assertEqual(forecasts[0].unit, unit, sku)
            self.assertEqual(
                forecasts[0].quantity,
                Decimal(last_28_quantity) / Decimal(28),
                sku,
            )
            self.assertAlmostEqual(
                float(sum((point.quantity for point in forecasts), Decimal("0"))),
                float(last_28_quantity),
                places=9,
                msg=sku,
            )

    def test_missing_config_function_is_a_specific_dependency_error(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                404,
                json={
                    "code": "PGRST202",
                    "message": (
                        "Could not find the function public."
                        "forecast_replenishment_config_v1"
                    ),
                },
            )

        client = SupabaseRestClient(
            url="https://controlled.invalid",
            publishable_key="controlled-publishable-key",
            timeout_seconds=1,
        )
        client._client.close()
        client._client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client._client.close)

        with self.assertRaisesRegex(
            ReplenishmentConfigurationUnavailableError,
            "stage_5f_forecast_replenishment_configuration.sql",
        ):
            client.call_rpc(
                "forecast_replenishment_config_v1",
                {"p_session_token": "opaque", "p_product_id": PRODUCT_ID},
            )


if __name__ == "__main__":
    unittest.main()
