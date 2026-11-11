from __future__ import annotations

import json
import unittest
from pathlib import Path


REPORT_PATH = (
    Path(__file__).resolve().parents[1]
    / "simulation_reports"
    / "revised_seasonal_evaluation.json"
)


class Stage22RevisedEvaluationArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = json.loads(REPORT_PATH.read_text(encoding="utf-8"))

    def test_population_is_expanded_24_only(self) -> None:
        population = self.report["evaluation_contract"]["population"]
        self.assertEqual(population["expanded_products_evaluated"], 24)
        self.assertEqual(population["original_products_evaluated"], 0)
        self.assertFalse(population["combined_population"])

    def test_history_windows_share_origins_without_padding(self) -> None:
        windows = self.report["by_history_window"]
        for split in ("validation", "final_test"):
            origin_sets = [windows[value][split]["origins"] for value in windows]
            self.assertTrue(all(value == origin_sets[0] for value in origin_sets[1:]))
            self.assertEqual(len(origin_sets[0]), 18)
        self.assertEqual(
            windows["1095"]["validation"]["observed_training_calendar_days"],
            {"minimum": 731, "maximum": 1068},
        )
        self.assertEqual(
            windows["1095"]["final_test"]["observed_training_calendar_days"],
            {"minimum": 1095, "maximum": 1095},
        )

    def test_every_requested_model_ran_without_fallback(self) -> None:
        for window in self.report["by_history_window"].values():
            for split in window.values():
                for requested, actual_counts in split["actual_model_counts"].items():
                    self.assertEqual(sum(actual_counts.values()), 24 * 18)
                    self.assertFalse(
                        any("fallback" in actual for actual in actual_counts),
                        requested,
                    )

    def test_never_sold_is_zero_and_intermittent_is_not_suppressed(self) -> None:
        selected = self.report["validation_selection"]["model"]
        patterns = self.report["selected_final_test"]["by_demand_pattern"][selected]
        self.assertEqual(patterns["no_sales"]["predicted_total"], 0)
        self.assertGreater(patterns["intermittent"]["predicted_total"], 0)
        self.assertGreater(patterns["intermittent_low"]["predicted_total"], 0)

    def test_candidate_is_not_activated(self) -> None:
        recommendation = self.report["recommendation"]
        self.assertEqual(recommendation["decision"], "REVISE")
        self.assertFalse(recommendation["activation_allowed"])
        self.assertFalse(recommendation["acceptance_checks_all_passed"])


if __name__ == "__main__":
    unittest.main()
