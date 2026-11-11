from __future__ import annotations

import unittest
from datetime import date
from decimal import Decimal

from app.simulation.generator import SyntheticHardwareStoreGenerator
from app.simulation.models import SimulationConfig
from app.simulation.policy_comparison import ExtendedInventoryPolicySimulator
from app.simulation.robustness import RobustForecastEvaluator


class RobustForecastEvaluatorTests(unittest.TestCase):
    def test_launch_relative_origins_exercise_manual_and_statistical_eligibility(
        self,
    ) -> None:
        config = SimulationConfig(
            start_date=date(2025, 1, 1),
            days=300,
            product_count=1,
            location_count=1,
            seed=601,
            evaluation_days=150,
            evaluation_origins=1,
            new_product_probability=Decimal("1"),
            new_product_launch_offset_range=(180, 180),
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        result = RobustForecastEvaluator(
            config, include_launch_origins=True
        ).evaluate(scenario)
        by_kind = {value.origin_kind: value for value in result.eligibility}

        no_history = by_kind["launch_relative_-1"]
        self.assertEqual(no_history.cold_start_reason, "no_history")
        self.assertEqual(no_history.routed_model, "manual_estimate_fallback")

        insufficient = by_kind["launch_relative_+6"]
        self.assertEqual(
            insufficient.cold_start_reason, "insufficient_history"
        )
        self.assertEqual(insufficient.routed_model, "manual_estimate_fallback")

        statistically_usable = by_kind["launch_relative_+27"]
        self.assertIsNone(statistically_usable.cold_start_reason)
        self.assertEqual(statistically_usable.routed_model, "mean28")

        ml_review = by_kind["launch_relative_+83"]
        self.assertEqual(ml_review.lightgbm_model, "lightgbm")
        self.assertEqual(ml_review.routed_model, "lightgbm")

    def test_intermittent_guardrail_is_separate_from_reference_lightgbm(self) -> None:
        config = SimulationConfig(
            start_date=date(2024, 1, 1),
            days=180,
            product_count=1,
            location_count=1,
            seed=602,
            evaluation_days=60,
            evaluation_origins=1,
            slow_frequency_range=(Decimal("0.20"), Decimal("0.20")),
            new_product_probability=Decimal("0"),
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        result = RobustForecastEvaluator(config).evaluate(scenario)
        reports = {value.requested_model: value for value in result.reports}

        self.assertEqual(reports["lightgbm"].actual_models, {"lightgbm": 1})
        self.assertEqual(
            reports["intermittent_guardrail"].actual_models,
            {"intermittent_guardrail_mean28": 1},
        )
        self.assertIn("intermittent", reports["lightgbm"].by_segment)


class ExtendedInventoryPolicyTests(unittest.TestCase):
    def test_four_policies_share_demand_and_report_category_costs(self) -> None:
        config = SimulationConfig(
            start_date=date(2024, 1, 1),
            days=180,
            product_count=3,
            location_count=1,
            seed=603,
            evaluation_days=35,
            evaluation_origins=1,
            new_product_probability=Decimal("0"),
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        outcomes = ExtendedInventoryPolicySimulator(config).compare(scenario)

        self.assertEqual(
            [value.strategy for value in outcomes],
            [
                "baseline_moving_average_order_up_to",
                "stage5c_mean28",
                "stage5c_lightgbm",
                "stage5c_calibrated_blend",
            ],
        )
        demand = {value.overall.underlying_demand_units for value in outcomes}
        self.assertEqual(len(demand), 1)
        for value in outcomes:
            self.assertEqual(set(value.by_category), {"slow", "medium", "fast"})
            self.assertEqual(
                value.overall.total_assumed_cost,
                value.overall.holding_cost + value.overall.ordering_cost,
            )
            self.assertTrue(value.actual_forecast_models)

    def test_late_launch_receives_opening_stock_in_each_policy(self) -> None:
        config = SimulationConfig(
            start_date=date(2025, 1, 1),
            days=90,
            product_count=1,
            location_count=1,
            seed=604,
            evaluation_days=60,
            evaluation_origins=1,
            new_product_probability=Decimal("1"),
            new_product_launch_offset_range=(45, 45),
            opening_stock_coverage_days=30,
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        outcomes = ExtendedInventoryPolicySimulator(config).compare(
            scenario,
            strategies=("baseline_moving_average_order_up_to", "stage5c_mean28"),
        )
        self.assertTrue(
            all(value.overall.immediately_fulfilled_units > 0 for value in outcomes)
        )
        self.assertEqual(
            outcomes[0].overall.underlying_demand_units,
            outcomes[1].overall.underlying_demand_units,
        )


if __name__ == "__main__":
    unittest.main()
