from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTEXT_SQL = ROOT / "database" / "stage_5d_forecast_product_context.sql"
SCHEMA_CONTEXT_SQL = (
    ROOT
    / "supabase"
    / "schemas"
    / "public"
    / "functions"
    / "forecast_product_context_v1.sql"
)
ADAPTER = ROOT / "forecasting_backend" / "app" / "api" / "adapters.py"


class ForecastingDatabaseContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sql = CONTEXT_SQL.read_text(encoding="utf-8").lower()
        self.adapter = ADAPTER.read_text(encoding="utf-8")

    def test_migration_and_declarative_schema_copies_match(self) -> None:
        self.assertEqual(
            CONTEXT_SQL.read_text(encoding="utf-8"),
            SCHEMA_CONTEXT_SQL.read_text(encoding="utf-8"),
        )

    def test_product_context_is_read_only_session_and_location_scoped(self) -> None:
        self.assertIn("security definer", self.sql)
        self.assertIn("set search_path", self.sql)
        self.assertIn("private.require_app_session_v1(p_session_token)", self.sql)
        self.assertIn("v_profile.role <> 'admin'", self.sql)
        self.assertIn("product.location_id = v_profile.location_id", self.sql)
        self.assertIn("and product.is_active", self.sql)
        self.assertIn("v_product.id is distinct from p_product_id", self.sql)
        self.assertIn(
            "v_product.location_id is distinct from v_profile.location_id", self.sql
        )
        self.assertIn("pg_catalog.btrim(v_product.product_name)", self.sql)
        self.assertIn("pg_catalog.btrim(v_product.unit)", self.sql)
        self.assertNotIn("insert into", self.sql)
        self.assertNotIn("update public.", self.sql)
        self.assertNotIn("delete from", self.sql)

    def test_product_context_exposes_only_forecasting_fields(self) -> None:
        for field in (
            "'id'",
            "'location_id'",
            "'sku'",
            "'product_name'",
            "'unit'",
            "'product_quantity'",
            "'max_quantity'",
            "'created_at'",
            "'updated_at'",
            "'is_active'",
        ):
            self.assertIn(field, self.sql)
        for sensitive in ("password", "email", "phone", "address"):
            self.assertNotIn(sensitive, self.sql)

    def test_rpc_signature_and_execution_grants_match_the_adapter(self) -> None:
        self.assertIn("p_session_token text", self.sql)
        self.assertIn("p_product_id uuid", self.sql)
        self.assertIn(") returns jsonb", self.sql)
        self.assertIn("set search_path to 'pg_catalog', 'pg_temp'", self.sql)
        self.assertIn(
            "revoke all on function public.forecast_product_context_v1(text, uuid)",
            self.sql,
        )
        self.assertIn("from public, authenticated", self.sql)
        self.assertIn("to anon, service_role, postgres", self.sql)
        self.assertIn('"p_session_token": session_token', self.adapter)
        self.assertIn('"p_product_id": product_id', self.adapter)

    def test_backend_has_no_stage6b7_or_direct_product_table_dependency(self) -> None:
        self.assertIn('"forecast_product_context_v1"', self.adapter)
        self.assertNotIn('"forecast_product_snapshot_v1"', self.adapter)
        self.assertNotIn('/rest/v1/products', self.adapter)


if __name__ == "__main__":
    unittest.main()
