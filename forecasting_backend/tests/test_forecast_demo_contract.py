from __future__ import annotations

import json
import unittest
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

from app.forecasting.models import (
    DataProvenance,
    DataQualityMetadata,
    DatasetRole,
    DemandForecast,
    ForecastMetadata,
)
from app.recommendations import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    RecommendationEngine,
    RecommendationPolicy,
    SafetyStockInput,
    SafetyStockSource,
    SupplierAvailability,
    SupplierPolicySnapshot,
    UnitConversion,
)


ROOT = Path(__file__).resolve().parents[1]
DEMO = ROOT / "integration" / "forecast_demo"
MANIFEST = json.loads((DEMO / "expected_results.json").read_text(encoding="utf-8"))
AS_OF = datetime.fromisoformat(MANIFEST["fixture"]["as_of"])
LOCATION_ID = MANIFEST["fixture"]["location_id"]


def _decimal(value: object) -> Decimal:
    return Decimal(str(value))


class ForecastDemoContractTests(unittest.TestCase):
    def test_shared_project_mode_keeps_original_isolation_guard_intact(self) -> None:
        isolated_seed = (DEMO / "forecast_demo_seed.sql").read_text(
            encoding="utf-8"
        )
        shared_seed = (DEMO / "forecast_demo_shared_seed.sql").read_text(
            encoding="utf-8"
        )
        shared_preview = (DEMO / "forecast_demo_shared_preview.sql").read_text(
            encoding="utf-8"
        )
        shared_reset = (DEMO / "forecast_demo_shared_reset.sql").read_text(
            encoding="utf-8"
        )
        shared_wrapper = (DEMO / "forecast_demo_shared.ps1").read_text(
            encoding="utf-8"
        )
        project_ref = "pzotcznujkuzymndluwl"

        self.assertIn("private.forecast_demo_isolated_environment", isolated_seed)
        self.assertNotIn("SEED_SHARED_FORECAST_DEMO", isolated_seed)
        for script in (shared_seed, shared_preview, shared_reset, shared_wrapper):
            self.assertIn(project_ref, script)
        self.assertIn("set transaction read only", shared_preview.lower())
        self.assertIn("rollback;", shared_preview.lower())
        self.assertIn("DISPOSABLE_STAGING_CONFIRMED_", shared_seed)
        self.assertIn("SEED_SHARED_FORECAST_DEMO", shared_seed)
        self.assertIn("RESET_SHARED_FORECAST_DEMO", shared_reset)
        self.assertNotIn("BackupDirectory", shared_wrapper)
        for script in (shared_seed, shared_reset):
            self.assertNotIn("truncate ", script.lower())
            self.assertNotIn(" cascade", script.lower())

    def test_reference_values_and_seed_guards_are_fixed(self) -> None:
        reference = MANIFEST["products"][0]
        self.assertEqual(reference["mean28"], {
            "today": 5,
            "next_7_days": 35,
            "next_28_days": 140,
        })
        self.assertEqual(reference["replenishment"]["reorder_point"], 45)
        self.assertEqual(
            reference["replenishment"]["recommended_inventory_units"], 50
        )
        seed = (DEMO / "forecast_demo_seed.sql").read_text(encoding="utf-8")
        reset = (DEMO / "forecast_demo_reset.sql").read_text(encoding="utf-8")
        self.assertIn("inventory-plus-forecast-demo", seed)
        self.assertIn("expected 114 completed daily orders", seed)
        self.assertIn("RESET_FORECAST_DEMO", reset)
        self.assertNotIn("truncate ", seed.lower())
        self.assertNotIn("truncate ", reset.lower())

    def test_dashboard_totals_are_unit_separated(self) -> None:
        totals: dict[str, dict[str, Decimal]] = {}
        for product in MANIFEST["products"]:
            mean28 = product["mean28"]
            if mean28.get("demand_is_unknown"):
                continue
            unit = product["unit"]
            unit_totals = totals.setdefault(
                unit,
                {"today": Decimal("0"), "next_7_days": Decimal("0"),
                 "next_28_days": Decimal("0")},
            )
            for key in unit_totals:
                unit_totals[key] += _decimal(mean28[key])
        for unit, expected in MANIFEST["dashboard"]["by_unit"].items():
            self.assertEqual(
                totals[unit],
                {name: _decimal(value) for name, value in expected.items()},
            )

    def test_configured_recommendations_use_existing_engine(self) -> None:
        engine = RecommendationEngine()
        generated_at = AS_OF
        forecast_start = date(2026, 11, 6)
        quality = DataQualityMetadata(
            history_calendar_days=114,
            observed_sales_days=114,
            assumed_zero_sales_days=0,
            stockout_censored_days=0,
            availability_evidence_days=0,
            availability_unknown_days=114,
            valid_target_days=114,
        )
        metadata = ForecastMetadata(
            model_name="mean28",
            model_version="1",
            lookback_days=28,
            history_days_available=114,
            sample_days_used=28,
            nonzero_demand_days=28,
            is_cold_start=False,
            cold_start_reason=None,
            cold_start_strategy=None,
            history_start=date(2026, 7, 15),
            history_end=date(2026, 11, 5),
            dataset_role=DatasetRole.HISTORICAL,
            data_provenance=DataProvenance.SYNTHETIC,
            forecast_horizon_days=28,
            data_quality=quality,
        )
        policy_age = timedelta(days=30)
        for product in MANIFEST["products"]:
            expected = product["replenishment"]
            mean28 = product["mean28"]
            if not expected["configured"] or mean28.get("demand_is_unknown"):
                continue
            with self.subTest(product=product["sku"]):
                daily = _decimal(mean28["today"])
                forecasts = tuple(
                    DemandForecast(
                        forecast_date=forecast_start + timedelta(days=index),
                        location_id=LOCATION_ID,
                        product_id=product["product_id"],
                        product_name=product["name"],
                        unit=product["unit"],
                        quantity=daily,
                        metadata=metadata,
                        sku=product["sku"],
                    )
                    for index in range(28)
                )
                inventory = product["inventory"]
                snapshot = InventorySnapshot(
                    location_id=LOCATION_ID,
                    product_id=product["product_id"],
                    unit=product["unit"],
                    saleable_on_hand=_decimal(inventory["on_hand"]),
                    confirmed_on_order=_decimal(inventory["confirmed_inbound"]),
                    unfulfilled_reservations=Decimal("0"),
                    backorders=_decimal(inventory["backorders"]),
                    max_capacity=_decimal(inventory["max_capacity"]),
                    balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
                    captured_at=generated_at,
                )
                supplier = SupplierPolicySnapshot(
                    supplier_id="forecast-demo",
                    order_unit=expected["order_unit"],
                    lead_time_days=expected["lead_time_days"],
                    minimum_order_quantity=_decimal(
                        expected["minimum_order_quantity"]
                    ),
                    pack_size=_decimal(expected["pack_size"]),
                    availability=SupplierAvailability.AVAILABLE,
                    captured_at=generated_at,
                )
                conversion = (
                    UnitConversion(
                        from_unit=expected["order_unit"],
                        to_unit=product["unit"],
                        factor=_decimal(expected["inventory_units_per_order_unit"]),
                    ),
                ) if "inventory_units_per_order_unit" in expected else ()
                result = engine.recommend(
                    forecast=DemandForecastSnapshot(
                        forecasts=forecasts,
                        generated_at=generated_at,
                        source_data_as_of=generated_at,
                    ),
                    inventory=snapshot,
                    supplier=supplier,
                    safety_stock=SafetyStockInput(
                        quantity=_decimal(expected["safety_stock"]),
                        unit=product["unit"],
                        source=SafetyStockSource.CONFIGURED,
                        captured_at=generated_at,
                    ),
                    policy=RecommendationPolicy(
                        version="forecast-demo-v1",
                        review_period_days=expected["review_period_days"],
                        max_forecast_age=policy_age,
                        max_inventory_age=policy_age,
                        max_supplier_age=policy_age,
                        max_safety_stock_age=policy_age,
                    ),
                    recommendation_at=generated_at,
                    conversions=conversion,
                )
                self.assertEqual(result.status.value, expected["status"])
                self.assertEqual(
                    result.calculation.reorder_point,
                    _decimal(expected["reorder_point"]),
                )
                self.assertEqual(
                    result.recommended_quantity_order_units,
                    _decimal(expected["recommended_order_units"]),
                )
                self.assertEqual(
                    result.recommended_quantity_inventory_units,
                    _decimal(expected["recommended_inventory_units"]),
                )


if __name__ == "__main__":
    unittest.main()
