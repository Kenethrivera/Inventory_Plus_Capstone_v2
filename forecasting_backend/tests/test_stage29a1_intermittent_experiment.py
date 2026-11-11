from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

from app.simulation.expanded_seasonal_fixture import bounded_dataset
from app.simulation.stage29a1_intermittent_experiment import (
    TSBIntermittentBaseline,
    TwoStageConfig,
    TwoStageOccurrenceQuantityForecaster,
    generate_realization,
    load_manifest,
    sha256,
)


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "app" / "simulation" / "stage29a1_experiment_manifest.json"
OUTPUT = ROOT / "simulation_reports" / "stage29a1"


class Stage29A1UnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = load_manifest(MANIFEST)
        # A dedicated test seed ensures unit tests never access the frozen
        # independent-final realization before or after its one-time run.
        cls.realization = generate_realization(
            cls.manifest,
            name="unit_test_only",
            seed=29010000,
        )

    def test_manifest_freezes_independent_seeds_and_selection_rules(self) -> None:
        self.assertTrue(self.manifest["frozen_before_final_evaluation"])
        self.assertNotEqual(
            self.manifest["development_seed"],
            self.manifest["independent_final_seed"],
        )
        self.assertTrue(
            self.manifest["independent_final_access"]["evaluate_once"]
        )
        self.assertFalse(
            self.manifest["independent_final_access"]["stage26_period_reused"]
        )
        self.assertEqual(
            hashlib.sha256(
                MANIFEST.read_bytes().replace(b"\r\n", b"\n")
            ).hexdigest(),
            "bad9c1380d02e657ed228586eb03d092f7fe7f1c89c8e051e006b1b41ca8b4e5",
        )

    def test_generator_is_reproducible_for_a_nonfinal_test_seed(self) -> None:
        again = generate_realization(
            self.manifest,
            name="unit_test_only",
            seed=29010000,
        )
        self.assertEqual(self.realization.actual, again.actual)
        different = generate_realization(
            self.manifest,
            name="unit_test_other",
            seed=29010001,
        )
        self.assertNotEqual(self.realization.actual, different.actual)

    def test_two_stage_and_tsb_preserve_never_sold_zero(self) -> None:
        source = next(
            value
            for value in self.realization.datasets
            if value.product.sku == "SIM-NEU-008"
        )
        training = bounded_dataset(
            source,
            date(2023, 12, 31),
            max_history_days=int(self.manifest["maximum_history_days"]),
        )
        config_values = self.manifest["two_stage_hyperparameter_candidates"][
            "compact"
        ]
        candidate = TwoStageOccurrenceQuantityForecaster(
            config=TwoStageConfig(
                name="test",
                random_seed=29010000,
                **config_values,
            )
        )
        tsb_values = self.manifest["simple_intermittent_baseline"]
        tsb = TSBIntermittentBaseline(
            occurrence_smoothing=tsb_values["occurrence_smoothing"],
            quantity_smoothing=tsb_values["quantity_smoothing"],
        )
        self.assertEqual(candidate.forecast(training, horizon_days=28), [0.0] * 28)
        self.assertEqual(tsb.forecast(training, horizon_days=28), [0.0] * 28)

    def test_intermittent_classification_uses_only_pretest_history(self) -> None:
        statistics = self.realization.pretest_statistics
        sparse = next(
            value
            for value in statistics.values()
            if value["sku"] == "SIM-RAIN-007"
        )
        self.assertEqual(sparse["history_days"], 1095)
        self.assertEqual(
            sparse["demand_frequency"] + sparse["zero_sales_frequency"],
            1.0,
        )
        self.assertIn(sparse["demand_class"], {"intermittent_low", "intermittent"})

    def test_loader_rejects_reused_development_and_final_seed(self) -> None:
        changed = dict(self.manifest)
        changed["independent_final_seed"] = changed["development_seed"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "must be independent"):
                load_manifest(path)


class Stage29A1OutputContractTests(unittest.TestCase):
    def test_one_time_output_records_frozen_selection_before_final(self) -> None:
        report_path = OUTPUT / "stage29a1_intermittent_experiment.json"
        if not report_path.exists():
            self.skipTest("run the Stage 2.9A-1 experiment first")
        report = json.loads(report_path.read_text(encoding="utf-8"))
        contract = report["evaluation_contract"]
        self.assertTrue(contract["selection_written_before_final_generation"])
        self.assertFalse(contract["stage26_period_reused"])
        self.assertEqual(contract["future_sales_leakage_check"], "PASS")
        selection = report["frozen_development_selection"]
        self.assertFalse(selection["selection_used_final_data"])
        self.assertFalse(selection["final_data_accessed"])

    def test_output_contains_all_required_model_and_group_comparisons(self) -> None:
        report_path = OUTPUT / "stage29a1_intermittent_experiment.json"
        if not report_path.exists():
            self.skipTest("run the Stage 2.9A-1 experiment first")
        report = json.loads(report_path.read_text(encoding="utf-8"))
        metrics = report["independent_final_assessment"]["metrics"]
        models = set(metrics["overall"])
        self.assertTrue(
            {
                "mean28",
                "existing_lightgbm",
                "seasonal_lightgbm",
                "tsb_intermittent_baseline",
                "development_selected_product_policy",
            }.issubset(models)
        )
        self.assertEqual(len(report["independent_final_product_comparison"]), 24)
        self.assertIn("intermittent_low", metrics["by_demand_class"]["seasonal_lightgbm"])
        self.assertEqual(
            set(report["independent_final_assessment"]["seasonal_group_nonregression_checks"]),
            {"SUMMER", "RAINY", "NEUTRAL"},
        )


if __name__ == "__main__":
    unittest.main()
