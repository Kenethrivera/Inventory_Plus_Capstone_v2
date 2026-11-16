from __future__ import annotations

import unittest
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

from app.api import create_app
from app.api.adapters import SyntheticDevelopmentAdapter
from app.api.contracts import DataUnavailableError
from app.api.snapshot_reads import ForecastSnapshotReadRepository
from app.api.settings import ApiSettings


TOKEN = "snapshot-read-test-admin-token"


def synthetic_settings() -> ApiSettings:
    return ApiSettings(
        mode="synthetic",
        supabase_url=None,
        supabase_publishable_key=None,
        request_timeout_seconds=1,
        review_period_days=7,
        policy_version="snapshot-read-test",
        synthetic_session_token=TOKEN,
        deployment_environment="test",
        synthetic_mode_enabled=True,
    )


def snapshot_settings() -> ApiSettings:
    return ApiSettings(
        mode="supabase",
        supabase_url="https://project.example.test",
        supabase_publishable_key="sb_publishable_test",
        supabase_secret_key="sb_secret_test",
        request_timeout_seconds=1,
        review_period_days=7,
        policy_version="snapshot-read-test",
        synthetic_session_token="",
        deployment_environment="test",
        forecast_snapshot_reads_enabled=True,
    )


class RecordingSnapshotRepository:
    def __init__(self) -> None:
        self.overview_calls: list[dict[str, object]] = []
        self.product_calls: list[dict[str, object]] = []

    def overview(self, **kwargs):
        self.overview_calls.append(kwargs)
        return {
            "page": kwargs["page"],
            "page_size": kwargs["page_size"],
            "total_count": 0,
            "page_count": 0,
            "items": [],
        }

    def product(self, **kwargs):
        self.product_calls.append(kwargs)
        return {"items": [{"status": "queued", "product": {"product_id": kwargs["product_id"]}}]}


class RecordingTrackingReader:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def tracking(self, **kwargs):
        self.calls.append(kwargs)
        return []


class ReadOnlyForecastAdapter(SyntheticDevelopmentAdapter):
    def load_analysis_context(self, **kwargs):
        raise AssertionError("snapshot reads must not load demand history or fit models")


class SnapshotReadApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = ReadOnlyForecastAdapter(synthetic_settings())
        self.repository = RecordingSnapshotRepository()
        self.patch_repository = patch(
            "app.api.main.ForecastSnapshotReadRepository",
            return_value=self.repository,
        )
        self.patch_repository.start()
        self.addCleanup(self.patch_repository.stop)
        self.app = create_app(adapter=self.adapter, settings=snapshot_settings())
        self.client = TestClient(self.app)

    def test_overview_is_authorized_bounded_and_single_read(self) -> None:
        response = self.client.get(
            "/v1/forecasting/snapshots/overview",
            params={"page": 2, "page_size": 25, "unit": "pcs"},
            headers={"Authorization": f"Bearer {TOKEN}"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["total_count"], 0)
        self.assertEqual(len(self.repository.overview_calls), 1)
        call = self.repository.overview_calls[0]
        self.assertEqual(call["page"], 2)
        self.assertEqual(call["page_size"], 25)
        self.assertEqual(call["model_key"], "blend")
        self.assertEqual(call["location_id"], self.adapter.authenticate(TOKEN).location_id)

        wrong_scope = self.client.get(
            "/v1/forecasting/snapshots/overview",
            params={"location_id": "another-location"},
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        self.assertEqual(wrong_scope.status_code, 403)
        self.assertEqual(len(self.repository.overview_calls), 1)

    def test_product_snapshot_requires_admin_session_and_uses_scoped_read(self) -> None:
        denied = self.client.get(
            "/v1/forecasting/products/31000000-0000-4000-8000-000000000001/snapshot",
            headers={"Authorization": "Bearer expired-token"},
        )
        self.assertEqual(denied.status_code, 401)
        self.assertEqual(self.repository.product_calls, [])

        response = self.client.get(
            "/v1/forecasting/products/31000000-0000-4000-8000-000000000001/snapshot",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.repository.product_calls), 1)
        self.assertEqual(
            self.repository.product_calls[0]["location_id"],
            self.adapter.authenticate(TOKEN).location_id,
        )

    def test_completed_product_uses_saved_bundle_and_operational_context_only(self) -> None:
        product_id = "31000000-0000-4000-8000-000000000001"
        self.repository.product = lambda **kwargs: {
            "items": [{
                "status": "completed",
                "product": {"product_id": product_id},
                "snapshot": {"result_id": "saved-result", "bundle": {"outputs": {}}},
            }],
        }
        with patch.object(
            self.adapter, "load_operational_context", return_value=object(),
            create=True,
        ) as load_operational, patch(
            "app.api.main.current_stock_analysis",
            return_value={"schema_version": "stage5d-v1"},
        ) as guidance:
            response = self.client.get(
                f"/v1/forecasting/products/{product_id}/snapshot",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["analysis"]["schema_version"], "stage5d-v1")
        load_operational.assert_called_once()
        guidance.assert_called_once()
        self.assertEqual(guidance.call_args.kwargs["snapshot"]["bundle"], {"outputs": {}})

    def test_stale_snapshot_keeps_chart_but_withholds_actionable_guidance(self) -> None:
        product_id = "31000000-0000-4000-8000-000000000001"
        self.repository.product = lambda **kwargs: {
            "items": [{"status": "stale", "snapshot": {"bundle": {"outputs": {}}}}],
        }
        saved = {
            "forecast": {"daily": [{"date": "2026-11-13", "quantity": 3}]},
            "preliminary_restocking_insight": {"status": "ready", "suggested_restock_quantity": 5, "limitations": []},
            "recommendation": {"status": "ready", "suggested_quantity": {"inventory_units": 5, "order_units": 5}, "warnings": []},
        }
        with patch.object(self.adapter, "load_operational_context", return_value=object(), create=True), patch(
            "app.api.main.current_stock_analysis", return_value=saved,
        ):
            response = self.client.get(
                f"/v1/forecasting/products/{product_id}/snapshot",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
        self.assertEqual(response.status_code, 200)
        result = response.json()["analysis"]
        self.assertEqual(result["forecast"]["daily"], [{"date": "2026-11-13", "quantity": 3}])
        self.assertIsNone(result["preliminary_restocking_insight"]["suggested_restock_quantity"])
        self.assertIsNone(result["recommendation"]["suggested_quantity"]["inventory_units"])
        self.assertIn("stale_saved_demand", result["recommendation"]["warnings"])

    def test_bootstrap_reuses_exact_current_result_without_materialization(self):
        from dataclasses import replace
        from types import SimpleNamespace
        from unittest.mock import Mock
        materializer = Mock()
        materializer._identity = SimpleNamespace(model_key="blend",model_version="1",config_digest="a"*64,implementation_digest="b"*64)
        self.adapter.list_active_products = lambda **kwargs: ()
        self.repository.product = lambda **kwargs: {"items":[{
            "status":"completed", "snapshot":{"result_id":"saved", "horizon_days":28,"history_window_days":365,
            "as_of_business_date":"2026-11-14", "requested_model":{"key":"blend","version":"1","config_digest":"a"*64,"implementation_digest":"b"*64}}}]}
        with patch("app.api.main.SupabaseForecastJobRepository"), patch("app.api.main.ForecastJobMaterializer",return_value=materializer):
            app = create_app(adapter=self.adapter,settings=replace(snapshot_settings(),forecast_job_materialization_enabled=True))
        response = TestClient(app).post("/v1/forecasting/jobs/bootstrap",params={"product_id":"31000000-0000-4000-8000-000000000001"},headers={"Authorization":f"Bearer {TOKEN}"})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.json()["result_id"],"saved")
        self.assertEqual(response.json()["jobs"][0]["status"],"succeeded")
        materializer.bootstrap.assert_not_called()

    def test_manual_preview_requires_admin_and_passes_confirmed_input(self) -> None:
        product_id = "31000000-0000-4000-8000-000000000001"
        self.repository.product = lambda **kwargs: {
            "items": [{"status": "completed", "snapshot": {"bundle": {"outputs": {}}}}],
        }
        path = f"/v1/forecasting/products/{product_id}/snapshot-guidance"
        body = {
            "location_id": self.adapter.authenticate(TOKEN).location_id,
            "model": "blend", "manual_daily_demand": 3,
            "manual_unit": "pcs", "manual_rationale": "Opening plan",
            "manual_confirmed": True,
        }
        self.assertEqual(self.client.post(path, json=body).status_code, 401)
        with patch.object(
            self.adapter, "load_operational_context", return_value=object(), create=True,
        ), patch(
            "app.api.main.current_stock_analysis", return_value={"schema_version": "stage5d-v1"},
        ) as guidance:
            response = self.client.post(
                path, json=body, headers={"Authorization": f"Bearer {TOKEN}"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(guidance.call_args.kwargs["manual_daily_demand"], 3)
        self.assertTrue(guidance.call_args.kwargs["manual_confirmed"])

    def test_snapshot_routes_are_registered_once(self) -> None:
        paths = [route.path for route in self.app.routes]
        self.assertEqual(paths.count("/v1/forecasting/snapshots/overview"), 1)
        self.assertEqual(paths.count("/v1/forecasting/products/{product_id}/snapshot"), 1)
        self.assertEqual(paths.count("/v1/forecasting/products/{product_id}/snapshot-guidance"), 1)

    def test_snapshot_mode_keeps_tracking_reads_without_enabling_writes(self) -> None:
        reader = RecordingTrackingReader()
        with patch(
            "app.api.main.SupabaseRecommendationTrackingReader", return_value=reader
        ):
            app = create_app(adapter=self.adapter, settings=snapshot_settings())
        client = TestClient(app)
        headers = {"Authorization": f"Bearer {TOKEN}"}
        recommendations = client.get("/v1/forecasting/recommendations", headers=headers)
        performance = client.get(
            "/v1/forecasting/forecast-performance",
            params={"product_id": "31000000-0000-4000-8000-000000000001"},
            headers=headers,
        )
        self.assertEqual(recommendations.status_code, 200)
        self.assertEqual(recommendations.json()["items"], [])
        self.assertEqual(performance.status_code, 200)
        self.assertEqual(performance.json()["items"], [])
        self.assertEqual(len(reader.calls), 2)
        self.assertEqual(
            client.get("/v1/forecasting/recommendations").status_code, 401
        )

    def test_both_tracking_routes_explain_disabled_reader(self) -> None:
        app = create_app(adapter=self.adapter, settings=synthetic_settings())
        client = TestClient(app)
        headers = {"Authorization": f"Bearer {TOKEN}"}
        recommendations = client.get("/v1/forecasting/recommendations", headers=headers)
        performance = client.get(
            "/v1/forecasting/forecast-performance",
            params={"product_id": "31000000-0000-4000-8000-000000000001"},
            headers=headers,
        )
        self.assertEqual(recommendations.status_code, 503)
        self.assertEqual(performance.status_code, 503)
        self.assertEqual(recommendations.json()["detail"], "Recommendation tracking is not activated")
        self.assertEqual(performance.json()["detail"], "Recommendation tracking is not activated")


class SnapshotRepositoryTests(unittest.TestCase):
    def test_secret_key_uses_server_only_headers_and_parses_result(self) -> None:
        captured: list[httpx.Request] = []

        def respond(request: httpx.Request) -> httpx.Response:
            captured.append(request)
            return httpx.Response(
                200,
                json={
                    "page": 1,
                    "page_size": 25,
                    "total_count": 0,
                    "page_count": 0,
                    "items": [],
                },
            )

        client = httpx.Client(transport=httpx.MockTransport(respond))
        repository = ForecastSnapshotReadRepository(
            url="https://project.example.test",
            secret_key="sb_secret_test",
            timeout_seconds=1,
            client=client,
        )
        self.addCleanup(repository.close)

        result = repository.overview(
            location_id="location-1",
            model_key="blend",
            page=1,
            page_size=25,
        )

        self.assertEqual(result["total_count"], 0)
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0].headers["apikey"], "sb_secret_test")
        self.assertNotIn("authorization", captured[0].headers)
        self.assertEqual(captured[0].url.path, "/rest/v1/rpc/forecast_snapshot_page_v1")

    def test_upstream_rpc_error_is_not_returned_as_success(self) -> None:
        client = httpx.Client(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(403, json={"message": "permission denied"})
            )
        )
        repository = ForecastSnapshotReadRepository(
            url="https://project.example.test",
            secret_key="sb_secret_test",
            timeout_seconds=1,
            client=client,
        )
        self.addCleanup(repository.close)

        with self.assertRaises(DataUnavailableError):
            repository.product(
                location_id="location-1",
                product_id="product-1",
                model_key="blend",
            )


if __name__ == "__main__":
    unittest.main()
