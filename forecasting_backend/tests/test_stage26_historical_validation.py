from __future__ import annotations

import csv
import json
import re
import tempfile
import unittest
from pathlib import Path

from app.simulation.stage26_historical_validation import (
    Stage26HistoricalValidator,
    compare_live_history,
    load_dense_history,
    verify_frozen_history,
)


BACKEND_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_ROOT.parent
FROZEN = BACKEND_ROOT / "simulation_reports" / "expanded_seasonal_daily_demand.csv"
STAGE23 = BACKEND_ROOT / "simulation_reports" / "product_specific_seasonal_evaluation.json"
READ_ONLY_EXPORT = PROJECT_ROOT / "database" / "stage_2_6_imported_history_export_READ_ONLY.sql"


class Stage26HistoricalValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.frozen = load_dense_history(FROZEN)

    def test_frozen_history_is_dense_and_matches_the_frozen_generator(self) -> None:
        result = verify_frozen_history(self.frozen)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["expected_products"], 24)
        self.assertEqual(result["actual_rows"], 24 * 1461)
        self.assertEqual(result["missing_product_date_rows"], 0)
        self.assertEqual(result["unexpected_product_date_rows"], 0)
        self.assertGreater(result["zero_demand_rows"], 0)
        self.assertGreater(result["positive_demand_rows"], 0)

    def test_live_comparison_detects_a_single_quantity_mismatch(self) -> None:
        changed = self._changed_history(row_index=0)
        result = compare_live_history(self.frozen, changed)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["quantity_mismatches"], 1)

    def test_history_mismatch_stops_before_accuracy_evaluation(self) -> None:
        changed = self._changed_history(row_index=-1)
        stage23 = json.loads(STAGE23.read_text(encoding="utf-8"))
        report, points, replay = Stage26HistoricalValidator(
            frozen_history=self.frozen,
            live_history=changed,
            stage23_report=stage23,
        ).run()
        self.assertEqual(report["decision"], "FAIL")
        self.assertEqual(report["accuracy_evaluation"], "NOT_RUN_DUE_TO_HISTORY_MISMATCH")
        self.assertEqual(points, [])
        self.assertEqual(replay, [])

    def test_export_sql_is_explicitly_read_only_and_separates_originals(self) -> None:
        sql = READ_ONLY_EXPORT.read_text(encoding="utf-8")
        executable = "\n".join(
            line for line in sql.splitlines() if not line.lstrip().startswith("--")
        )
        self.assertIn("begin transaction read only", executable.lower())
        self.assertIn("original_active_products", executable)
        self.assertIn("expanded-ph-seasonal-simulation-v1", executable)
        self.assertIsNone(
            re.search(
                r"\b(insert|update|delete|truncate|alter|drop|create|grant|revoke)\b",
                executable,
                flags=re.IGNORECASE,
            )
        )

    def _changed_history(self, *, row_index: int):
        with FROZEN.open("r", encoding="utf-8-sig", newline="") as source:
            rows = list(csv.DictReader(source))
            fieldnames = list(rows[0])
        rows[row_index]["quantity"] = str(float(rows[row_index]["quantity"]) + 1)
        with tempfile.TemporaryDirectory() as directory:
            changed_path = Path(directory) / "changed.csv"
            with changed_path.open("w", encoding="utf-8", newline="") as target:
                writer = csv.DictWriter(target, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(rows)
            return load_dense_history(changed_path)


if __name__ == "__main__":
    unittest.main()
