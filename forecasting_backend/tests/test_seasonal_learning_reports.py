from __future__ import annotations

import tempfile
import unittest
import os
from pathlib import Path

from fastapi.testclient import TestClient

from app.api import create_app
from app.api.adapters import SyntheticDevelopmentAdapter
from app.api.research_reports import SeasonalLearningReportService
from app.api.settings import ApiSettings


BACKEND_ROOT = Path(__file__).resolve().parents[1]
REPORT_ROOT = BACKEND_ROOT / "simulation_reports"
LIVE_HISTORY = BACKEND_ROOT.parent / "database" / "stage26_live_history.csv"
TOKEN = "stage28-report-token"


def settings() -> ApiSettings:
    return ApiSettings(
        mode="synthetic",
        supabase_url=None,
        supabase_publishable_key=None,
        request_timeout_seconds=1,
        review_period_days=7,
        policy_version="stage28-test",
        synthetic_session_token=TOKEN,
        deployment_environment="test",
        synthetic_mode_enabled=True,
    )


class SeasonalLearningReportServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.service = SeasonalLearningReportService(
            report_root=REPORT_ROOT,
            live_history_path=LIVE_HISTORY,
        )
        cls.report = cls.service.load()

    def test_reported_metrics_are_not_recalculated_or_invented(self) -> None:
        self.assertTrue(self.report["available"])
        metrics = self.report["stage26"]["metrics"]
        seasonal_28 = next(
            value
            for value in metrics
            if value["horizon_days"] == 28
            and value["model"] == "product_specific_seasonal_lightgbm"
        )
        self.assertAlmostEqual(seasonal_28["wape"], 0.31634823421029573)
        refined = self.report["stage27b"]["final_comparison"]["refined"]
        self.assertEqual(
            refined["classification_metrics"]["accuracy"], 0.875
        )
        self.assertEqual(
            refined["classification_metrics"]["covered_accuracy"], 1.0
        )

    def test_product_mapping_preserves_unknown_and_simulation_labels(self) -> None:
        products = self.report["products"]
        self.assertEqual(len(products), 24)
        self.assertTrue(all(value["is_simulation"] for value in products))
        unknown = {
            value["sku"]
            for value in products
            if value["refined_discovered"] == "UNKNOWN"
        }
        self.assertEqual(
            unknown,
            {"SIM-RAIN-003", "SIM-NEU-002", "SIM-NEU-008"},
        )

    def test_forecast_actual_points_are_strictly_after_the_origin(self) -> None:
        product_id = self.report["products"][0]["product_id"]
        selected = self.service.load(product_id=product_id)
        points = selected["forecast_vs_actual"]["points"]
        self.assertTrue(points)
        self.assertEqual(
            selected["forecast_vs_actual"]["leakage_check"], "PASS"
        )
        self.assertTrue(
            all(value["forecast_date"] > value["origin"] for value in points)
        )
        self.assertEqual(
            {value["model"] for value in points},
            {
                "mean28",
                "existing_lightgbm",
                "matched_nonseasonal_ablation",
                "product_specific_seasonal_lightgbm",
            },
        )

    def test_missing_reports_return_safe_unavailable_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = SeasonalLearningReportService(
                report_root=Path(directory),
                live_history_path=Path(directory) / "missing.csv",
            ).load()
        self.assertFalse(missing["available"])
        self.assertFalse(missing["complete"])
        self.assertTrue(missing["warnings"])
        self.assertEqual(missing["products"], [])

    def test_current_stage26_artifact_records_live_verification(self) -> None:
        stage26 = next(
            value
            for value in self.report["artifacts"]
            if value["stage"] == "Stage 2.6"
        )
        self.assertEqual(stage26["status"], "available")
        self.assertEqual(
            self.report["stage26"]["database_verification"], "PASS"
        )
        self.assertTrue(self.report["complete"])

    def test_stale_report_is_explicitly_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "reports"
            report = root / "stage26" / "stage26_historical_accuracy.json"
            report.parent.mkdir(parents=True)
            report.write_text("{}", encoding="utf-8")
            live = Path(directory) / "live.csv"
            live.write_text("placeholder", encoding="utf-8")
            os.utime(report, (1, 1))
            os.utime(live, (2, 2))
            payload = SeasonalLearningReportService(
                report_root=root,
                live_history_path=live,
            ).load()
        stage26 = next(
            value
            for value in payload["artifacts"]
            if value["stage"] == "Stage 2.6"
        )
        self.assertEqual(stage26["status"], "stale")
        self.assertFalse(payload["complete"])
        self.assertTrue(any("older" in value for value in payload["warnings"]))


class SeasonalLearningReportApiTests(unittest.TestCase):
    def setUp(self) -> None:
        configured = settings()
        self.client = TestClient(
            create_app(
                adapter=SyntheticDevelopmentAdapter(configured),
                settings=configured,
                research_report_service=SeasonalLearningReportService(
                    report_root=REPORT_ROOT,
                    live_history_path=LIVE_HISTORY,
                ),
            )
        )

    def test_endpoint_is_authenticated_and_read_only(self) -> None:
        unauthenticated = self.client.get(
            "/v1/forecasting/research/seasonal-learning"
        )
        self.assertEqual(unauthenticated.status_code, 401)

        response = self.client.get(
            "/v1/forecasting/research/seasonal-learning",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["read_only"])
        self.assertEqual(body["schema_version"], "seasonal-learning-lab-v1")
        self.assertNotIn("purchase_order", body)


if __name__ == "__main__":
    unittest.main()
