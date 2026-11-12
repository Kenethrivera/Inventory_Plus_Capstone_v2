from __future__ import annotations

import math
import unittest
from dataclasses import replace
from datetime import date, timedelta

from app.simulation.sales_seasonality_discovery import (
    LearnedSeasonality,
    SalesSeasonalityDiscoverer,
)
from app.simulation.seasonality_refinement import (
    RefinementPolicy,
    apply_refinement,
)


class SeasonalityRefinementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.learner = SalesSeasonalityDiscoverer()
        cls.dates = [
            date(2022, 1, 1) + timedelta(days=index)
            for index in range(1095)
        ]
        cls.summer_values = [
            10.0
            + 5.0
            * math.cos(
                2.0
                * math.pi
                * (business_date.timetuple().tm_yday - 100)
                / 365.25
            )
            for business_date in cls.dates
        ]
        cls.strong_summer = cls.learner.discover(
            cls.dates,
            cls.summer_values,
            cutoff=cls.dates[-1],
        )

    def test_original_assignment_is_never_revoked(self) -> None:
        self.assertEqual(
            self.strong_summer.classification,
            LearnedSeasonality.SUMMER,
        )
        for policy in RefinementPolicy:
            refined = apply_refinement(self.strong_summer, policy)
            self.assertEqual(refined.classification, LearnedSeasonality.SUMMER)
            self.assertIn("preserved_original", refined.reason)

    def test_combined_policy_can_promote_only_redundant_gate_abstention(self) -> None:
        abstention = replace(
            self.strong_summer,
            classification=LearnedSeasonality.UNKNOWN,
            evidence_strength="inconclusive",
            reason="evidence_gates_not_jointly_satisfied",
            cycle_directions=("INCONCLUSIVE",) * 3,
        )
        combined = apply_refinement(
            abstention, RefinementPolicy.NONREDUNDANT_COMBINED
        )
        cycle_required = apply_refinement(
            abstention, RefinementPolicy.DROP_BOOTSTRAP_SIGNIFICANCE
        )
        self.assertEqual(combined.classification, LearnedSeasonality.SUMMER)
        self.assertEqual(
            cycle_required.classification, LearnedSeasonality.UNKNOWN
        )

    def test_reversal_remains_unknown_under_every_policy(self) -> None:
        reversal = replace(
            self.strong_summer,
            classification=LearnedSeasonality.UNKNOWN,
            evidence_strength="conflicting",
            cycle_directions=("SUMMER", "RAINY", "SUMMER"),
        )
        for policy in RefinementPolicy:
            refined = apply_refinement(reversal, policy)
            self.assertEqual(refined.classification, LearnedSeasonality.UNKNOWN)
            self.assertIn("reversal", refined.reason)

    def test_no_sales_remains_unknown_under_every_policy(self) -> None:
        no_sales = self.learner.discover(
            self.dates,
            [0.0] * len(self.dates),
            cutoff=self.dates[-1],
        )
        for policy in RefinementPolicy:
            refined = apply_refinement(no_sales, policy)
            self.assertEqual(refined.classification, LearnedSeasonality.UNKNOWN)
            self.assertEqual(refined.reason, "no_sales_history")

    def test_simple_baseline_can_confuse_monotonic_trend_for_seasonality(self) -> None:
        dates = [
            date(2022, 1, 1) + timedelta(days=index)
            for index in range(730)
        ]
        quantities = [1.0 + 0.01 * index for index in range(len(dates))]
        original = self.learner.discover(
            dates, quantities, cutoff=dates[-1]
        )
        baseline = self.learner.simple_baseline(
            dates, quantities, cutoff=dates[-1]
        )
        self.assertEqual(baseline.classification, LearnedSeasonality.RAINY)
        self.assertLess(baseline.p_value, 0.05)
        self.assertEqual(original.classification, LearnedSeasonality.UNKNOWN)
        for policy in RefinementPolicy:
            self.assertEqual(
                apply_refinement(original, policy).classification,
                LearnedSeasonality.UNKNOWN,
            )


if __name__ == "__main__":
    unittest.main()
