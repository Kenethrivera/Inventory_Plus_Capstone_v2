from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database" / "stage_5f_forecast_replenishment_configuration.sql"
ADAPTER = ROOT / "forecasting_backend" / "app" / "api" / "adapters.py"


class ReplenishmentPersistenceContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sql = MIGRATION.read_text(encoding="utf-8").lower()
        self.adapter = ADAPTER.read_text(encoding="utf-8")

    def test_table_is_forecasting_specific_and_not_directly_exposed(self) -> None:
        self.assertIn(
            "create table if not exists public.forecast_replenishment_configs",
            self.sql,
        )
        self.assertIn(
            "alter table public.forecast_replenishment_configs enable row level security",
            self.sql,
        )
        self.assertIn(
            "revoke all on table public.forecast_replenishment_configs",
            self.sql,
        )
        table_grant_section = self.sql.split(
            "create or replace function public.forecast_replenishment_config_v1", 1
        )[0]
        self.assertNotIn("to anon", table_grant_section)
        self.assertNotIn("to authenticated", table_grant_section)

    def test_rpcs_are_admin_and_server_location_scoped(self) -> None:
        self.assertIn("private.require_app_session_v1(p_session_token)", self.sql)
        self.assertGreaterEqual(self.sql.count("v_profile.role <> 'admin'"), 2)
        self.assertGreaterEqual(
            self.sql.count("product.location_id = v_profile.location_id"), 2
        )
        self.assertIn("and product.is_active", self.sql)
        self.assertIn("security definer", self.sql)
        self.assertIn("set search_path to 'pg_catalog', 'pg_temp'", self.sql)

    def test_configuration_has_verification_and_provenance_fields(self) -> None:
        for field in (
            "supplier_lead_time_days",
            "review_period_days",
            "safety_stock",
            "minimum_order_quantity",
            "supplier_pack_size",
            "supplier_order_unit",
            "unit_conversion_factor",
            "confirmed_incoming_quantity",
            "incoming_quantity_verified",
            "backorder_quantity",
            "backorder_quantity_verified",
            "supplier_availability",
            "data_source",
            "source_captured_at",
            "rationale",
        ):
            self.assertIn(field, self.sql)
        self.assertIn("admin estimates require a rationale", self.sql)
        self.assertIn("forecast_replenishment_conversion_unit_check", self.sql)
        self.assertIn(
            "supplier order unit is required for unit conversion", self.sql
        )
        self.assertIn("incoming quantity must be present only when verified", self.sql)
        self.assertIn("backorder quantity must be present only when verified", self.sql)

    def test_configuration_does_not_mutate_inventory_or_create_orders(self) -> None:
        self.assertNotIn("update public.products", self.sql)
        self.assertNotIn("insert into public.orders", self.sql)
        self.assertNotIn("insert into public.order_history", self.sql)
        self.assertNotIn("insert into public.transaction_history", self.sql)

    def test_python_adapter_uses_only_configuration_rpcs(self) -> None:
        self.assertIn('"forecast_replenishment_config_v1"', self.adapter)
        self.assertIn('"upsert_forecast_replenishment_config_v1"', self.adapter)
        self.assertNotIn('/rest/v1/forecast_replenishment_configs', self.adapter)


if __name__ == "__main__":
    unittest.main()
