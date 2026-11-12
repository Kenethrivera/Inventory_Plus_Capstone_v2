from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_MIGRATION = ROOT / "database" / "stage_6b5_data_integrity_remediation.sql"
RESTORE_MIGRATION = ROOT / "database" / (
    "stage_2_4_restore_completed_snapshot_validation.sql"
)
DECLARATIVE_FUNCTION = ROOT / "supabase" / "schemas" / "private" / (
    "functions/assert_completed_order_snapshot_v1.sql"
)
ORDERS_SCHEMA = ROOT / "supabase" / "schemas" / "public" / "tables/orders.sql"
HISTORY_SCHEMA = ROOT / "supabase" / "schemas" / "public" / (
    "tables/order_history.sql"
)


def _normalized(text: str) -> str:
    return " ".join(text.lower().split())


def _function_body(text: str) -> str:
    match = re.search(r"as \$function\$(.*?)\$function\$;", text, re.I | re.S)
    if match is None:
        raise AssertionError("assert_completed_order_snapshot_v1 body not found")
    return _normalized(match.group(1))


class Stage24SnapshotValidatorMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE_MIGRATION.read_text(encoding="utf-8")
        cls.restore = RESTORE_MIGRATION.read_text(encoding="utf-8")
        cls.restore_normalized = _normalized(cls.restore)
        cls.declarative = DECLARATIVE_FUNCTION.read_text(encoding="utf-8")

    def test_restore_uses_the_original_validator_body_without_changes(self) -> None:
        self.assertEqual(_function_body(self.source), _function_body(self.restore))
        self.assertEqual(_function_body(self.source), _function_body(self.declarative))

    def test_restore_uses_the_original_trigger_definitions(self) -> None:
        for table_name, trigger_name in (
            ("orders", "orders_validate_completed_snapshot_v1"),
            ("order_history", "order_history_validate_completed_snapshot_v1"),
        ):
            definition = _normalized(
                f"create trigger {trigger_name} "
                "before insert or update of status, items, completed_at "
                f"on public.{table_name} for each row execute function "
                "private.assert_completed_order_snapshot_v1();"
            )
            self.assertIn(definition, _normalized(self.source))
            self.assertIn(definition, self.restore_normalized)

    def test_restore_is_atomic_and_has_read_only_verification(self) -> None:
        self.assertTrue(self.restore_normalized.startswith("-- inventory plus"))
        self.assertIn("begin;", self.restore_normalized)
        self.assertIn("set local lock_timeout = '5s';", self.restore_normalized)
        self.assertIn("begin transaction read only;", self.restore_normalized)
        self.assertIn("'overall'", self.restore_normalized)
        self.assertEqual(self.restore_normalized.count("commit;"), 2)

    def test_restore_does_not_change_rows_rls_or_seasonal_import_data(self) -> None:
        sql_without_comments = re.sub(
            r"--.*?$", "", self.restore.lower(), flags=re.MULTILINE
        )
        for forbidden in (
            "insert into",
            "update public.",
            "delete from",
            "truncate",
            "alter table",
            "create table",
            "drop table",
            "create policy",
            "drop policy",
            "enable row level security",
            "disable row level security",
        ):
            self.assertNotIn(forbidden, sql_without_comments)
        self.assertNotIn("order_history_data_issues", sql_without_comments)
        self.assertNotIn("stage21", sql_without_comments)

    def test_declarative_schema_contains_both_intended_triggers(self) -> None:
        orders = _normalized(ORDERS_SCHEMA.read_text(encoding="utf-8"))
        history = _normalized(HISTORY_SCHEMA.read_text(encoding="utf-8"))
        self.assertIn("orders_validate_completed_snapshot_v1", orders)
        self.assertIn("order_history_validate_completed_snapshot_v1", history)
        self.assertIn("private.assert_completed_order_snapshot_v1()", orders)
        self.assertIn("private.assert_completed_order_snapshot_v1()", history)


if __name__ == "__main__":
    unittest.main()
