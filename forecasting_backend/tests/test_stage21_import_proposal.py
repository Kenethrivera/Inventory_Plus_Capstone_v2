from __future__ import annotations

import re
import unittest
from pathlib import Path

from app.simulation.expanded_seasonal_fixture import PRODUCTS


ROOT = Path(__file__).resolve().parents[2]
SQL_PATH = ROOT / "database" / "stage_2_1_expanded_seasonal_simulation_PROPOSAL.sql"
PREFLIGHT_PATH = (
    ROOT
    / "database"
    / "stage_2_4_expanded_seasonal_simulation_PREFLIGHT_READ_ONLY.sql"
)


class Stage21ImportProposalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = SQL_PATH.read_text(encoding="utf-8")

    def test_proposal_is_disabled_by_default(self) -> None:
        self.assertIn("insert into _stage21_authorization values (false)", self.sql)
        self.assertIn("proposal is disabled", self.sql)

    def test_proposal_contains_every_frozen_sku_once_in_plan(self) -> None:
        plan_section = self.sql.split("do $preflight$", maxsplit=1)[0]
        for product in PRODUCTS:
            self.assertEqual(plan_section.count(f"'{product.sku}'"), 1)

    def test_import_is_tagged_and_has_targeted_rollback(self) -> None:
        self.assertIn("sim-season-v1:product:", self.sql)
        self.assertIn("sim-season-v1:order:", self.sql)
        self.assertIn("sim-season-v1:checkout:", self.sql)
        self.assertIn("TARGETED MANUAL ROLLBACK", self.sql)
        self.assertRegex(
            self.sql,
            re.compile(
                r"delete from public\.transaction_history.*?"
                r"delete from public\.orders.*?"
                r"delete from public\.order_history.*?"
                r"delete from public\.products",
                re.DOTALL,
            ),
        )

    def test_proposal_has_no_schema_or_security_changes(self) -> None:
        lowered = self.sql.casefold()
        self.assertNotIn("alter table", lowered)
        self.assertNotIn("create policy", lowered)
        self.assertNotIn("disable trigger", lowered)
        self.assertNotIn("drop table public.", lowered)
        self.assertNotIn("truncate", lowered)

    def test_stage24_preflight_and_preservation_guards_are_present(self) -> None:
        self.assertIn("Required import columns are missing", self.sql)
        self.assertIn("orders_validate_completed_snapshot_v1", self.sql)
        self.assertIn("_stage21_preservation_baseline", self.sql)
        self.assertIn("Pre-existing operational row counts were not preserved", self.sql)
        self.assertIn("exceeds catalog max quantity", self.sql)
        self.assertIn("statement_timestamp()", self.sql)
        profile_sections = re.findall(
            r"from public\.profiles.*?location_id = .*?::uuid;",
            self.sql,
            flags=re.DOTALL,
        )
        self.assertEqual(len(profile_sections), 2)
        self.assertTrue(all("is_active" not in value for value in profile_sections))

    def test_completed_order_trigger_is_required_once_and_enabled(self) -> None:
        self.assertIn("v_enabled_count bigint", self.sql)
        self.assertIn("if v_count <> 1 or v_enabled_count <> 1", self.sql)
        self.assertIn(
            "private.assert_completed_order_snapshot_v1()",
            self.sql,
        )
        self.assertIn("trigger_row.tgenabled in ('O', 'A')", self.sql)


class Stage24ReadOnlyPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = PREFLIGHT_PATH.read_text(encoding="utf-8")

    def test_preflight_is_enforced_read_only_and_has_no_write_statement(self) -> None:
        lowered = self.sql.casefold()
        self.assertIn("begin transaction read only", lowered)
        self.assertIn("commit;", lowered)
        sql_without_comments = "\n".join(
            line for line in lowered.splitlines() if not line.lstrip().startswith("--")
        )
        for statement in (
            "insert into",
            "update ",
            "delete from",
            "truncate ",
            "alter ",
            "create ",
            "drop ",
        ):
            self.assertNotIn(statement, sql_without_comments)

    def test_preflight_covers_schema_functions_triggers_admin_and_duplicates(self) -> None:
        for expected in (
            "required tables",
            "required columns and types",
            "required function signatures",
            "required constraints",
            "required idempotency indexes",
            "orders_sync_order_history_v1",
            "orders_validate_completed_snapshot_v1",
            "order_history_validate_completed_snapshot_v1",
            "existing Admin and location",
            "planned product ID, SKU, and import-tag collisions",
            "deterministic order ID collisions",
            "tagged inventory-movement collisions",
            "OVERALL",
        ):
            self.assertIn(expected, self.sql)

    def test_preflight_contains_all_frozen_products(self) -> None:
        for product in PRODUCTS:
            self.assertEqual(self.sql.count(f"'{product.product_id}'::uuid"), 1)
            self.assertEqual(self.sql.count(f"'{product.sku}'"), 1)


if __name__ == "__main__":
    unittest.main()
