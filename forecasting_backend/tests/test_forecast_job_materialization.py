from __future__ import annotations

import re
import unittest
from datetime import date, datetime, timedelta
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import Mock, patch
from zoneinfo import ZoneInfo

from app.api.contracts import DataUnavailableError, ProductNotFoundError, SessionProfile
from app.api.job_materialization import (
    ForecastJobMaterializer,
    SupabaseForecastJobRepository,
    canonical_history_input,
    demand_input_digest,
    forecast_model_identity,
)
from app.performance_diagnostics import performance_request
from app.data.models import DailyDemand
from app.forecasting import (
    AvailabilityEvidence,
    AvailabilityStatus,
    CalibratedBlendForecaster,
    DataProvenance,
    ForecastProduct,
    HistoricalDemandDataset,
    LightGBMForecaster,
    Mean28Forecaster,
)


MANILA = ZoneInfo("Asia/Manila")
LOCATION_ID = "11111111-1111-4111-8111-111111111111"
PRODUCT_A = "22222222-2222-4222-8222-222222222222"
PRODUCT_B = "33333333-3333-4333-8333-333333333333"
AS_OF = datetime(2026, 11, 13, 9, 30, tzinfo=MANILA)


def _history(product_id: str, *, observations: tuple[DailyDemand, ...] | None = None):
    end = AS_OF.date() - timedelta(days=1)
    start = end - timedelta(days=364)
    product = ForecastProduct(
        location_id=LOCATION_ID,
        product_id=product_id,
        product_name=f"Product {product_id[-4:]}",
        sku=f"SKU-{product_id[-4:]}",
        unit="pcs",
    )
    rows = observations if observations is not None else (
        DailyDemand(
            business_date=end,
            location_id=LOCATION_ID,
            product_id=product_id,
            product_name=product.product_name,
            sku=product.sku,
            unit="pcs",
            quantity=Decimal("2.50"),
            completed_order_count=1,
        ),
    )
    return HistoricalDemandDataset.from_real_observations(
        product=product,
        history_start=start if rows else None,
        history_end=end,
        observations=rows,
        availability_evidence=(
            AvailabilityEvidence(end, AvailabilityStatus.IN_STOCK),
        ) if rows else (),
    )


def _model_service():
    return SimpleNamespace(
        _blend=CalibratedBlendForecaster(),
        _lightgbm=LightGBMForecaster(),
        _mean28=Mean28Forecaster(),
    )


class FakeCatalog:
    def __init__(self, histories):
        self.histories = histories
        self.on_load = None
        self.load_calls = []
        self.inventory_quantity = Decimal("5")

    def list_active_products(self, *, profile, session_token):
        return tuple(sorted(self.histories))

    def load_analysis_context(
        self, *, profile, session_token, product_id, now, history_days=365
    ):
        self.load_calls.append((product_id, now, history_days))
        if self.on_load is not None:
            self.on_load(product_id)
        return SimpleNamespace(
            history=self.histories[product_id],
            source_data_as_of=now.astimezone(MANILA),
            inventory=SimpleNamespace(saleable_on_hand=self.inventory_quantity),
        )


class FakeRepository:
    def __init__(self):
        self.revisions = {}
        self.jobs = {}
        self.initialize_calls = []

    def initialize_revisions(self, *, location_id, product_ids):
        self.initialize_calls.append((location_id, tuple(product_ids)))
        result = {}
        for product_id in product_ids:
            result[product_id] = self.revisions.setdefault(
                product_id, {"sales_revision": 0, "product_revision": 0}
            ).copy()
        return result

    def enqueue_jobs(self, *, location_id, jobs):
        outcomes = []
        for job in jobs:
            product_id = str(job["product_id"])
            expected = (
                int(job["sales_revision"]),
                int(job["product_revision"]),
            )
            current = self.revisions[product_id]
            actual = (current["sales_revision"], current["product_revision"])
            if actual != expected:
                outcomes.append({"product_id": product_id, "outcome": "stale_revision"})
                continue
            key = tuple(job[name] for name in (
                "location_id", "product_id", "requested_model_key",
                "requested_model_version", "requested_model_config_digest",
                "requested_implementation_digest", "horizon_days",
                "history_window_days", "as_of_at", "as_of_business_date",
                "sales_revision", "product_revision", "request_input_digest",
            ))
            if key in self.jobs:
                outcomes.append({"product_id": product_id, "outcome": "duplicate"})
            else:
                self.jobs[key] = dict(job)
                outcomes.append({"product_id": product_id, "outcome": "queued"})
        return outcomes


class ForecastJobMaterializationTests(unittest.TestCase):
    def setUp(self):
        self.profile = SessionProfile(
            profile_id="profile-id",
            role="admin",
            location_id=LOCATION_ID,
            name="Admin",
        )
        self.catalog = FakeCatalog({PRODUCT_A: _history(PRODUCT_A)})
        self.repository = FakeRepository()
        self.service = _model_service()

    def _materializer(self):
        return ForecastJobMaterializer(
            catalog=self.catalog,
            repository=self.repository,
            service=self.service,
        )

    def test_canonical_digest_is_stable_and_sensitive_to_frozen_inputs(self):
        history = _history(PRODUCT_A)
        reversed_rows = HistoricalDemandDataset.from_real_observations(
            product=history.product,
            history_start=history.history_start,
            history_end=history.history_end,
            observations=tuple(reversed(history.observations)),
            availability_evidence=tuple(reversed(history.availability_evidence)),
        )
        self.assertEqual(demand_input_digest(history), demand_input_digest(reversed_rows))
        self.assertRegex(demand_input_digest(history), re.compile(r"^[0-9a-f]{64}$"))
        changed = _history(
            PRODUCT_A,
            observations=(DailyDemand(
                business_date=history.history_end,
                location_id=LOCATION_ID,
                product_id=PRODUCT_A,
                product_name=history.product.product_name,
                sku=history.product.sku,
                unit="pcs",
                quantity=Decimal("2.51"),
                completed_order_count=1,
            ),),
        )
        self.assertNotEqual(demand_input_digest(history), demand_input_digest(changed))

    def test_model_configuration_and_implementation_digests_are_deterministic(self):
        first = forecast_model_identity(self.service)
        second = forecast_model_identity(self.service)
        self.assertEqual(first, second)
        self.assertEqual(first.model_key, "blend")
        self.assertEqual(first.model_version, "1")
        self.assertRegex(first.config_digest, r"^[0-9a-f]{64}$")
        self.assertRegex(first.implementation_digest, r"^[0-9a-f]{64}$")

    def test_bootstrap_initializes_missing_revision_and_creates_default_job(self):
        report = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.assertEqual(self.repository.revisions[PRODUCT_A], {
            "sales_revision": 0, "product_revision": 0,
        })
        self.assertEqual((report.prepared, report.queued, report.stale), (1, 1, 0))
        job = next(iter(self.repository.jobs.values()))
        self.assertEqual(job["requested_model_key"], "blend")
        self.assertEqual(job["horizon_days"], 28)
        self.assertEqual(job["history_window_days"], 365)
        self.assertEqual(job["as_of_business_date"], "2026-11-13")
        self.assertTrue(job["as_of_at"].startswith("2026-11-12T16:00:00"))

    def test_bootstrap_accepts_no_history_as_real_cold_start_input(self):
        self.catalog.histories[PRODUCT_B] = _history(PRODUCT_B, observations=())
        report = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.assertEqual(report.queued, 2)
        cold_job = next(
            job for job in self.repository.jobs.values()
            if job["product_id"] == PRODUCT_B
        )
        self.assertEqual(
            cold_job["request_input_digest"],
            demand_input_digest(
                self.catalog.histories[PRODUCT_B],
                source_data_as_of=AS_OF.replace(hour=0, minute=0, second=0, microsecond=0),
            ),
        )

    def test_bootstrap_accepts_limited_real_history(self):
        end = AS_OF.date() - timedelta(days=1)
        self.catalog.histories[PRODUCT_A] = _history(
            PRODUCT_A,
            observations=(
                DailyDemand(
                    business_date=end,
                    location_id=LOCATION_ID,
                    product_id=PRODUCT_A,
                    product_name="Product A",
                    sku="SKU-A",
                    unit="pcs",
                    quantity=Decimal("1"),
                    completed_order_count=1,
                ),
            ),
        )
        report = self._materializer().bootstrap(
            profile=self.profile,
            session_token="test-token",
            now=AS_OF,
            product_id=PRODUCT_A,
        )
        self.assertEqual((report.prepared, report.queued, report.skipped), (1, 1, 0))

    def test_skipped_frozen_input_emits_safe_stage_and_reason(self):
        self.catalog.on_load = lambda _product_id: (_ for _ in ()).throw(
            DataUnavailableError("sensitive backend details")
        )
        with patch("app.performance_diagnostics._write") as diagnostic:
            with performance_request(enabled=True):
                report = self._materializer().bootstrap(
                    profile=self.profile,
                    session_token="test-token",
                    now=AS_OF,
                    product_id=PRODUCT_A,
                )

        self.assertEqual((report.prepared, report.skipped), (0, 1))
        rendered = " ".join(
            call.args[0] % call.args[1:]
            for call in diagnostic.call_args_list
        )
        self.assertIn("stage=frozen_context_load", rendered)
        self.assertIn("reason_code=frozen_input_unavailable", rendered)
        self.assertIn("category=DataUnavailableError", rendered)
        self.assertNotIn(PRODUCT_A, rendered)
        self.assertNotIn("sensitive backend details", rendered)

    def test_repeated_bootstrap_is_deduplicated(self):
        first = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        second = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.assertEqual(first.queued, 1)
        self.assertEqual(second.duplicate, 1)
        self.assertEqual(len(self.repository.jobs), 1)

    def test_single_product_bootstrap_does_not_prepare_other_active_products(self):
        self.catalog.histories[PRODUCT_B] = _history(PRODUCT_B)
        report = self._materializer().bootstrap(
            profile=self.profile,
            session_token="test-token",
            now=AS_OF,
            product_id=PRODUCT_A,
        )
        self.assertEqual(report.active_products, 1)
        self.assertEqual(report.queued, 1)
        self.assertEqual(self.repository.initialize_calls[0][1], (PRODUCT_A,))
        self.assertEqual([call[0] for call in self.catalog.load_calls], [PRODUCT_A])
        self.assertEqual(len(self.repository.jobs), 1)

    def test_single_product_bootstrap_rejects_product_outside_admin_scope(self):
        with self.assertRaises(ProductNotFoundError):
            self._materializer().bootstrap(
                profile=self.profile,
                session_token="test-token",
                now=AS_OF,
                product_id="44444444-4444-4444-8444-444444444444",
            )
        self.assertEqual(self.repository.initialize_calls, [])
        self.assertEqual(self.repository.jobs, {})

    def test_revision_change_during_freeze_rejects_stale_job(self):
        def change_revision(_product_id):
            self.repository.revisions[PRODUCT_A]["sales_revision"] += 1

        self.catalog.on_load = change_revision
        report = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.assertEqual(report.stale, 1)
        self.assertEqual(report.queued, 0)
        self.assertEqual(self.repository.jobs, {})

    def test_inventory_only_changes_do_not_enter_demand_digest(self):
        first = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.catalog.inventory_quantity = Decimal("99")
        second = self._materializer().bootstrap(
            profile=self.profile, session_token="test-token", now=AS_OF
        )
        self.assertEqual(first.queued, 1)
        self.assertEqual(second.duplicate, 1)
        self.assertEqual(len(self.repository.jobs), 1)

    def test_non_admin_cannot_bootstrap(self):
        profile = SessionProfile(
            profile_id="staff-id", role="staff", location_id=LOCATION_ID, name="Staff"
        )
        with self.assertRaises(PermissionError):
            self._materializer().bootstrap(
                profile=profile, session_token="test-token", now=AS_OF
            )

    def test_opaque_secret_key_is_not_sent_as_bearer_token(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="sb_secret_test-only",
            timeout_seconds=1,
        )
        self.assertEqual(repository._headers["apikey"], "sb_secret_test-only")
        self.assertNotIn("Authorization", repository._headers)
        repository._client.close()

    def test_legacy_service_role_jwt_remains_in_bearer_header(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="legacy-service-role-jwt-test-only",
            timeout_seconds=1,
        )
        self.assertEqual(
            repository._headers["Authorization"],
            "Bearer legacy-service-role-jwt-test-only",
        )
        repository._client.close()

    def test_trusted_rpc_failure_reports_safe_operation_and_category(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="sb_secret_test-only",
            timeout_seconds=1,
        )
        repository._client.post = Mock(
            return_value=SimpleNamespace(status_code=401)
        )
        with patch("app.performance_diagnostics._write") as diagnostic:
            with performance_request(enabled=True):
                with self.assertRaises(DataUnavailableError) as raised:
                    repository._rpc("forecast_initialize_revisions_v1", {})
        self.assertEqual(
            raised.exception.stage,
            "trusted_rpc:forecast_initialize_revisions_v1:http_401",
        )
        self.assertNotIn("example.supabase.co", str(raised.exception))
        messages = [" ".join(str(part) for part in call.args) for call in diagnostic.call_args_list]
        self.assertTrue(any("forecast_materialization.rpc_failed" in message for message in messages))
        self.assertTrue(any("rpc_name=trusted_rpc:forecast_initialize_revisions_v1" in message for message in messages))
        self.assertTrue(any("category=upstream_http_error" in message for message in messages))
        self.assertTrue(any("http_status=401" in message for message in messages))
        repository._client.close()

    def test_trusted_rpc_success_parses_json_response(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="sb_secret_test-only",
            timeout_seconds=1,
        )
        expected = [{"product_id": PRODUCT_A, "sales_revision": 0}]
        repository._client.post = Mock(
            return_value=SimpleNamespace(status_code=200, json=Mock(return_value=expected))
        )
        self.assertEqual(
            repository._rpc("forecast_initialize_revisions_v1", {"p_product_ids": [PRODUCT_A]}),
            expected,
        )
        repository._client.close()

    def test_revision_rpc_uses_deployed_parameter_names_and_types(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="sb_secret_test-only",
            timeout_seconds=1,
        )
        response = SimpleNamespace(
            status_code=200,
            json=Mock(
                return_value=[
                    {
                        "product_id": PRODUCT_A,
                        "sales_revision": 0,
                        "product_revision": 0,
                    }
                ]
            ),
        )
        request = Mock(return_value=response)
        repository._client.post = request

        revisions = repository.initialize_revisions(
            location_id=LOCATION_ID, product_ids=(PRODUCT_A,)
        )

        self.assertEqual(revisions[PRODUCT_A], {"sales_revision": 0, "product_revision": 0})
        self.assertEqual(
            request.call_args.kwargs["json"],
            {"p_location_id": LOCATION_ID, "p_product_ids": [PRODUCT_A]},
        )
        self.assertTrue(request.call_args.args[0].endswith(
            "/rest/v1/rpc/forecast_initialize_revisions_v1"
        ))
        repository._client.close()

    def test_rpc_error_diagnostics_capture_sqlstate_and_redact_values(self):
        repository = SupabaseForecastJobRepository(
            url="https://example.supabase.co",
            secret_key="sb_secret_test-only",
            timeout_seconds=1,
        )
        body = {
            "code": "42702",
            "message": 'column reference "product_id" is ambiguous',
            "details": "Failing row contains (private, 31000000-0000-4000-8000-000000000001)",
            "hint": "Check https://example.invalid/private and token eyJabc.def.ghi",
        }
        repository._client.post = Mock(
            return_value=SimpleNamespace(
                status_code=400, json=Mock(return_value=body)
            )
        )
        with patch("app.performance_diagnostics._write") as diagnostic:
            with performance_request(enabled=True) as request_id:
                with self.assertRaises(DataUnavailableError) as raised:
                    repository._rpc(
                        "forecast_initialize_revisions_v1",
                        {"p_location_id": LOCATION_ID, "p_product_ids": [PRODUCT_A]},
                    )

        self.assertEqual(
            raised.exception.stage,
            "trusted_rpc:forecast_initialize_revisions_v1:http_400",
        )
        rendered = " ".join(
            call.args[0] % call.args[1:]
            for call in diagnostic.call_args_list
        )
        self.assertIn(f"request_id={request_id}", rendered)
        self.assertIn("error_code=42702", rendered)
        self.assertIn("sqlstate=42702", rendered)
        self.assertIn("column reference", rendered)
        self.assertIn("[REDACTED_ROW]", rendered)
        self.assertIn("[REDACTED_URL]", rendered)
        self.assertIn("[REDACTED_TOKEN]", rendered)
        self.assertNotIn(PRODUCT_A, rendered)
        self.assertNotIn("example.invalid", rendered)
        self.assertNotIn("eyJabc", rendered)
        self.assertNotIn("sb_secret_test-only", rendered)
        repository._client.close()


if __name__ == "__main__":
    unittest.main()
