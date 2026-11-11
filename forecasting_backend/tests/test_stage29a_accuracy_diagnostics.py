from __future__ import annotations

import json
import math
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

from app.simulation.stage29a_accuracy_diagnostics import (
    CANDIDATE,
    MODELS,
    ForecastPoint,
    _horizon_total_rows,
    _overall_rows,
    build_diagnostics,
    load_json,
    load_points,
    sha256,
)


ROOT = Path(__file__).resolve().parents[1]
STAGE26_DIR = ROOT / "simulation_reports" / "stage26"
POINTS = STAGE26_DIR / "historical_forecast_vs_actual.csv"
REPORT = STAGE26_DIR / "stage26_historical_accuracy.json"
ASSUMPTIONS = ROOT / "app" / "simulation" / "expanded_seasonal_assumptions.json"


class Stage29AAccuracyDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.points_hash = sha256(POINTS)
        cls.report_hash = sha256(REPORT)
        cls.assumptions_hash = sha256(ASSUMPTIONS)
        cls.points = load_points(POINTS)
        cls.diagnostics = build_diagnostics(
            points=cls.points,
            stage26=load_json(REPORT),
            assumptions=load_json(ASSUMPTIONS),
            points_sha256=cls.points_hash,
            stage26_sha256=cls.report_hash,
            assumptions_sha256=cls.assumptions_hash,
        )

    def test_reproduces_frozen_stage26_baselines_exactly(self) -> None:
        baseline = self.diagnostics["published_baseline_reproduction"]
        self.assertEqual(baseline["status"], "PASS")
        self.assertAlmostEqual(
            baseline["daily_28_day_wape"][CANDIDATE],
            0.31634823421029573,
            places=12,
        )
        self.assertAlmostEqual(
            baseline["daily_28_day_wape"]["matched_nonseasonal_ablation"],
            0.31748526200612553,
            places=12,
        )

    def test_inputs_remain_byte_identical_after_diagnostics(self) -> None:
        self.assertEqual(sha256(POINTS), self.points_hash)
        self.assertEqual(sha256(REPORT), self.report_hash)
        self.assertEqual(sha256(ASSUMPTIONS), self.assumptions_hash)

    def test_all_targets_are_strictly_after_origin(self) -> None:
        self.assertTrue(
            all(point.forecast_date > point.origin for point in self.points)
        )
        self.assertEqual(
            self.diagnostics["source_integrity"]["future_data_leakage_check"],
            "PASS",
        )

    def test_product_ranking_covers_all_simulation_products(self) -> None:
        products = self.diagnostics["ranked_product_error_contributors"]
        self.assertEqual(len(products), 24)
        self.assertEqual({value["rank"] for value in products}, set(range(1, 25)))
        self.assertTrue(
            all(
                products[index]["absolute_error_total"]
                >= products[index + 1]["absolute_error_total"]
                for index in range(len(products) - 1)
            )
        )
        for unit in {value["unit"] for value in products}:
            unit_rows = [value for value in products if value["unit"] == unit]
            self.assertEqual(
                {value["unit_rank"] for value in unit_rows},
                set(range(1, len(unit_rows) + 1)),
            )

    def test_horizon_total_metric_is_distinct_from_daily_wape(self) -> None:
        summary = self.diagnostics["diagnostic_summary"]
        self.assertFalse(
            math.isclose(
                summary["daily_28_day_wape"],
                summary["quantity_total_28_day_wape"],
                abs_tol=1e-12,
            )
        )

    def test_no_sales_control_has_no_false_positive_forecast(self) -> None:
        products = self.diagnostics["ranked_product_error_contributors"]
        control = next(value for value in products if value["demand_pattern"] == "no_sales")
        self.assertEqual(control["actual_total"], 0)
        self.assertEqual(control["predicted_total"], 0)
        self.assertEqual(control["absolute_error_total"], 0)

    def test_loader_rejects_future_target_leakage(self) -> None:
        header = (
            "horizon_days,origin,forecast_date,requested_model,product_id,sku,"
            "product_name,unit,seasonal_group,demand_pattern,season,transition,"
            "actual,predicted\n"
        )
        row = "7,2026-01-01,2026-01-01,mean28,p1,S1,Item,pcs,NEUTRAL,neutral,dry,none,1,1\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "leak.csv"
            path.write_text(header + row, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not after its origin"):
                load_points(path)

    def test_all_improvement_proposals_preserve_final_holdout(self) -> None:
        proposals = self.diagnostics["targeted_improvements"]
        self.assertLessEqual(len(proposals), 3)
        self.assertTrue(
            all(
                "validation" in value["evaluation"].lower()
                and "new" in value["evaluation"].lower()
                and "holdout" in value["evaluation"].lower()
                for value in proposals
            )
        )
        holdout = self.diagnostics["holdout_policy"]
        self.assertEqual(holdout["stage26_final_use"], "diagnosis_only")
        self.assertFalse(holdout["selection_allowed"])


class Stage29ASyntheticMetricTests(unittest.TestCase):
    def test_quantity_total_error_allows_only_within_horizon_cancellation(self) -> None:
        # This focused fixture proves the diagnostic distinction without using
        # labels, names or hidden generator variables as model inputs.
        origin = date(2026, 1, 1)
        points = []
        for model in MODELS:
            for horizon in (7, 28):
                for offset in range(1, horizon + 1):
                    actual = 2.0
                    predicted = 3.0 if offset % 2 else 1.0
                    points.append(
                        ForecastPoint(
                            horizon_days=horizon,
                            origin=origin,
                            forecast_date=origin + timedelta(days=offset),
                            model=model,
                            product_id="p1",
                            sku="S1",
                            product_name="Item",
                            unit="pcs",
                            seasonal_group="NEUTRAL",
                            demand_pattern="neutral",
                            season="dry",
                            transition="none",
                            actual=actual,
                            predicted=predicted,
                        )
                    )
        daily = {
            (value["horizon_days"], value["model"]): value
            for value in _overall_rows(points)
        }
        totals = {
            (value["horizon_days"], value["model"]): value
            for value in _horizon_total_rows(points)
        }
        self.assertEqual(daily[(28, CANDIDATE)]["wape"], 0.5)
        self.assertEqual(totals[(28, CANDIDATE)]["quantity_total_wape"], 0)
        self.assertGreater(
            daily[(7, CANDIDATE)]["wape"],
            totals[(7, CANDIDATE)]["quantity_total_wape"],
        )


if __name__ == "__main__":
    unittest.main()
