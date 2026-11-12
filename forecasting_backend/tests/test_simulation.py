from __future__ import annotations

import unittest
from datetime import date
from decimal import Decimal

from app.forecasting import ColdStartReason, Mean28Forecaster
from app.simulation.datasets import historical_dataset
from app.simulation.evaluation import ForecastEvaluator, calculate_metrics
from app.simulation.events import settle_inventory_day, supplier_delivery_date
from app.simulation.generator import SyntheticHardwareStoreGenerator
from app.simulation.inventory import InventoryPolicySimulator
from app.simulation.models import SimulationConfig


class SyntheticGenerationTests(unittest.TestCase):
    def test_generator_honors_configured_policy_ranges(self) -> None:
        config = SimulationConfig(
            start_date=date(2025, 1, 1),
            days=40,
            product_count=3,
            location_count=1,
            seed=5,
            evaluation_days=10,
            evaluation_origins=1,
            slow_daily_demand_range=(Decimal("1"), Decimal("1")),
            medium_daily_demand_range=(Decimal("2"), Decimal("2")),
            fast_daily_demand_range=(Decimal("3"), Decimal("3")),
            slow_frequency_range=(Decimal("1"), Decimal("1")),
            medium_frequency_range=(Decimal("1"), Decimal("1")),
            fast_frequency_range=(Decimal("1"), Decimal("1")),
            demand_variability_range=(Decimal("0"), Decimal("0")),
            weekly_seasonality_range=(Decimal("0"), Decimal("0")),
            annual_seasonality_range=(Decimal("0"), Decimal("0")),
            new_product_probability=Decimal("1"),
            new_product_launch_offset_range=(5, 5),
            supplier_lead_time_range=(4, 4),
            pack_size_options=(5,),
            moq_pack_multiple_options=(2,),
            opening_stock_coverage_days=6,
            capacity_coverage_days=20,
            minimum_safety_stock_days=3,
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        self.assertEqual(
            [policy.base_daily_demand for policy in scenario.policies],
            [Decimal("1.000000"), Decimal("2.000000"), Decimal("3.000000")],
        )
        self.assertTrue(
            all(policy.launch_date == date(2025, 1, 6) for policy in scenario.policies)
        )
        self.assertTrue(all(policy.lead_time_days == 4 for policy in scenario.policies))
        self.assertTrue(all(policy.pack_size == 5 for policy in scenario.policies))
        self.assertTrue(
            all(policy.minimum_order_quantity == 10 for policy in scenario.policies)
        )

    def test_identical_seed_is_exactly_reproducible(self) -> None:
        config = SimulationConfig(
            start_date=date(2025, 1, 1),
            days=90,
            product_count=4,
            location_count=2,
            seed=17,
            evaluation_days=30,
            evaluation_origins=1,
        )
        generator = SyntheticHardwareStoreGenerator()
        self.assertEqual(generator.generate(config), generator.generate(config))
        self.assertNotEqual(
            generator.generate(config),
            generator.generate(
                SimulationConfig(
                    start_date=config.start_date,
                    days=config.days,
                    product_count=config.product_count,
                    location_count=config.location_count,
                    seed=18,
                    evaluation_days=30,
                    evaluation_origins=1,
                )
            ),
        )

    def test_latent_demand_sales_and_stockout_identity(self) -> None:
        scenario = SyntheticHardwareStoreGenerator().generate(
            SimulationConfig(
                start_date=date(2025, 1, 1),
                days=120,
                product_count=3,
                location_count=1,
                seed=91,
                evaluation_days=30,
                evaluation_origins=1,
            )
        )
        launched = [
            day
            for day in scenario.days
            if day.business_date
            >= next(policy.launch_date for policy in scenario.policies if policy.key == day.key)
        ]
        self.assertTrue(launched)
        for day in launched:
            self.assertLessEqual(day.fulfilled_sales, day.underlying_net_demand)
            self.assertEqual(
                day.unmet_demand,
                day.underlying_net_demand - day.fulfilled_sales,
            )
            self.assertEqual(day.stockout, day.unmet_demand > 0)
            self.assertEqual(
                day.customer_demand,
                day.underlying_net_demand + day.cancelled_units,
            )

    def test_history_boundary_excludes_future_days_and_marks_stockouts(self) -> None:
        scenario = SyntheticHardwareStoreGenerator().generate(
            SimulationConfig(
                start_date=date(2025, 1, 1),
                days=100,
                product_count=1,
                location_count=1,
                seed=4,
                evaluation_days=30,
                evaluation_origins=1,
            )
        )
        policy = scenario.policies[0]
        cutoff = policy.launch_date
        dataset = historical_dataset(scenario, policy, history_end=cutoff)
        self.assertTrue(
            all(value.business_date <= cutoff for value in dataset.observations)
        )
        self.assertTrue(
            all(
                value.business_date <= cutoff
                for value in dataset.availability_evidence
            )
        )
        result = Mean28Forecaster().forecast(dataset, horizon_days=1)[0]
        self.assertEqual(
            result.metadata.cold_start_reason,
            ColdStartReason.INSUFFICIENT_HISTORY,
        )
        self.assertGreater(result.forecast_date, cutoff)

        explicitly_empty = historical_dataset(
            scenario,
            policy,
            history_end=cutoff,
            observed_days=(),
        )
        self.assertEqual(explicitly_empty.observations, ())
        self.assertEqual(explicitly_empty.availability_evidence, ())


class InventoryEventTests(unittest.TestCase):
    def test_exact_depletion_stockout_and_backorder_settlement(self) -> None:
        result = settle_inventory_day(
            on_hand=Decimal("5"),
            backorders=Decimal("2"),
            delivery=Decimal("3"),
            returns=Decimal("1"),
            underlying_demand=Decimal("10"),
            capacity=Decimal("20"),
            backorder_fraction=Decimal("0.5"),
        )
        self.assertEqual(result.late_backorders_fulfilled, Decimal("2"))
        self.assertEqual(result.immediate_fulfilled, Decimal("7"))
        self.assertEqual(result.unmet_demand, Decimal("3"))
        self.assertEqual(result.backorders_added, Decimal("2"))
        self.assertEqual(result.backorders_end, Decimal("2"))
        self.assertEqual(result.on_hand_end, Decimal("0"))
        self.assertTrue(result.stockout)

    def test_supplier_delivery_timing_is_lead_plus_delay(self) -> None:
        self.assertEqual(
            supplier_delivery_date(
                date(2026, 1, 10), lead_time_days=5, delay_days=3
            ),
            date(2026, 1, 18),
        )

    def test_policy_and_baseline_share_exact_demand_scenario(self) -> None:
        config = SimulationConfig(
            start_date=date(2025, 1, 1),
            days=140,
            product_count=2,
            location_count=1,
            seed=33,
            evaluation_days=60,
            evaluation_origins=1,
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        outcomes = InventoryPolicySimulator(config).compare(scenario)
        self.assertEqual(len(outcomes), 2)
        self.assertEqual(
            outcomes[0].underlying_demand_units,
            outcomes[1].underlying_demand_units,
        )
        self.assertTrue(all(value.orders_placed >= 0 for value in outcomes))
        self.assertTrue(
            all(value.immediately_fulfilled_units <= value.underlying_demand_units for value in outcomes)
        )


class ForecastEvaluationTests(unittest.TestCase):
    def test_metrics_have_known_daily_answer(self) -> None:
        result = calculate_metrics(
            [Decimal("10"), Decimal("0")],
            [Decimal("8"), Decimal("2")],
        )
        self.assertEqual(result.observations, 2)
        self.assertEqual(result.wape, Decimal("0.4"))
        self.assertEqual(result.signed_bias, Decimal("0"))
        self.assertEqual(result.mae, Decimal("2"))

    def test_small_evaluation_is_chronological_and_reports_all_models(self) -> None:
        config = SimulationConfig(
            start_date=date(2024, 1, 1),
            days=180,
            product_count=2,
            location_count=1,
            seed=121,
            evaluation_days=60,
            evaluation_origins=1,
        )
        scenario = SyntheticHardwareStoreGenerator().generate(config)
        reports = ForecastEvaluator(config).evaluate(scenario)
        self.assertEqual(
            [value.requested_model for value in reports],
            ["mean28", "lightgbm", "calibrated_blend"],
        )
        self.assertTrue(all(value.forecast_points == 56 for value in reports))
        self.assertTrue(all(value.daily.observations == 56 for value in reports))


if __name__ == "__main__":
    unittest.main()
