from __future__ import annotations

import os
import unittest
from datetime import datetime, timezone

from app.api.adapters import SupabaseForecastAdapter, SupabaseRestClient
from app.api.contracts import ApiDataError, AuthorizationError
from app.api.service import ForecastAnalysisService
from app.api.settings import ApiSettings
from app.data.sales_repository import SalesRepository
from app.data.validation import DemandDataError
from app.data.preprocessing import fill_missing_days


LOCATION_A = "61000000-0000-4000-8000-000000000001"
LOCATION_B = "61000000-0000-4000-8000-000000000002"
PRODUCT_A = "61a00000-0000-4000-8000-000000000001"
NO_HISTORY_PRODUCT = "61a00000-0000-4000-8000-000000000002"


class IsolatedStage6BTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        marker = os.getenv("STAGE6B_TEST_ENVIRONMENT_MARKER", "").strip()
        test_url = os.getenv("STAGE6B_TEST_SUPABASE_URL", "").strip()
        test_key = os.getenv("STAGE6B_TEST_SUPABASE_PUBLISHABLE_KEY", "").strip()
        production_url = os.getenv("STAGE6B_PRODUCTION_SUPABASE_URL", "").strip()
        test_project_ref = os.getenv("STAGE6B_TEST_PROJECT_REF", "").strip()
        production_project_ref = os.getenv(
            "STAGE6B_PRODUCTION_PROJECT_REF", ""
        ).strip()
        configured = any(
            (
                marker,
                test_url,
                test_key,
                production_url,
                test_project_ref,
                production_project_ref,
            )
        )
        if not configured:
            raise unittest.SkipTest("isolated Stage 6B environment is not configured")
        if marker != "inventory-plus-stage6b":
            raise RuntimeError("Stage 6B isolated environment marker is invalid")
        if not all(
            (
                test_url,
                test_key,
                production_url,
                test_project_ref,
                production_project_ref,
            )
        ):
            raise RuntimeError(
                "Stage 6B test and production URL/project guards are required"
            )
        if test_url.rstrip("/").lower() == production_url.rstrip("/").lower():
            raise RuntimeError("Stage 6B test URL must not equal the production URL")
        if test_project_ref.lower() == production_project_ref.lower():
            raise RuntimeError(
                "Stage 6B test project must not equal the production project"
            )

        identity_client = SupabaseRestClient(
            url=test_url,
            publishable_key=test_key,
            timeout_seconds=10,
        )
        identity = identity_client.call_rpc(
            "stage6b_test_environment_identity_v1", {}
        )
        if not isinstance(identity, dict):
            raise RuntimeError("Stage 6B isolated database identity is unavailable")
        if (
            identity.get("marker") != "inventory-plus-stage6b"
            or identity.get("project_ref") != test_project_ref
            or identity.get("purpose")
            != "inventory-plus-stage6b-isolated-integration"
            or identity.get("fixture_writes_authorized") is not True
        ):
            raise RuntimeError("Stage 6B isolated database identity is not authorized")

        cls.settings = ApiSettings(
            mode="supabase",
            supabase_url=test_url,
            supabase_publishable_key=test_key,
            request_timeout_seconds=10,
            review_period_days=7,
            policy_version="stage6b-isolated-v1",
            synthetic_session_token="",
            deployment_environment="test",
            synthetic_mode_enabled=False,
        )
        cls.client = SupabaseRestClient(
            url=test_url,
            publishable_key=test_key,
            timeout_seconds=10,
        )
        cls.adapter = SupabaseForecastAdapter(cls.settings)
        cls.service = ForecastAnalysisService(cls.adapter)

    def test_admin_rpc_exact_aggregation_boundaries_and_zero_fill(self) -> None:
        rows = SalesRepository(self.client, "stage6b-admin-a").daily_demand(
            period_start=datetime(2026, 10, 31, 16, tzinfo=timezone.utc),
            period_end=datetime(2026, 11, 1, 16, tzinfo=timezone.utc),
        )
        product = next(value for value in rows if value.product_id == PRODUCT_A)
        self.assertEqual(str(product.quantity), "7")
        self.assertEqual(product.completed_order_count, 2)
        self.assertTrue(all(value.location_id == LOCATION_A for value in rows))
        self.assertTrue(any(value.sku is None for value in rows))

        grouped = fill_missing_days(
            rows,
            start=datetime(2026, 11, 1).date(),
            end=datetime(2026, 11, 2).date(),
        )
        product_series = grouped[product.series_key]
        self.assertEqual(str(product_series[0].quantity), "7")
        self.assertEqual(str(product_series[1].quantity), "0")

        midnight = SalesRepository(self.client, "stage6b-admin-a").daily_demand(
            period_start=datetime(2026, 11, 1, 16, tzinfo=timezone.utc),
            period_end=datetime(2026, 11, 2, 16, tzinfo=timezone.utc),
        )
        self.assertEqual(str(midnight[0].quantity), "5")
        self.assertEqual(midnight[0].business_date.isoformat(), "2026-11-02")

    def test_roles_invalid_expired_and_malformed_records_fail_closed(self) -> None:
        bounds = {
            "period_start": datetime(2026, 11, 1, tzinfo=timezone.utc),
            "period_end": datetime(2026, 11, 2, tzinfo=timezone.utc),
        }
        for token in (
            "stage6b-cashier-a",
            "stage6b-helper-a",
            "stage6b-expired",
            "stage6b-invalid",
        ):
            with self.subTest(token_kind=token.rsplit("-", 1)[-1]):
                with self.assertRaises(ApiDataError):
                    SalesRepository(self.client, token).daily_demand(**bounds)

        for day in (1, 2, 3):
            with self.subTest(malformed_day=day):
                with self.assertRaises(ApiDataError):
                    SalesRepository(self.client, "stage6b-admin-b").daily_demand(
                        period_start=datetime(2026, 10, day, tzinfo=timezone.utc),
                        period_end=datetime(
                            2026, 10, day + 1, tzinfo=timezone.utc
                        ),
                    )

        with self.assertRaises(DemandDataError):
            SalesRepository(self.client, "stage6b-admin-b").daily_demand(
                period_start=datetime(2026, 10, 4, tzinfo=timezone.utc),
                period_end=datetime(2026, 10, 5, tzinfo=timezone.utc),
            )

        with self.assertRaises(ApiDataError):
            SalesRepository(self.client, "stage6b-admin-b").daily_demand(
                period_start=datetime(2026, 10, 5, tzinfo=timezone.utc),
                period_end=datetime(2026, 10, 6, tzinfo=timezone.utc),
            )

    def test_end_to_end_real_no_history_and_insufficient_history(self) -> None:
        now = datetime(2026, 11, 5, 8, tzinfo=timezone.utc)
        no_history = self.service.analyze(
            session_token="stage6b-admin-a",
            requested_location_id=LOCATION_A,
            product_id=NO_HISTORY_PRODUCT,
            model="mean28",
            horizon_days=28,
            now=now,
        )
        self.assertEqual(no_history["forecast"]["provenance"], "real")
        self.assertEqual(
            no_history["forecast"]["cold_start"]["reason"], "no_history"
        )
        self.assertTrue(
            no_history["forecast"]["cold_start"]["zero_is_unknown_demand"]
        )
        self.assertEqual(no_history["recommendation"]["status"], "needs_review")
        self.assertFalse(no_history["recommendation"]["purchase_order_created"])

        insufficient = self.service.analyze(
            session_token="stage6b-admin-a",
            requested_location_id=LOCATION_A,
            product_id=PRODUCT_A,
            model="lightgbm",
            horizon_days=28,
            now=now,
        )
        self.assertEqual(
            insufficient["forecast"]["cold_start"]["reason"],
            "insufficient_history",
        )
        self.assertEqual(insufficient["forecast"]["model"], "mean28_fallback")
        self.assertEqual(
            insufficient["recommendation"]["status"], "needs_review"
        )

    def test_location_scope_and_read_only_behavior(self) -> None:
        now = datetime(2026, 11, 5, 8, tzinfo=timezone.utc)
        with self.assertRaises(AuthorizationError):
            self.service.analyze(
                session_token="stage6b-admin-a",
                requested_location_id=LOCATION_B,
                product_id=PRODUCT_A,
                model="mean28",
                horizon_days=28,
                now=now,
            )

        product_params = {
            "p_session_token": "stage6b-admin-a",
            "p_product_id": PRODUCT_A,
        }
        before = self.client.call_rpc(
            "forecast_product_context_v1", product_params
        )
        self.service.analyze(
            session_token="stage6b-admin-a",
            requested_location_id=LOCATION_A,
            product_id=PRODUCT_A,
            model="mean28",
            horizon_days=28,
            now=now,
        )
        after = self.client.call_rpc(
            "forecast_product_context_v1", product_params
        )
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
