"""Read-only forecast job monitor contracts. No database connection required."""
from __future__ import annotations

import unittest
from datetime import date
from unittest.mock import Mock, patch

import httpx
from fastapi.testclient import TestClient

from app.api import create_app
from app.api.contracts import AuthenticationError, SessionProfile
from app.api.job_monitoring import ForecastJobReadRepository
from app.api.settings import ApiSettings


LOCATION = "11111111-1111-4111-8111-111111111111"


def fixture() -> dict:
    return {
        "page": 1, "page_size": 25, "total_count": 1, "page_count": 1,
        "latest_only": False, "generated_at": "2026-11-22T01:00:00Z",
        "counts": {"total_jobs": 1, "queued": 0, "retry_pending": 0,
                   "running": 0, "succeeded": 0, "failed": 1,
                   "cancelled": 0, "superseded": 0},
        "items": [{
            "job_id": "job-1", "product_id": "product-1", "status": "failed",
            "display_status": "failed", "model_key": "lightgbm",
            "created_at": "2026-11-21T01:00:00Z",
            "safe_error_code": "forecast_input_unavailable",
            "lease_token": "must-never-be-returned",
            "output_bundle": {"private": "must-never-be-returned"},
        }],
    }


class _Adapter:
    role = "admin"

    def authenticate(self, token: str) -> SessionProfile:
        if token != "valid-session":
            raise AuthenticationError("Session invalid")
        return SessionProfile(profile_id="admin", role=self.role,
                              location_id=LOCATION, name="Admin")


class ForecastJobMonitoringTests(unittest.TestCase):
    def test_repository_scopes_rpc_and_removes_private_fields(self) -> None:
        captured = []

        def handle(request: httpx.Request) -> httpx.Response:
            captured.append(request)
            return httpx.Response(200, json=fixture())

        client = httpx.Client(transport=httpx.MockTransport(handle))
        reader = ForecastJobReadRepository(url="https://example.supabase.co",
            secret_key="sb_secret_test-only", timeout_seconds=1, client=client)
        result = reader.page(location_id=LOCATION, page=1, page_size=25,
            latest_only=False, search="SIM", model_key="lightgbm",
            status="failed", from_date=date(2026, 11, 1), to_date=date(2026, 11, 22))
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0].url.path, "/rest/v1/rpc/forecast_jobs_page_v1")
        self.assertIn(LOCATION, captured[0].content.decode())
        self.assertEqual(result["items"][0]["safe_error_code"], "forecast_input_unavailable")
        self.assertNotIn("lease_token", result["items"][0])
        self.assertNotIn("output_bundle", result["items"][0])

    def test_api_derives_location_and_rejects_unauthorized_roles(self) -> None:
        settings = ApiSettings(mode="supabase", supabase_url="https://example.supabase.co",
            supabase_publishable_key="publishable-test", supabase_secret_key="sb_secret_test-only",
            request_timeout_seconds=1, review_period_days=7, policy_version="test",
            synthetic_session_token="", deployment_environment="test",
            forecast_snapshot_reads_enabled=True)
        adapter = _Adapter()
        reader = Mock()
        reader.page.return_value = fixture()
        with patch("app.api.main.ForecastSnapshotReadRepository"), \
             patch("app.api.main.ForecastJobReadRepository", return_value=reader):
            api = TestClient(create_app(adapter=adapter, settings=settings))
            response = api.get("/v1/forecasting/jobs",
                params={"latest_only": "false", "model": "lightgbm",
                        "status": "failed", "page": 1},
                headers={"Authorization": "Bearer valid-session"})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(reader.page.call_args.kwargs["location_id"], LOCATION)
            self.assertEqual(reader.page.call_args.kwargs["status"], "failed")
            self.assertEqual(api.get("/v1/forecasting/jobs",
                headers={"Authorization": "Bearer invalid"}).status_code, 401)
            adapter.role = "staff"
            self.assertEqual(api.get("/v1/forecasting/jobs",
                headers={"Authorization": "Bearer valid-session"}).status_code, 403)
            self.assertEqual(reader.page.call_count, 1)
