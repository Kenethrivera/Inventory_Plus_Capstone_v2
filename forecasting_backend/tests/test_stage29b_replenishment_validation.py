from __future__ import annotations

import unittest

from app.simulation.stage29b_replenishment_validation import run_validation


class Stage29BReplenishmentValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = run_validation()
        cls.by_name = {
            item["scenario"]: item for item in cls.report["scenarios"]
        }

    def test_every_isolated_scenario_passes(self) -> None:
        failures = {
            item["scenario"]: item["mismatches"]
            for item in self.report["scenarios"]
            if not item["passed"]
        }
        self.assertEqual(failures, {})
        self.assertEqual(self.report["decision"], "PASS")

    def test_concrete_blocks_complete_calculation_matches_independent_values(self) -> None:
        actual = self.by_name["concrete_blocks_complete_verified_inputs"]["actual"]
        self.assertEqual(actual["inventory_position"], "115")
        self.assertEqual(actual["lead_time_demand"], "50")
        self.assertEqual(actual["reorder_point"], "70")
        self.assertEqual(actual["protection_period_days"], 12)
        self.assertEqual(actual["order_up_to_target"], "140")
        self.assertEqual(actual["preliminary_inventory_units"], "25")
        self.assertEqual(actual["rounded_order_units"], "3")
        self.assertEqual(actual["suggested_inventory_units"], "30")

    def test_concrete_blocks_unknown_inputs_are_not_zero(self) -> None:
        actual = self.by_name["concrete_blocks_missing_verified_inputs"]["actual"]
        self.assertIsNone(actual["suggested_inventory_units"])
        for warning in (
            "confirmed_on_order_missing",
            "backorders_missing",
            "supplier_lead_time_missing",
            "review_period_missing",
        ):
            self.assertIn(warning, actual["warnings"])

    def test_known_zero_and_unknown_are_distinct(self) -> None:
        known = self.by_name["confirmed_zero_incoming_and_backorders"]["actual"]
        unknown = self.by_name["concrete_blocks_missing_verified_inputs"]["actual"]
        self.assertEqual(known["inventory_position"], "100")
        self.assertEqual(known["suggested_inventory_units"], "40")
        self.assertIsNone(unknown["inventory_position"])
        self.assertIsNone(unknown["suggested_inventory_units"])

    def test_no_scenario_creates_purchase_order(self) -> None:
        self.assertTrue(
            all(
                item["actual"]["purchase_order_created"] is False
                for item in self.report["scenarios"]
            )
        )


if __name__ == "__main__":
    unittest.main()

