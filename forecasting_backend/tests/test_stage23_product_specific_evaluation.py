from __future__ import annotations

import json
import unittest
from pathlib import Path


REPORT_PATH = (
    Path(__file__).resolve().parents[1]
    / "simulation_reports"
    / "product_specific_seasonal_evaluation.json"
)


class Stage23ProductSpecificEvaluationArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = json.loads(REPORT_PATH.read_text(encoding="utf-8"))

    def test_population_and_validation_windows_are_frozen(self) -> None:
        contract = self.report["evaluation_contract"]
        self.assertEqual(contract["population"]["expanded_products_evaluated"], 24)
        self.assertEqual(contract["population"]["original_products_evaluated"], 0)
        self.assertEqual(contract["history_windows_days"], [365, 730, 1095])
        windows = self.report["validation_by_history_window"]
        origins = [windows[value]["origins"] for value in ("365", "730", "1095")]
        self.assertTrue(all(value == origins[0] for value in origins[1:]))
        self.assertEqual(len(origins[0]), 18)
        self.assertEqual(
            windows["1095"]["observed_training_calendar_days"],
            {"minimum": 731, "maximum": 1068},
        )

    def test_selection_is_validation_only_and_final_models_are_limited(self) -> None:
        selection = self.report["validation_selection"]
        self.assertFalse(selection["selection_used_final_test"])
        self.assertEqual(selection["history_window_days"], 1095)
        self.assertEqual(selection["hyperparameters"], "conservative")
        final_counts = self.report["final_test"]["actual_model_counts"]
        self.assertEqual(
            set(final_counts),
            {
                "existing_lightgbm",
                "ablation_conservative",
                "seasonal_conservative",
            },
        )

    def test_all_models_ran_without_fallback(self) -> None:
        reports = list(self.report["validation_by_history_window"].values()) + [
            self.report["final_test"]
        ]
        for report in reports:
            for requested, actual_counts in report["actual_model_counts"].items():
                self.assertEqual(sum(actual_counts.values()), 24 * 18)
                self.assertFalse(
                    any("fallback" in actual for actual in actual_counts),
                    requested,
                )

    def test_no_sales_and_intermittent_controls_remain_distinct(self) -> None:
        selected = self.report["validation_selection"]["model"]
        patterns = self.report["final_test"]["by_demand_pattern"][selected]
        self.assertEqual(patterns["no_sales"]["predicted_total"], 0)
        self.assertGreater(patterns["intermittent"]["predicted_total"], 0)
        self.assertGreater(patterns["intermittent_low"]["predicted_total"], 0)

    def test_acceptance_and_pretransition_checks_pass(self) -> None:
        recommendation = self.report["recommendation"]
        self.assertEqual(recommendation["decision"], "ACCEPT")
        self.assertTrue(recommendation["integration_recommended"])
        self.assertTrue(recommendation["acceptance_checks_all_passed"])
        self.assertTrue(
            all(
                value > 0
                for value in recommendation[
                    "pretransition_wape_gains_vs_ablation"
                ].values()
            )
        )

    def test_product_level_regressions_are_disclosed(self) -> None:
        comparison = self.report["product_level_comparison"]
        self.assertEqual(comparison["existing_lightgbm"]["improved"], 17)
        self.assertEqual(comparison["existing_lightgbm"]["regressed"], 5)
        self.assertEqual(comparison["ablation_conservative"]["improved"], 15)
        self.assertEqual(comparison["ablation_conservative"]["regressed"], 7)


if __name__ == "__main__":
    unittest.main()
