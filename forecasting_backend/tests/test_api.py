from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

from app.api import create_app
from app.api.adapters import SyntheticDevelopmentAdapter
from app.api.contracts import (
    AnalysisContext,
    DataUnavailableError,
    ReplenishmentConfigurationInput,
    ReplenishmentConfigurationUnavailableError,
    SessionProfile,
)
from app.api.settings import ApiSettings
from app.classification import (
    GeminiRateLimitError,
    GeminiServiceError,
    GeminiTimeoutError,
    HardwareProductClassifier,
)
from app.forecasting import HistoricalDemandDataset
from app.recommendations import SupplierAvailability
from app.simulation.expanded_seasonal_fixture import (
    HISTORY_END,
    LOCATION_ID,
    PRODUCTS,
    bounded_dataset,
    expanded_datasets,
)


NOW = datetime(2026, 11, 4, 8, tzinfo=timezone.utc)
TOKEN = "test-synthetic-admin-token"
TEST_CLASSIFIER = HardwareProductClassifier.load_default(semantic_mode="disabled")


class StubGeminiClassifier:
    version = "stub-gemini-v1"

    def __init__(self, failure=None) -> None:
        self.failure = failure
        self.calls = 0

    def classify(self, *, product_name, category=None, description=None):
        self.calls += 1
        if self.failure is not None:
            raise self.failure
        return TEST_CLASSIFIER.result_from_validated_taxonomy_identity(
            product_name=product_name,
            product_type="paint_roller",
            confidence=TEST_CLASSIFIER.classify(
                product_name="Paint roller"
            ).identification_confidence,
            identification_explanation="Stub Gemini identification.",
            method="gemini_ai_taxonomy_validated",
        )


def settings() -> ApiSettings:
    return ApiSettings(
        mode="synthetic",
        supabase_url=None,
        supabase_publishable_key=None,
        request_timeout_seconds=1,
        review_period_days=7,
        policy_version="stage5d-test-policy",
        synthetic_session_token=TOKEN,
        deployment_environment="test",
        synthetic_mode_enabled=True,
    )


class TransformingAdapter:
    def __init__(
        self,
        transform=None,
        *,
        role: str = "admin",
        failure=None,
        configuration_failure=None,
    ) -> None:
        self.base = SyntheticDevelopmentAdapter(settings())
        self.transform = transform or (lambda value: value)
        self.role = role
        self.failure = failure
        self.configuration_failure = configuration_failure
        self.load_calls = 0
        self.configuration_load_calls = 0
        self.configuration_save_calls = 0
        self.requested_history_days: list[int] = []

    def authenticate(self, session_token: str) -> SessionProfile:
        profile = self.base.authenticate(session_token)
        return replace(profile, role=self.role)

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = 365,
    ) -> AnalysisContext:
        self.load_calls += 1
        self.requested_history_days.append(history_days)
        if self.failure is not None:
            raise self.failure
        value = self.base.load_analysis_context(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
            now=now,
            history_days=history_days,
        )
        return self.transform(value)

    def load_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
    ):
        self.configuration_load_calls += 1
        if self.configuration_failure is not None:
            raise self.configuration_failure
        return self.base.load_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
        )

    def save_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        configuration: ReplenishmentConfigurationInput,
    ):
        self.configuration_save_calls += 1
        return self.base.save_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
            configuration=configuration,
        )


class ExperimentalProductAdapter(TransformingAdapter):
    def __init__(self, *, available_history_days: int = 1095) -> None:
        super().__init__()
        self.available_history_days = available_history_days

    def authenticate(self, session_token: str) -> SessionProfile:
        return replace(
            super().authenticate(session_token),
            location_id=LOCATION_ID,
        )

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = 365,
    ) -> AnalysisContext:
        self.load_calls += 1
        self.requested_history_days.append(history_days)
        base = self.base.load_analysis_context(
            profile=replace(
                profile,
                location_id=SyntheticDevelopmentAdapter.LOCATION_ID,
            ),
            session_token=session_token,
            product_id=SyntheticDevelopmentAdapter.PRODUCT_ID,
            now=now,
            history_days=history_days,
        )
        product = PRODUCTS[0]
        if product_id != product.product_id:
            raise AssertionError("unexpected experimental product")
        dataset = bounded_dataset(
            expanded_datasets()[0],
            HISTORY_END,
            max_history_days=min(history_days, self.available_history_days),
        )
        return replace(
            base,
            history=dataset,
            inventory=replace(
                base.inventory,
                location_id=LOCATION_ID,
                product_id=product.product_id,
                unit=product.unit,
            ),
            supplier=replace(base.supplier, order_unit=product.unit),
            replenishment_configuration=replace(
                base.replenishment_configuration,
                product_id=product.product_id,
                location_id=LOCATION_ID,
                inventory_unit=product.unit,
                supplier_order_unit=product.unit,
            ),
        )


def client(adapter=None, *, gemini_classifier=None) -> TestClient:
    selected = adapter or TransformingAdapter()
    return TestClient(
        create_app(
            adapter=selected,
            classifier=TEST_CLASSIFIER,
            gemini_classifier=gemini_classifier,
            settings=settings(),
            clock=lambda: NOW,
        )
    )


def request_payload(**changes):
    payload = {
        "location_id": SyntheticDevelopmentAdapter.LOCATION_ID,
        "model": "mean28",
        "horizon_days": 28,
    }
    payload.update(changes)
    return payload


def post(api: TestClient, **changes):
    return api.post(
        "/v1/forecasting/products/"
        f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis",
        headers={"Authorization": f"Bearer {TOKEN}"},
        json=request_payload(**changes),
    )


class ForecastApiTests(unittest.TestCase):
    def test_503_logs_safe_model_endpoint_stage_and_exception_type(self) -> None:
        adapter = TransformingAdapter(
            failure=DataUnavailableError(
                "controlled upstream failure",
                stage="supabase_rpc:forecast_daily_demand_v1:page_offset=1000",
            )
        )

        with self.assertLogs("inventory_plus.forecasting", level="ERROR") as logs:
            response = post(
                client(adapter),
                model="seasonal_experimental",
            )

        self.assertEqual(response.status_code, 503)
        diagnostic = "\n".join(logs.output)
        self.assertIn(
            "endpoint=/v1/forecasting/products/{product_id}/analysis",
            diagnostic,
        )
        self.assertIn("requested_model=seasonal_experimental", diagnostic)
        self.assertIn(
            "stage=supabase_rpc:forecast_daily_demand_v1:page_offset=1000",
            diagnostic,
        )
        self.assertIn("exception_type=DataUnavailableError", diagnostic)
        self.assertNotIn(TOKEN, diagnostic)

    def test_classification_is_authenticated_admin_only_and_read_only(self) -> None:
        adapter = TransformingAdapter()
        response = client(adapter).post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "product_name": "Roofing Sealant",
                "category": "Roofing Repair",
                "description": "Sealant for roof leak points",
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertTrue(body["read_only"])
        self.assertEqual(body["schema_version"], "classification-v3")
        self.assertEqual(body["engine"], "existing")
        self.assertEqual(
            body["result"]["identified_product_type"], "roofing_sealant"
        )
        self.assertEqual(body["result"]["seasonal_relevance"], "rainy")
        self.assertEqual(adapter.load_calls, 0)
        self.assertEqual(adapter.configuration_load_calls, 0)
        self.assertEqual(adapter.configuration_save_calls, 0)

        helper_response = client(TransformingAdapter(role="helper")).post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={"product_name": "Claw Hammer"},
        )
        self.assertEqual(helper_response.status_code, 403)

        missing_auth = client().post(
            "/v1/classification", json={"product_name": "Claw Hammer"}
        )
        self.assertEqual(missing_auth.status_code, 401)

    def test_classification_selects_injected_gemini_after_admin_auth(self) -> None:
        gemini = StubGeminiClassifier()
        response = client(gemini_classifier=gemini).post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={"product_name": "Paint roller", "engine": "gemini"},
        )
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual(body["engine"], "gemini")
        self.assertEqual(body["classifier_version"], "stub-gemini-v1")
        self.assertEqual(
            body["result"]["identification_method"],
            "gemini_ai_taxonomy_validated",
        )
        self.assertEqual(gemini.calls, 1)

    def test_classification_maps_gemini_operational_failures(self) -> None:
        cases = (
            (GeminiRateLimitError("rate limited"), 429),
            (GeminiTimeoutError("timed out"), 504),
            (GeminiServiceError("unavailable"), 503),
        )
        for failure, expected_status in cases:
            with self.subTest(status=expected_status):
                response = client(
                    gemini_classifier=StubGeminiClassifier(failure=failure)
                ).post(
                    "/v1/classification",
                    headers={"Authorization": f"Bearer {TOKEN}"},
                    json={"product_name": "Paint roller", "engine": "gemini"},
                )
                self.assertEqual(response.status_code, expected_status)

    def test_classification_abstains_for_unknown_new_product(self) -> None:
        response = client().post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={"product_name": "Unknown Product XYZ"},
        )
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()["result"]
        self.assertTrue(result["is_unknown"])
        self.assertEqual(result["seasonal_relevance"], "unknown")
        self.assertEqual(result["seasonal_evidence_level"], "insufficient")

    def test_classification_generalizes_new_hardware_without_seasonal_guess(self) -> None:
        response = client().post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "product_name": "TINER",
                "category": "paint",
                "description": "",
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()["result"]
        self.assertEqual(result["identified_product_type"], "paint_thinner")
        self.assertEqual(result["seasonal_relevance"], "unknown")
        self.assertEqual(result["seasonal_evidence_level"], "insufficient")
        self.assertNotEqual(result["identification_confidence"], "high")
        self.assertIn(
            result["identification_method"],
            {"semantic_taxonomy", "lexical_taxonomy"},
        )

    def test_classification_returns_hierarchical_seasonal_evidence(self) -> None:
        response = client().post(
            "/v1/classification",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "product_name": "Concrete Hollow Blocks",
                "category": "Masonry",
                "description": "Units for exterior wall construction",
                "engine": "existing",
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()["result"]
        self.assertEqual(result["identified_product_type"], "concrete_hollow_block")
        self.assertEqual(result["seasonal_relevance"], "dry")
        self.assertEqual(
            result["seasonal_match_type"], "inherited_industry_activity"
        )
        self.assertIn("Masonry construction", result["seasonal_hierarchy"])
        self.assertEqual(len(result["evidence"]), 2)

    def test_serializes_structured_read_only_forecast_and_recommendation(self) -> None:
        response = post(client())
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual(body["schema_version"], "stage5d-v1")
        self.assertTrue(body["synthetic"])
        self.assertEqual(body["forecast"]["model"], "mean28")
        self.assertEqual(body["forecast"]["version"], "1")
        self.assertEqual(body["forecast"]["provenance"], "synthetic")
        self.assertEqual(body["forecast"]["horizon_days"], 28)
        self.assertEqual(len(body["forecast"]["daily"]), 28)
        self.assertIsInstance(body["forecast"]["total_quantity"], float)
        self.assertEqual(
            body["recommendation"]["policy_type"],
            "periodic_review_order_up_to",
        )
        self.assertFalse(body["recommendation"]["approved_purchase_decision"])
        self.assertFalse(body["recommendation"]["purchase_order_created"])
        self.assertEqual(
            body["capabilities"],
            {
                "read_only": True,
                "inventory_mutation": False,
                "purchase_order_creation": False,
            },
        )

    def test_requires_bearer_authentication(self) -> None:
        api = client()
        response = api.post(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis",
            json=request_payload(),
        )
        self.assertEqual(response.status_code, 401)
        invalid = api.post(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis",
            headers={"Authorization": "Bearer wrong"},
            json=request_payload(),
        )
        self.assertEqual(invalid.status_code, 401)

    def test_enforces_admin_role_before_loading_product_data(self) -> None:
        adapter = TransformingAdapter(role="helper")
        response = post(client(adapter))
        self.assertEqual(response.status_code, 403)
        self.assertEqual(adapter.load_calls, 0)

    def test_rejects_client_location_outside_session(self) -> None:
        response = post(
            client(), location_id="22222222-2222-4222-8222-222222222222"
        )
        self.assertEqual(response.status_code, 403)

    def test_replenishment_configuration_is_admin_and_location_scoped(self) -> None:
        helper = TransformingAdapter(role="helper")
        helper_response = client(helper).get(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config",
            headers={"Authorization": f"Bearer {TOKEN}"},
            params={"location_id": SyntheticDevelopmentAdapter.LOCATION_ID},
        )
        self.assertEqual(helper_response.status_code, 403)
        self.assertEqual(helper.configuration_load_calls, 0)

        admin = TransformingAdapter()
        outside = client(admin).get(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config",
            headers={"Authorization": f"Bearer {TOKEN}"},
            params={"location_id": "22222222-2222-4222-8222-222222222222"},
        )
        self.assertEqual(outside.status_code, 403)
        self.assertEqual(admin.configuration_load_calls, 0)

    def test_missing_replenishment_migration_is_reported_explicitly(self) -> None:
        adapter = TransformingAdapter(
            configuration_failure=ReplenishmentConfigurationUnavailableError(
                "Replenishment configuration is unavailable until "
                "database/stage_5f_forecast_replenishment_configuration.sql "
                "is approved and applied"
            )
        )
        api = client(adapter)
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config"
        )

        response = api.get(
            path,
            headers={"Authorization": f"Bearer {TOKEN}"},
            params={"location_id": SyntheticDevelopmentAdapter.LOCATION_ID},
        )

        self.assertEqual(response.status_code, 503)
        self.assertIn(
            "stage_5f_forecast_replenishment_configuration.sql",
            response.json()["detail"],
        )

    def test_replenishment_configuration_save_recalculates_analysis_inputs(self) -> None:
        adapter = TransformingAdapter()
        api = client(adapter)
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config"
        )
        response = api.put(
            path,
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": SyntheticDevelopmentAdapter.LOCATION_ID,
                "supplier_lead_time_days": 9,
                "review_period_days": 14,
                "safety_stock": 25,
                "minimum_order_quantity": 4,
                "supplier_pack_size": 2,
                "supplier_order_unit": "case",
                "unit_conversion_factor": 6,
                "confirmed_incoming_quantity": 12,
                "incoming_quantity_verified": True,
                "backorder_quantity": 3,
                "backorder_quantity_verified": True,
                "supplier_availability": "available",
                "data_source": "admin_estimate",
                "source_captured_at": NOW.isoformat(),
                "rationale": "Reviewed supplier estimate",
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["supplier_lead_time_days"], 9)
        self.assertEqual(adapter.configuration_save_calls, 1)

        analysis = post(api).json()
        snapshot = analysis["recommendation"]["inventory_snapshot"]
        supplier = analysis["recommendation"]["supplier_snapshot"]
        self.assertEqual(snapshot["confirmed_on_order"], 12.0)
        self.assertEqual(snapshot["backorders"], 3.0)
        self.assertEqual(supplier["lead_time_days"], 9)
        self.assertEqual(supplier["minimum_order_quantity"], 4.0)

    def test_unverified_quantities_and_missing_rationale_are_rejected(self) -> None:
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config"
        )
        response = client().put(
            path,
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": SyntheticDevelopmentAdapter.LOCATION_ID,
                "confirmed_incoming_quantity": 5,
                "incoming_quantity_verified": False,
                "data_source": "admin_estimate",
                "source_captured_at": NOW.isoformat(),
                "rationale": "",
            },
        )
        self.assertEqual(response.status_code, 422)

    def test_unit_conversion_requires_a_supplier_order_unit(self) -> None:
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/replenishment-config"
        )
        response = client().put(
            path,
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": SyntheticDevelopmentAdapter.LOCATION_ID,
                "unit_conversion_factor": 6,
                "data_source": "verified_record",
                "source_captured_at": NOW.isoformat(),
            },
        )
        self.assertEqual(response.status_code, 422)
        self.assertIn("supplier_order_unit", response.json()["detail"])

    def test_product_and_authorized_location_are_consistent(self) -> None:
        body = post(client()).json()
        self.assertEqual(
            body["product"]["location_id"],
            body["authorized_scope"]["location_id"],
        )
        self.assertEqual(
            body["product"]["product_id"],
            SyntheticDevelopmentAdapter.PRODUCT_ID,
        )

    def test_calibrated_blend_client_name_maps_to_blend_candidate(self) -> None:
        response = post(client(), model="calibrated_blend")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn(
            response.json()["forecast"]["model"],
            {"calibrated_lightgbm_mean28_blend", "mean28"},
        )

    def test_experimental_model_is_explicit_and_replenishment_is_isolated(self) -> None:
        adapter = ExperimentalProductAdapter()
        product = PRODUCTS[0]
        api = client(adapter)
        response = api.post(
            f"/v1/forecasting/products/{product.product_id}/analysis",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": LOCATION_ID,
                "model": "seasonal_experimental",
                "horizon_days": 28,
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        forecast = body["forecast"]
        self.assertEqual(adapter.requested_history_days, [1095])
        self.assertEqual(forecast["requested_model"], "seasonal_experimental")
        self.assertEqual(
            forecast["model"],
            "product_specific_seasonal_lightgbm_experimental",
        )
        self.assertFalse(forecast["fallback"]["used"])
        self.assertEqual(forecast["history_window_days_requested"], 1095)
        self.assertEqual(
            forecast["seasonal_context"]["classification"][
                "seasonal_relevance"
            ],
            "summer",
        )
        self.assertFalse(
            forecast["seasonal_context"]["numerical_multiplier_applied"]
        )
        self.assertIn("season", forecast["daily"][0])
        basis = body["recommendation"]["forecast_basis"]
        self.assertFalse(basis["uses_experimental_seasonal_forecast"])
        self.assertIn(basis["model"], {"lightgbm", "mean28_fallback"})
        self.assertEqual(basis["history_window_days"], 365)
        preliminary = body["preliminary_restocking_insight"]
        self.assertEqual(preliminary["planning_horizon_days"], 28)
        self.assertEqual(preliminary["forecast_basis"]["requested_model"], "lightgbm")
        self.assertFalse(
            preliminary["forecast_basis"]["uses_experimental_seasonal_forecast"]
        )
        self.assertFalse(preliminary["incoming_and_backorders_treated_as_zero"])

        baseline_response = api.post(
            f"/v1/forecasting/products/{product.product_id}/analysis",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": LOCATION_ID,
                "model": "lightgbm",
                "horizon_days": 28,
            },
        )
        self.assertEqual(baseline_response.status_code, 200, baseline_response.text)
        baseline_recommendation = baseline_response.json()["recommendation"]
        self.assertEqual(
            body["preliminary_restocking_insight"],
            baseline_response.json()["preliminary_restocking_insight"],
        )
        experimental_recommendation = body["recommendation"]
        for field in (
            "inventory_position",
            "expected_lead_time_demand",
            "reorder_point",
            "safety_stock",
            "protection_period_days",
            "target_inventory",
            "preliminary_quantity",
            "suggested_quantity",
        ):
            self.assertEqual(
                experimental_recommendation[field],
                baseline_recommendation[field],
            )
        self.assertEqual(
            experimental_recommendation["forecast_basis"]["model"],
            baseline_recommendation["forecast_basis"]["model"],
        )

    def test_experimental_model_falls_back_for_unregistered_product(self) -> None:
        adapter = TransformingAdapter()
        response = post(client(adapter), model="seasonal_experimental")

        self.assertEqual(response.status_code, 200, response.text)
        forecast = response.json()["forecast"]
        self.assertEqual(adapter.requested_history_days, [1095])
        self.assertTrue(forecast["fallback"]["used"])
        self.assertEqual(
            forecast["fallback"]["reason"],
            "seasonal_context_or_product_context_unavailable",
        )
        self.assertNotEqual(
            forecast["model"],
            "product_specific_seasonal_lightgbm_experimental",
        )
        self.assertEqual(
            forecast["seasonal_context"]["classification"][
                "seasonal_relevance"
            ],
            "unknown",
        )

    def test_experimental_model_falls_back_for_insufficient_history(self) -> None:
        adapter = ExperimentalProductAdapter(available_history_days=60)
        product = PRODUCTS[0]
        response = client(adapter).post(
            f"/v1/forecasting/products/{product.product_id}/analysis",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "location_id": LOCATION_ID,
                "model": "seasonal_experimental",
                "horizon_days": 28,
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        fallback = response.json()["forecast"]["fallback"]
        self.assertTrue(fallback["used"])
        self.assertEqual(fallback["reason"], "insufficient_training_history")

    def test_default_and_existing_models_keep_365_day_history(self) -> None:
        adapter = TransformingAdapter()
        response = post(client(adapter), model="lightgbm")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(adapter.requested_history_days, [365])
        self.assertEqual(
            response.json()["forecast"]["history_window_days_requested"],
            365,
        )

    def test_api_default_model_remains_existing_blend(self) -> None:
        adapter = TransformingAdapter()
        response = client(adapter).post(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={"location_id": SyntheticDevelopmentAdapter.LOCATION_ID},
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["forecast"]["requested_model"], "blend")
        self.assertEqual(adapter.requested_history_days, [365])

    def test_no_history_remains_unknown_without_manual_estimate(self) -> None:
        def no_history(context: AnalysisContext) -> AnalysisContext:
            history = HistoricalDemandDataset.from_synthetic_observations(
                product=context.history.product,
                history_start=None,
                history_end=context.history.history_end,
                observations=[],
            )
            return replace(context, history=history)

        body = post(client(TransformingAdapter(no_history))).json()
        self.assertTrue(body["forecast"]["cold_start"]["is_cold_start"])
        self.assertEqual(body["forecast"]["cold_start"]["reason"], "no_history")
        self.assertTrue(
            body["forecast"]["cold_start"]["zero_is_unknown_demand"]
        )
        self.assertEqual(body["forecast"]["total_quantity"], 0.0)
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        preliminary = body["preliminary_restocking_insight"]
        self.assertEqual(preliminary["status"], "limited")
        self.assertIsNone(preliminary["predicted_demand"])
        self.assertIsNone(preliminary["suggested_restock_quantity"])
        self.assertTrue(preliminary["limitations"])
        self.assertIsNone(body["recommendation"]["manual_demand_estimate"])
        self.assertIn(
            "no_history_demand_unknown", body["recommendation"]["warnings"]
        )

    def test_synthetic_adapter_exposes_an_api_cold_start_fixture(self) -> None:
        api = client()
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.COLD_START_PRODUCT_ID}/analysis"
        )
        response = api.post(
            path,
            headers={"Authorization": f"Bearer {TOKEN}"},
            json=request_payload(),
        )

        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertTrue(body["forecast"]["cold_start"]["is_cold_start"])
        self.assertEqual(body["forecast"]["cold_start"]["reason"], "no_history")
        self.assertTrue(
            body["forecast"]["cold_start"]["zero_is_unknown_demand"]
        )
        self.assertEqual(body["recommendation"]["status"], "needs_review")

    def test_manual_cold_start_estimate_is_provisional(self) -> None:
        def no_history(context: AnalysisContext) -> AnalysisContext:
            return replace(
                context,
                history=HistoricalDemandDataset.from_synthetic_observations(
                    product=context.history.product,
                    history_start=None,
                    history_end=context.history.history_end,
                    observations=[],
                ),
            )

        response = post(
            client(TransformingAdapter(no_history)),
            manual_daily_demand=5,
            manual_unit="pcs",
            manual_rationale="Explicit new-product estimate",
            manual_confirmed=True,
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIn(
            "cold_start_manual_demand_estimate_used",
            body["recommendation"]["warnings"],
        )
        manual = body["recommendation"]["manual_demand_estimate"]
        self.assertEqual(manual["daily_quantity"], 5.0)
        self.assertEqual(manual["unit"], "pcs")
        self.assertEqual(manual["rationale"], "Explicit new-product estimate")
        self.assertEqual(manual["source"], "authenticated_admin_manual_input")
        self.assertTrue(manual["staff_confirmed"])
        self.assertEqual(manual["confirmed_by_profile_id"], "synthetic-admin")
        self.assertTrue(manual["provisional"])
        self.assertFalse(manual["creates_historical_sales"])
        self.assertEqual(body["forecast"]["total_quantity"], 0.0)

    def test_manual_estimate_requires_staff_confirmation(self) -> None:
        def no_history(context: AnalysisContext) -> AnalysisContext:
            return replace(
                context,
                history=HistoricalDemandDataset.from_synthetic_observations(
                    product=context.history.product,
                    history_start=None,
                    history_end=context.history.history_end,
                    observations=[],
                ),
            )

        response = post(
            client(TransformingAdapter(no_history)),
            manual_daily_demand=5,
            manual_unit="pcs",
            manual_rationale="Unconfirmed estimate",
        )
        self.assertEqual(response.status_code, 422)
        self.assertIn("explicit staff confirmation", response.json()["detail"])

    def test_insufficient_history_remains_cold_start(self) -> None:
        def insufficient(context: AnalysisContext) -> AnalysisContext:
            observations = context.history.observations[-10:]
            return replace(
                context,
                history=HistoricalDemandDataset.from_synthetic_observations(
                    product=context.history.product,
                    history_start=observations[0].business_date,
                    history_end=observations[-1].business_date,
                    observations=observations,
                ),
            )

        body = post(
            client(TransformingAdapter(insufficient)), model="mean28"
        ).json()
        self.assertTrue(body["forecast"]["cold_start"]["is_cold_start"])
        self.assertEqual(
            body["forecast"]["cold_start"]["reason"],
            "insufficient_history",
        )
        self.assertFalse(
            body["forecast"]["cold_start"]["zero_is_unknown_demand"]
        )
        self.assertEqual(body["recommendation"]["status"], "needs_review")

    def test_manual_no_history_with_missing_inputs_is_forecast_only_review(self) -> None:
        def missing(context: AnalysisContext) -> AnalysisContext:
            return replace(
                context,
                history=HistoricalDemandDataset.from_synthetic_observations(
                    product=context.history.product,
                    history_start=None,
                    history_end=context.history.history_end,
                    observations=[],
                ),
                inventory=replace(
                    context.inventory,
                    confirmed_on_order=None,
                    backorders=None,
                ),
                supplier=replace(
                    context.supplier,
                    lead_time_days=None,
                    availability=SupplierAvailability.UNKNOWN,
                ),
                safety_stock=None,
            )

        body = post(
            client(TransformingAdapter(missing)),
            manual_daily_demand=4,
            manual_unit="pcs",
            manual_rationale="Opening-week shelf allocation",
            manual_confirmed=True,
        ).json()
        self.assertEqual(body["forecast"]["total_quantity"], 0.0)
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIsNone(
            body["recommendation"]["suggested_quantity"]["inventory_units"]
        )
        self.assertIsNotNone(body["recommendation"]["manual_demand_estimate"])
        self.assertIn(
            "confirmed_on_order_missing", body["recommendation"]["warnings"]
        )

    def test_missing_supplier_and_balance_data_returns_forecast_only_review(self) -> None:
        def missing(context: AnalysisContext) -> AnalysisContext:
            return replace(
                context,
                inventory=replace(
                    context.inventory,
                    confirmed_on_order=None,
                    backorders=None,
                ),
                supplier=replace(
                    context.supplier,
                    lead_time_days=None,
                    minimum_order_quantity=None,
                    pack_size=None,
                    availability=SupplierAvailability.UNKNOWN,
                ),
                safety_stock=None,
            )

        body = post(client(TransformingAdapter(missing))).json()
        self.assertEqual(body["forecast"]["horizon_days"], 28)
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIsNone(body["recommendation"]["suggested_quantity"]["inventory_units"])
        preliminary = body["preliminary_restocking_insight"]
        self.assertEqual(preliminary["status"], "available")
        self.assertIsNotNone(preliminary["predicted_demand"])
        self.assertIsNotNone(preliminary["available_inventory"])
        self.assertIsNotNone(preliminary["suggested_restock_quantity"])
        self.assertTrue(preliminary["requires_owner_review"])
        self.assertFalse(preliminary["incoming_and_backorders_treated_as_zero"])
        self.assertIn(
            "confirmed_on_order_missing", body["recommendation"]["warnings"]
        )

    def test_stale_source_is_explicit(self) -> None:
        def stale(context: AnalysisContext) -> AnalysisContext:
            old = NOW - timedelta(days=10)
            return replace(
                context,
                source_data_as_of=old,
                inventory=replace(context.inventory, captured_at=old),
            )

        body = post(client(TransformingAdapter(stale))).json()
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIn("forecast_source_data_stale", body["recommendation"]["warnings"])
        self.assertIn("inventory_snapshot_stale", body["recommendation"]["warnings"])

    def test_moq_capacity_conflict_is_serialized(self) -> None:
        def conflict(context: AnalysisContext) -> AnalysisContext:
            return replace(
                context,
                inventory=replace(
                    context.inventory,
                    saleable_on_hand=Decimal("100"),
                    max_capacity=Decimal("110"),
                ),
                supplier=replace(
                    context.supplier,
                    minimum_order_quantity=Decimal("50"),
                    pack_size=Decimal("10"),
                ),
            )

        body = post(client(TransformingAdapter(conflict))).json()
        self.assertEqual(body["recommendation"]["status"], "needs_review")
        self.assertIn(
            "capacity_conflicts_with_supplier_constraints",
            body["recommendation"]["warnings"],
        )

    def test_timeout_and_connection_failures_are_explicit(self) -> None:
        timeout = post(
            client(
                TransformingAdapter(
                    failure=httpx.ReadTimeout("controlled timeout")
                )
            )
        )
        self.assertEqual(timeout.status_code, 504)
        connection = post(
            client(
                TransformingAdapter(
                    failure=httpx.ConnectError("controlled connection failure")
                )
            )
        )
        self.assertEqual(connection.status_code, 503)

    def test_api_exposes_no_inventory_or_purchase_order_mutation(self) -> None:
        api = client()
        path = (
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis"
        )
        self.assertEqual(api.put(path, json={}).status_code, 405)
        self.assertEqual(api.delete(path).status_code, 405)
        body = post(api).json()
        self.assertFalse(body["capabilities"]["inventory_mutation"])
        self.assertFalse(body["capabilities"]["purchase_order_creation"])


class ForecastApiSettingsTests(unittest.TestCase):
    def test_configured_web_origin_receives_cors_preflight_headers(self) -> None:
        configured = replace(
            settings(),
            cors_origins=("http://127.0.0.1:7357",),
        )
        api = TestClient(
            create_app(
                adapter=TransformingAdapter(),
                settings=configured,
                clock=lambda: NOW,
            )
        )

        response = api.options(
            "/v1/forecasting/products/"
            f"{SyntheticDevelopmentAdapter.PRODUCT_ID}/analysis",
            headers={
                "Origin": "http://127.0.0.1:7357",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization,content-type",
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.headers["access-control-allow-origin"],
            "http://127.0.0.1:7357",
        )

    def test_production_environment_rejects_synthetic_mode(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "FORECAST_API_MODE": "synthetic",
                "FORECAST_DEPLOYMENT_ENV": "production",
                "FORECAST_SYNTHETIC_SESSION_TOKEN": "must-not-enable",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "forbidden in production"):
                ApiSettings.from_environment()

    def test_synthetic_mode_requires_explicit_nonproduction_token(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "FORECAST_API_MODE": "synthetic",
                "FORECAST_DEPLOYMENT_ENV": "development",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(
                RuntimeError, "must be explicitly configured"
            ):
                ApiSettings.from_environment()

    def test_synthetic_mode_is_enabled_only_for_explicit_test_configuration(
        self,
    ) -> None:
        with patch.dict(
            "os.environ",
            {
                "FORECAST_API_MODE": "synthetic",
                "FORECAST_DEPLOYMENT_ENV": "test",
                "FORECAST_SYNTHETIC_SESSION_TOKEN": TOKEN,
            },
            clear=True,
        ):
            configured = ApiSettings.from_environment()
        self.assertTrue(configured.synthetic_mode_enabled)
        self.assertEqual(configured.deployment_environment, "test")
        self.assertEqual(configured.synthetic_session_token, TOKEN)

    def test_adapter_rejects_direct_production_construction(self) -> None:
        production = replace(
            settings(),
            deployment_environment="production",
            synthetic_mode_enabled=False,
        )
        with self.assertRaisesRegex(RuntimeError, "disabled"):
            SyntheticDevelopmentAdapter(production)


if __name__ == "__main__":
    unittest.main()
