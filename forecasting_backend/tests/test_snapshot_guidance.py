from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from app.api.contracts import AnalysisContext, DataUnavailableError, SessionProfile
from app.api.snapshot_guidance import current_stock_analysis
from app.api.service import ForecastAnalysisService
from app.forecasting.execution import DemandForecastExecutionInput
from app.recommendations.models import (
    InventoryBalanceBasis, InventorySnapshot, RecommendationPolicy,
    SupplierAvailability, SupplierPolicySnapshot,
)
from app.worker.bundle import build_output_bundle

from tests.test_forecast_worker import AS_OF, FakeExecutor, history_fixture, make_job


def saved_fixture():
    history = history_fixture()
    job = make_job(history)
    execution = FakeExecutor().execute(
        DemandForecastExecutionInput(history, "blend", 28, AS_OF, AS_OF, 28)
    )
    bundle = build_output_bundle(
        execution=execution,
        job=job,
        history=history,
        implementation_digest=job["requested_implementation_digest"],
        producer_config_digests={
            "blend": job["requested_model_config_digest"],
            "lightgbm": "a" * 64,
            "mean28": "b" * 64,
            "seasonal_experimental": "c" * 64,
        },
    )
    context = AnalysisContext(
        history=history,
        inventory=object(),  # calculators below record inputs without using stock
        supplier=object(),
        safety_stock=None,
        conversions=(),
        policy=object(),
        source_data_as_of=AS_OF,
        adapter_name="test",
    )
    snapshot = {
        "bundle": bundle,
        "product_id": history.product.product_id,
        "location_id": history.product.location_id,
        "inventory_unit": history.product.unit,
        "horizon_days": 28,
        "history_window_days": 365,
        "forecast_start_date": (AS_OF.date()).isoformat(),
        "forecast_end_date": (AS_OF.date() + timedelta(days=27)).isoformat(),
        "created_at": AS_OF.isoformat(),
        "source_data_as_of": AS_OF.isoformat(),
    }
    return history, execution, context, snapshot


class SnapshotGuidanceTests(unittest.TestCase):
    def test_saved_forecasts_use_existing_rules_with_current_stock(self):
        history, execution, _, snapshot = saved_fixture()
        context = AnalysisContext(
            history=history,
            inventory=InventorySnapshot(
                location_id=history.product.location_id,
                product_id=history.product.product_id,
                unit=history.product.unit,
                saleable_on_hand=Decimal("10"),
                confirmed_on_order=None,
                unfulfilled_reservations=Decimal("0"),
                backorders=None,
                max_capacity=None,
                balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
                captured_at=AS_OF,
            ),
            supplier=SupplierPolicySnapshot(
                supplier_id="test", order_unit="pcs", lead_time_days=7,
                minimum_order_quantity=None, pack_size=None,
                availability=SupplierAvailability.AVAILABLE, captured_at=AS_OF,
            ),
            safety_stock=None,
            conversions=(),
            policy=RecommendationPolicy(
                version="test", review_period_days=7,
                max_forecast_age=timedelta(hours=24),
                max_inventory_age=timedelta(days=7),
                max_supplier_age=timedelta(days=30),
                max_safety_stock_age=timedelta(days=30),
            ),
            source_data_as_of=AS_OF,
            adapter_name="test",
        )
        profile = SessionProfile("1", "admin", history.product.location_id, "Admin")
        service = ForecastAnalysisService(adapter=object())
        result = current_stock_analysis(
            service=service, profile=profile, context=context,
            snapshot=snapshot, now=AS_OF,
        )
        self.assertEqual(len(result["forecast"]["daily"]), 28)
        self.assertEqual(
            result["forecast"]["daily"][0]["quantity"],
            float(execution.requested_forecasts[0].quantity),
        )
        self.assertEqual(
            result["preliminary_restocking_insight"]["available_inventory"], 10.0
        )
        self.assertEqual(
            result["selected_model_preliminary_insight"]["predicted_demand"],
            float(sum((point.quantity for point in execution.requested_forecasts), Decimal("0"))),
        )
        self.assertEqual(
            result["preliminary_restocking_insight"]["predicted_demand"],
            float(sum((point.quantity for point in execution.preliminary_forecasts), Decimal("0"))),
        )
        self.assertTrue(result["preliminary_comparison_eligible"])
        self.assertEqual(result["forecast"]["requested_model"], "blend")

    def test_saved_roles_are_decoded_without_model_execution(self):
        history, execution, context, snapshot = saved_fixture()
        captured = {}

        def preliminary(*, forecast, inventory):
            captured["preliminary"] = forecast
            return object()

        def recommendation(*, forecast, **kwargs):
            captured["recommendation"] = forecast
            return object()

        service = SimpleNamespace(
            _preliminary_insights=SimpleNamespace(calculate=preliminary),
            _recommendations=SimpleNamespace(recommend=recommendation),
        )
        profile = SessionProfile("1", "admin", history.product.location_id, "Admin")
        with patch("app.api.snapshot_guidance.analysis_response") as serialize:
            serialize.return_value = {"ok": True}
            result = current_stock_analysis(
                service=service, profile=profile, context=context,
                snapshot=snapshot, now=AS_OF,
            )
            self.assertEqual(result, {"ok": True})
            requested = serialize.call_args.kwargs["forecasts"]
        self.assertEqual(len(requested), 28)
        self.assertEqual(requested[0].quantity, execution.requested_forecasts[0].quantity)
        self.assertEqual(len(captured["recommendation"].forecasts), 28)
        self.assertEqual(len(captured["preliminary"].forecasts), 28)
        self.assertEqual(
            captured["preliminary"].forecasts[0].quantity,
            execution.preliminary_forecasts[0].quantity,
        )

    def test_mismatched_saved_end_date_is_rejected(self):
        history, _, context, snapshot = saved_fixture()
        snapshot["forecast_end_date"] = AS_OF.date().isoformat()
        service = SimpleNamespace(
            _preliminary_insights=SimpleNamespace(calculate=lambda **_: object()),
            _recommendations=SimpleNamespace(recommend=lambda **_: object()),
        )
        profile = SessionProfile("1", "admin", history.product.location_id, "Admin")
        with self.assertRaises(DataUnavailableError):
            current_stock_analysis(
                service=service, profile=profile, context=context,
                snapshot=snapshot, now=AS_OF,
            )

    def test_manual_cold_start_preview_uses_saved_forecast_without_model_fitting(self):
        history, _, context, snapshot = saved_fixture()
        for point in snapshot["bundle"]["outputs"]["requested_forecasts"]["series"][0]["points"]:
            point["metadata"]["is_cold_start"] = True
        captured = {}
        service = SimpleNamespace(
            _preliminary_insights=SimpleNamespace(calculate=lambda **_: object()),
            _recommendations=SimpleNamespace(
                recommend=lambda **kwargs: captured.update(kwargs) or object()
            ),
        )
        profile = SessionProfile("1", "admin", history.product.location_id, "Admin")
        with patch("app.api.snapshot_guidance.analysis_response", return_value={"ok": True}):
            result = current_stock_analysis(
                service=service, profile=profile, context=context,
                snapshot=snapshot, now=AS_OF,
                manual_daily_demand=Decimal("3"), manual_unit=history.product.unit,
                manual_rationale="Opening shelf plan", manual_confirmed=True,
            )
        self.assertEqual(result, {"ok": True})
        self.assertEqual(captured["manual_demand"].daily_quantity, Decimal("3"))
        self.assertEqual(captured["manual_demand"].rationale, "Opening shelf plan")

    def test_manual_preview_rejects_non_cold_start_forecast(self):
        history, _, context, snapshot = saved_fixture()
        profile = SessionProfile("1", "admin", history.product.location_id, "Admin")
        with self.assertRaisesRegex(ValueError, "cold-start"):
            current_stock_analysis(
                service=object(), profile=profile, context=context,
                snapshot=snapshot, now=AS_OF,
                manual_daily_demand=Decimal("3"), manual_unit=history.product.unit,
                manual_rationale="Plan", manual_confirmed=True,
            )


if __name__ == "__main__":
    unittest.main()
