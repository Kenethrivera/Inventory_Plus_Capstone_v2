from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
from typing import Mapping
from unittest.mock import Mock, patch
from uuid import UUID, uuid4

from fastapi.testclient import TestClient

from app.api import create_app
from app.api.adapters import SyntheticDevelopmentAdapter
from app.api.contracts import DataUnavailableError, TrustedRecommendationSnapshot
from app.api.recommendation_persistence import SupabaseSecretRestClient
from app.api.service import ForecastAnalysisService

from .test_api import NOW, TOKEN, TransformingAdapter, settings


class MemoryPersistenceAdapter:
    def __init__(self) -> None:
        self.snapshots: dict[UUID, dict[str, object]] = {}
        self.save_calls = 0
        self.match_calls = 0
        self.reconcile_calls = 0
        self.tracking_calls = 0

    def snapshot_by_request(
        self, *, session_token: str, request_id: UUID
    ) -> Mapping[str, object] | None:
        return self.snapshots.get(request_id)

    def save_snapshot(
        self,
        *,
        session_token: str,
        request_id: UUID,
        snapshot: TrustedRecommendationSnapshot,
    ) -> Mapping[str, object]:
        self.save_calls += 1
        recommendation_id = len(self.snapshots) + 1
        self.snapshots[request_id] = existing_payload(
            request_id=request_id,
            recommendation_id=recommendation_id,
            snapshot=snapshot,
        )
        return {"recommendation_id": recommendation_id, "reused": False}

    def match_receipt(self, **kwargs) -> Mapping[str, object]:
        self.match_calls += 1
        return {"allocation_id": 7, "reused": False}

    def reconcile(self, **kwargs) -> Mapping[str, object]:
        self.reconcile_calls += 1
        return {"reconciliation_id": 9, "reused": False}

    def tracking(self, **kwargs) -> list[Mapping[str, object]]:
        self.tracking_calls += 1
        return [{"recommendation_id": 1, "evaluation_status": "pending"}]


def trusted_snapshot(adapter: TransformingAdapter) -> TrustedRecommendationSnapshot:
    return ForecastAnalysisService(adapter).trusted_preliminary_snapshot(
        session_token=TOKEN,
        requested_location_id=None,
        product_id=SyntheticDevelopmentAdapter.PRODUCT_ID,
        forecast_generated_at=NOW,
    )


def request_payload(
    snapshot: TrustedRecommendationSnapshot,
    *,
    request_id: UUID,
) -> dict[str, object]:
    return {
        "request_id": str(request_id),
        "location_id": snapshot.location_id,
        "forecast_model": snapshot.forecast_model,
        "forecast_version": snapshot.forecast_version,
        "training_history_days": snapshot.training_history_days,
        "experimental_model": snapshot.experimental_model,
        "forecast_generated_at": snapshot.forecast_generated_at.isoformat(),
        "forecast_source_data_as_of": (
            snapshot.forecast_source_data_as_of.isoformat()
        ),
        "planning_horizon_days": snapshot.planning_horizon_days,
        "forecast_period_start": snapshot.forecast_period_start.isoformat(),
        "forecast_period_end": snapshot.forecast_period_end.isoformat(),
        "predicted_demand": str(snapshot.predicted_demand),
        "available_inventory": str(snapshot.available_inventory),
        "recommended_restock_quantity": str(
            snapshot.recommended_restock_quantity
        ),
        "inventory_unit": snapshot.inventory_unit,
    }


def existing_payload(
    *,
    request_id: UUID,
    recommendation_id: int,
    snapshot: TrustedRecommendationSnapshot,
) -> dict[str, object]:
    return {
        "recommendation_id": recommendation_id,
        "request_id": str(request_id),
        "location_id_snapshot": snapshot.location_id,
        "product_id_snapshot": snapshot.product_id,
        "product_name_snapshot": "Synthetic development fixture",
        "product_sku_snapshot": "SYNTH-001",
        "inventory_unit_snapshot": snapshot.inventory_unit,
        "forecast_model": snapshot.forecast_model,
        "forecast_version": snapshot.forecast_version,
        "training_history_days": snapshot.training_history_days,
        "experimental_model": snapshot.experimental_model,
        "forecast_generated_at": snapshot.forecast_generated_at.isoformat(),
        "forecast_source_data_as_of": (
            snapshot.forecast_source_data_as_of.isoformat()
        ),
        "planning_horizon_days": snapshot.planning_horizon_days,
        "forecast_period_start": snapshot.forecast_period_start.isoformat(),
        "forecast_period_end": snapshot.forecast_period_end.isoformat(),
        "predicted_demand": str(snapshot.predicted_demand),
        "available_inventory": str(snapshot.available_inventory),
        "recommended_restock_quantity": str(
            snapshot.recommended_restock_quantity
        ),
    }


class TrustedPersistenceApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = TransformingAdapter()
        self.persistence = MemoryPersistenceAdapter()
        self.configured = replace(
            settings(),
            recommendation_persistence_enabled=True,
            supabase_secret_key="test-server-only-secret",
        )
        self.client = TestClient(
            create_app(
                adapter=self.adapter,
                recommendation_persistence_adapter=self.persistence,
                settings=self.configured,
                clock=lambda: NOW,
            )
        )
        self.snapshot = trusted_snapshot(self.adapter)
        self.product_id = SyntheticDevelopmentAdapter.PRODUCT_ID

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {TOKEN}"}

    def test_save_recomputes_and_persists_only_matching_lightgbm_candidate(self) -> None:
        request_id = uuid4()
        before = self.adapter.base.load_analysis_context(
            profile=self.adapter.base.authenticate(TOKEN),
            session_token=TOKEN,
            product_id=self.product_id,
            now=NOW,
            history_days=365,
        ).inventory.saleable_on_hand
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=request_payload(self.snapshot, request_id=request_id),
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.persistence.save_calls, 1)
        body = response.json()
        self.assertEqual(body["snapshot"]["forecast_model"], "lightgbm")
        self.assertEqual(body["snapshot"]["training_history_days"], 365)
        self.assertFalse(body["snapshot"]["experimental_model"])
        self.assertNotIn("secret", response.text.casefold())
        after = self.adapter.base.load_analysis_context(
            profile=self.adapter.base.authenticate(TOKEN),
            session_token=TOKEN,
            product_id=self.product_id,
            now=NOW,
            history_days=365,
        ).inventory.saleable_on_hand
        self.assertEqual(after, before)

    def test_forged_prediction_is_rejected_before_persistence(self) -> None:
        payload = request_payload(self.snapshot, request_id=uuid4())
        payload["predicted_demand"] = str(self.snapshot.predicted_demand + 10)
        payload["recommended_restock_quantity"] = str(
            self.snapshot.recommended_restock_quantity + 10
        )
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(response.status_code, 409, response.text)
        self.assertEqual(self.persistence.save_calls, 0)

    def test_stale_candidate_is_rejected_before_recalculation(self) -> None:
        payload = request_payload(self.snapshot, request_id=uuid4())
        payload["forecast_generated_at"] = (NOW - timedelta(days=2)).isoformat()
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(response.status_code, 422, response.text)
        self.assertIn("stale", response.text.casefold())
        self.assertEqual(self.persistence.save_calls, 0)

    def test_experimental_candidate_is_rejected_by_request_schema(self) -> None:
        payload = request_payload(self.snapshot, request_id=uuid4())
        payload["forecast_model"] = "seasonal_experimental"
        payload["experimental_model"] = True
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(self.persistence.save_calls, 0)

    def test_idempotent_retry_returns_snapshot_without_reloading_stock(self) -> None:
        request_id = uuid4()
        self.persistence.snapshots[request_id] = existing_payload(
            request_id=request_id,
            recommendation_id=42,
            snapshot=self.snapshot,
        )
        calls_before = self.adapter.load_calls
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=request_payload(self.snapshot, request_id=request_id),
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertTrue(response.json()["reused"])
        self.assertEqual(response.json()["recommendation_id"], 42)
        self.assertEqual(self.adapter.load_calls, calls_before)
        self.assertEqual(self.persistence.save_calls, 0)

    def test_conflicting_retry_is_rejected(self) -> None:
        request_id = uuid4()
        self.persistence.snapshots[request_id] = existing_payload(
            request_id=request_id,
            recommendation_id=42,
            snapshot=self.snapshot,
        )
        payload = request_payload(self.snapshot, request_id=request_id)
        payload["available_inventory"] = str(self.snapshot.available_inventory + 1)
        response = self.client.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(response.status_code, 409, response.text)

    def test_receipt_reconciliation_and_tracking_boundaries(self) -> None:
        receipt = self.client.post(
            "/v1/forecasting/recommendations/1/receipt-allocations",
            headers=self.headers,
            json={
                "location_id": self.snapshot.location_id,
                "transaction_history_id": str(uuid4()),
                "allocated_inventory_quantity": "5",
            },
        )
        self.assertEqual(receipt.status_code, 200, receipt.text)
        reconciliation = self.client.post(
            "/v1/forecasting/recommendations/1/reconcile",
            headers=self.headers,
            json={
                "request_id": str(uuid4()),
                "location_id": self.snapshot.location_id,
                "confirm_no_receipts": False,
            },
        )
        self.assertEqual(reconciliation.status_code, 200, reconciliation.text)
        tracking = self.client.get(
            "/v1/forecasting/recommendations",
            headers=self.headers,
            params={"product_id": self.product_id},
        )
        self.assertEqual(tracking.status_code, 200, tracking.text)
        self.assertEqual(tracking.json()["items"][0]["evaluation_status"], "pending")
        self.assertEqual(tracking.json()["items"][0]["forecast_model"], "lightgbm")
        self.assertEqual(tracking.json()["items"][0]["training_history_days"], 365)
        self.assertFalse(tracking.json()["items"][0]["experimental_model"])
        self.assertTrue(tracking.json()["items"][0]["assumptions"])
        self.assertEqual(self.persistence.match_calls, 1)
        self.assertEqual(self.persistence.reconcile_calls, 1)
        self.assertEqual(self.persistence.tracking_calls, 1)

    def test_disabled_boundary_returns_503_without_a_write(self) -> None:
        disabled = TestClient(
            create_app(
                adapter=self.adapter,
                settings=settings(),
                clock=lambda: NOW,
            )
        )
        response = disabled.post(
            f"/v1/forecasting/products/{self.product_id}/recommendation-snapshots",
            headers=self.headers,
            json=request_payload(self.snapshot, request_id=uuid4()),
        )
        self.assertEqual(response.status_code, 503, response.text)
        self.assertIn("not activated", response.text)

    def test_non_admin_cannot_use_receipt_boundary(self) -> None:
        helper_adapter = TransformingAdapter(role="helper")
        client = TestClient(
            create_app(
                adapter=helper_adapter,
                recommendation_persistence_adapter=self.persistence,
                settings=self.configured,
                clock=lambda: NOW,
            )
        )
        response = client.post(
            "/v1/forecasting/recommendations/1/receipt-allocations",
            headers=self.headers,
            json={
                "location_id": self.snapshot.location_id,
                "transaction_history_id": str(uuid4()),
                "allocated_inventory_quantity": "5",
            },
        )
        self.assertEqual(response.status_code, 403, response.text)
        self.assertEqual(self.persistence.match_calls, 0)

    def test_lightgbm_fallback_is_not_persistable(self) -> None:
        with self.assertRaisesRegex(
            DataUnavailableError, "approved LightGBM forecast is unavailable"
        ):
            ForecastAnalysisService(self.adapter).trusted_preliminary_snapshot(
                session_token=TOKEN,
                requested_location_id=None,
                product_id=SyntheticDevelopmentAdapter.COLD_START_PRODUCT_ID,
                forecast_generated_at=NOW,
            )


class TrustedCredentialConfigurationTests(unittest.TestCase):
    def test_secret_key_is_not_in_settings_repr_or_new_key_bearer_header(self) -> None:
        configured = replace(
            settings(),
            supabase_secret_key="sb_secret_do-not-expose",
            recommendation_persistence_enabled=True,
        )
        self.assertNotIn("do-not-expose", repr(configured))
        client = SupabaseSecretRestClient(
            url="https://example.supabase.co",
            secret_key=configured.supabase_secret_key or "",
            timeout_seconds=1,
        )
        self.assertNotIn("Authorization", client._headers)

    def test_privileged_tracking_rpc_is_paginated(self) -> None:
        client = SupabaseSecretRestClient(
            url="https://example.supabase.co",
            secret_key="sb_secret_test",
            timeout_seconds=1,
        )
        client.call_rpc = Mock(
            side_effect=[
                [{"recommendation_id": index} for index in range(1000)],
                [{"recommendation_id": 1000}],
            ]
        )
        rows = client.call_rpc_rows("tracking", {"p_session_token": "token"})
        self.assertEqual(len(rows), 1001)
        self.assertEqual(client.call_rpc.call_args_list[0].kwargs["row_offset"], 0)
        self.assertEqual(
            client.call_rpc.call_args_list[1].kwargs["row_offset"], 1000
        )

    def test_environment_requires_distinct_server_secret_when_enabled(self) -> None:
        base = {
            "FORECAST_API_MODE": "supabase",
            "FORECAST_REVIEW_PERIOD_DAYS": "7",
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_public",
            "FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED": "true",
        }
        from app.api.settings import ApiSettings

        with patch.dict("os.environ", base, clear=True):
            with self.assertRaisesRegex(RuntimeError, "SUPABASE_SECRET_KEY"):
                ApiSettings.from_environment()
        with patch.dict(
            "os.environ",
            {**base, "SUPABASE_SECRET_KEY": "sb_secret_server-only"},
            clear=True,
        ):
            configured = ApiSettings.from_environment()
        self.assertTrue(configured.recommendation_persistence_enabled)
        self.assertEqual(configured.supabase_secret_key, "sb_secret_server-only")


if __name__ == "__main__":
    unittest.main()
