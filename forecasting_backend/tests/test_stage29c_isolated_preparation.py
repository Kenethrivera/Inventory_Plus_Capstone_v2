from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INTEGRATION = ROOT / "forecasting_backend" / "integration" / "stage29c"


class Stage29CIsolatedPreparationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = (INTEGRATION / "test_stage29c_isolated_database.py").read_text(
            encoding="utf-8"
        )
        cls.authorization = (
            INTEGRATION / "stage29c_authorize_disposable.sql"
        ).read_text(encoding="utf-8")
        cls.cleanup = (INTEGRATION / "stage29c_cleanup.sql").read_text(
            encoding="utf-8"
        )

    def test_runner_refuses_protected_project_and_requires_two_sided_guard(self) -> None:
        self.assertIn('PROTECTED_PROJECT_REF = "pzotcznujkuzymndluwl"', self.runner)
        self.assertIn("STAGE29C_TEST_WRITE_CONFIRMATION", self.runner)
        self.assertIn("private.stage29c_isolated_environment", self.runner)
        self.assertIn("Database-side Stage 2.9C authorization is absent", self.runner)

    def test_operator_authorization_cannot_target_protected_project(self) -> None:
        self.assertIn("pzotcznujkuzymndluwl", self.authorization)
        self.assertIn(
            "I_APPROVE_STAGE29C_WRITES_ON_THIS_DISPOSABLE_DATABASE",
            self.authorization,
        )
        self.assertNotIn("if not exists", self.authorization.lower())

    def test_cleanup_is_scoped_and_has_no_cascade(self) -> None:
        self.assertIn("stage29c_isolated_environment", self.cleanup)
        self.assertIn("stage29c-isolated-test", self.cleanup)
        self.assertNotIn("cascade", self.cleanup.lower())
        self.assertNotIn("truncate", self.cleanup.lower())

    def test_runner_covers_required_database_behaviors(self) -> None:
        for marker in (
            "migration_signatures_and_privileges",
            "authorization_forgery_staleness_and_idempotency",
            "pending_partial_multiple_receipts_and_reconciliation",
            "concurrent_allocation_prevents_overallocation",
            "product_deletion_compatibility",
            "records_are_immutable",
            "inventory_before",
            "experimental=True",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.runner)


if __name__ == "__main__":
    unittest.main()
