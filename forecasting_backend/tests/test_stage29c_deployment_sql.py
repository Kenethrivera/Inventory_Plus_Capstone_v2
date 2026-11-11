from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATABASE = ROOT / "database"
PROPOSAL = DATABASE / "stage_2_9c_recommendation_tracking_PROPOSAL.sql"
DRY_RUN = DATABASE / "stage_2_9c_recommendation_tracking_DRY_RUN.sql"
MIGRATION = DATABASE / "stage_2_9c_recommendation_tracking_MIGRATION.sql"
POST_DEPLOY = (
    DATABASE / "stage_2_9c_recommendation_tracking_POST_DEPLOY_READ_ONLY.sql"
)
ROLLBACK = DATABASE / "stage_2_9c_recommendation_tracking_ROLLBACK.sql"
SEASONAL_IMPORT = DATABASE / "stage_2_1_expanded_seasonal_simulation_PROPOSAL.sql"


def _sql(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _statements(sql: str, keyword: str) -> list[str]:
    return re.findall(rf"(?im)^\s*{keyword}\s*;\s*$", sql)


def _last_non_comment_line(sql: str) -> str:
    lines = [
        line.strip()
        for line in sql.splitlines()
        if line.strip() and not line.lstrip().startswith("--")
    ]
    return lines[-1].lower()


def _reviewed_core(sql: str) -> str:
    start = sql.index("create table public.forecast_recommendation_snapshots")
    final_comment = (
        "comment on table public.forecast_recommendation_reconciliations"
    )
    end = sql.index(final_comment, start)
    end = sql.index(";", end) + 1
    return sql[start:end]


class Stage29CDeploymentSqlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.proposal = _sql(PROPOSAL)
        cls.dry_run = _sql(DRY_RUN)
        cls.migration = _sql(MIGRATION)
        cls.post_deploy = _sql(POST_DEPLOY)
        cls.rollback = _sql(ROLLBACK)

    def test_dry_run_is_one_transaction_and_always_rolls_back(self) -> None:
        self.assertEqual(len(_statements(self.dry_run, "begin")), 1)
        self.assertEqual(len(_statements(self.dry_run, "commit")), 0)
        self.assertEqual(len(_statements(self.dry_run, "rollback")), 1)
        self.assertEqual(_last_non_comment_line(self.dry_run), "rollback;")
        self.assertIn("$preflight$", self.dry_run)
        self.assertIn("$verify$", self.dry_run)

    def test_migration_is_atomic_and_keeps_reviewed_ddl_exact(self) -> None:
        self.assertEqual(len(_statements(self.migration, "begin")), 1)
        self.assertEqual(len(_statements(self.migration, "commit")), 1)
        self.assertEqual(len(_statements(self.migration, "rollback")), 0)
        self.assertEqual(_reviewed_core(self.migration), _reviewed_core(self.proposal))
        self.assertEqual(_reviewed_core(self.dry_run), _reviewed_core(self.proposal))
        self.assertIn("Stage 2.9C object conflict", self.migration)
        self.assertIn("existing operational row counts changed", self.migration)

    def test_post_deploy_script_is_read_only_and_complete(self) -> None:
        self.assertIn("begin transaction read only;", self.post_deploy.lower())
        self.assertNotRegex(
            self.post_deploy,
            re.compile(
                r"(?im)^\s*(insert|update|delete|truncate|create|alter|drop|grant|revoke)\b"
            ),
        )
        for marker in (
            "01_tables_exist_and_rls_enabled",
            "02_rpc_signatures_security_and_owner",
            "03_named_constraints",
            "04_internal_foreign_keys_only",
            "05_supporting_indexes",
            "06_immutability_triggers",
            "07_no_direct_table_access",
            "08_no_direct_sequence_access",
            "OVERALL",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.post_deploy)

    def test_rollback_is_targeted_guarded_and_non_cascading(self) -> None:
        self.assertIn("v_history_removal_authorized boolean := false", self.rollback)
        self.assertIn("rollback refused: history exists", self.rollback.lower())
        self.assertNotRegex(self.rollback, re.compile(r"(?im)^\s*truncate\b"))
        self.assertNotRegex(self.rollback, re.compile(r"(?im)\bdrop\b[^;]*\bcascade\b"))
        self.assertNotRegex(
            self.rollback,
            re.compile(
                r"(?im)^\s*(insert|update|delete)\s+(into\s+|from\s+)?public\.(products|transaction_history|orders|order_history)\b"
            ),
        )
        self.assertIn("obj_description", self.rollback)

    def test_access_boundary_is_service_role_only(self) -> None:
        for sql in (self.dry_run, self.migration):
            with self.subTest(file_size=len(sql)):
                self.assertGreaterEqual(sql.count("to service_role, postgres"), 5)
                self.assertGreaterEqual(
                    sql.count("from public, anon, authenticated"), 5
                )
                self.assertIn("private.require_app_session_v1", sql)
                self.assertIn("v_profile.role <> 'admin'", sql)

    def test_completed_seasonal_import_is_disabled_again(self) -> None:
        import_sql = _sql(SEASONAL_IMPORT)
        self.assertIn(
            "insert into _stage21_authorization values (false);", import_sql
        )
        self.assertNotIn(
            "insert into _stage21_authorization values (true);", import_sql
        )


if __name__ == "__main__":
    unittest.main()
