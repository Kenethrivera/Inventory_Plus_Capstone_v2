from __future__ import annotations

import csv
import json
import math
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any


class SeasonalLearningReportService:
    """Read immutable Stage 2.6-2.7B artifacts for the demonstration UI."""

    SCHEMA_VERSION = "seasonal-learning-lab-v1"

    def __init__(
        self,
        *,
        report_root: Path | None = None,
        live_history_path: Path | None = None,
    ) -> None:
        backend_root = Path(__file__).resolve().parents[2]
        self._root = report_root or backend_root / "simulation_reports"
        self._live_history = live_history_path or (
            backend_root.parent / "database" / "stage26_live_history.csv"
        )
        self._lock = Lock()
        self._cache_signature: tuple[tuple[str, int, int], ...] | None = None
        self._cache: dict[str, Any] | None = None
        self._series_by_product: dict[str, list[dict[str, object]]] = {}

    def load(self, *, product_id: str | None = None) -> dict[str, object]:
        with self._lock:
            signature = self._signature()
            if self._cache is None or signature != self._cache_signature:
                self._cache, self._series_by_product = self._load_all()
                self._cache_signature = signature
            response = deepcopy(self._cache)
            products = response.get("products", [])
            known_ids = {
                str(value.get("product_id"))
                for value in products
                if isinstance(value, dict)
            }
            selected = product_id if product_id in known_ids else None
            if selected is None and products:
                selected = str(products[0]["product_id"])
                if product_id:
                    response["warnings"].append(
                        "The requested product is not part of the 24-product "
                        "synthetic research catalog. The first simulation "
                        "product is shown instead."
                    )
            response["selected_product_id"] = selected
            response["forecast_vs_actual"] = {
                "product_id": selected,
                "points": deepcopy(
                    self._series_by_product.get(selected or "", [])
                ),
                "leakage_check": "PASS"
                if selected and self._series_by_product.get(selected)
                else "NOT_AVAILABLE",
            }
            return response

    def _paths(self) -> dict[str, Path]:
        return {
            "stage26_json": self._root
            / "stage26"
            / "stage26_historical_accuracy.json",
            "stage26_points": self._root
            / "stage26"
            / "historical_forecast_vs_actual.csv",
            "stage27_json": self._root
            / "stage27"
            / "stage27_sales_seasonality.json",
            "stage27b_json": self._root
            / "stage27b"
            / "stage27b_seasonality_refinement.json",
            "stage27b_products": self._root
            / "stage27b"
            / "refined_classifications.csv",
            "stage27b_chronology": self._root
            / "stage27b"
            / "chronological_comparison.csv",
        }

    def _signature(self) -> tuple[tuple[str, int, int], ...]:
        paths = {**self._paths(), "live_history": self._live_history}
        result = []
        for name, path in sorted(paths.items()):
            try:
                stat = path.stat()
                result.append((name, stat.st_mtime_ns, stat.st_size))
            except OSError:
                result.append((name, -1, -1))
        return tuple(result)

    def _load_all(
        self,
    ) -> tuple[dict[str, Any], dict[str, list[dict[str, object]]]]:
        paths = self._paths()
        warnings: list[str] = []
        artifacts: list[dict[str, object]] = []
        stage26 = self._read_json(
            "Stage 2.6", paths["stage26_json"], warnings, artifacts
        )
        stage27 = self._read_json(
            "Stage 2.7", paths["stage27_json"], warnings, artifacts
        )
        stage27b = self._read_json(
            "Stage 2.7B", paths["stage27b_json"], warnings, artifacts
        )
        products = self._read_products(paths["stage27b_products"], warnings)
        chronology = self._read_chronology(
            paths["stage27b_chronology"], warnings
        )
        series = self._read_latest_forecast_series(
            paths["stage26_points"], warnings
        )

        stage26_payload = self._stage26_payload(stage26, warnings)
        stage27_payload = self._stage27_payload(stage27, warnings)
        stage27b_payload = self._stage27b_payload(
            stage27b, chronology, warnings
        )
        required_present = (
            all(value is not None for value in (stage26, stage27, stage27b))
            and bool(products)
            and bool(chronology)
            and bool(series)
        )
        required_artifacts_current = all(
            value.get("status") == "available" for value in artifacts
        )
        response = {
            "schema_version": self.SCHEMA_VERSION,
            "read_only": True,
            "available": any(
                value is not None for value in (stage26, stage27, stage27b)
            ),
            "complete": required_present
            and required_artifacts_current
            and stage26_payload.get("database_verification") == "PASS",
            "warnings": warnings,
            "artifacts": artifacts,
            "stage26": stage26_payload,
            "stage27": stage27_payload,
            "stage27b": stage27b_payload,
            "products": products,
            "provenance_guide": {
                "live_forecast": (
                    "The operational forecast above is calculated now through "
                    "the authenticated Supabase-backed API."
                ),
                "knowledge_based_classification": (
                    "The seasonal context shown with a live experimental "
                    "forecast comes from the versioned hardware knowledge base."
                ),
                "frozen_simulation_label": (
                    "SUMMER, RAINY and NEUTRAL labels in this laboratory are "
                    "frozen synthetic hypotheses, not validated retail facts."
                ),
                "sales_discovered_classification": (
                    "Original, refined and baseline labels were produced "
                    "offline from historical synthetic sales. They are not "
                    "written back to inventory."
                ),
                "historical_error": (
                    "Forecast-versus-actual points are frozen historical "
                    "evaluations whose target dates occur after each origin."
                ),
            },
        }
        if not response["available"]:
            warnings.append(
                "Seasonal learning reports are unavailable. Operational "
                "forecasting remains available."
            )
        if not response["complete"]:
            warnings.append(
                "The research bundle is incomplete or not fully verified; "
                "treat displayed results as provisional."
            )
        return response, series

    def _read_json(
        self,
        stage: str,
        path: Path,
        warnings: list[str],
        artifacts: list[dict[str, object]],
    ) -> dict[str, Any] | None:
        status = "available"
        stale = self._is_stale(path)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                raise ValueError("report root must be an object")
        except FileNotFoundError:
            status = "missing"
            value = None
            warnings.append(f"{stage} report artifact is missing.")
        except (OSError, ValueError, json.JSONDecodeError):
            status = "incomplete"
            value = None
            warnings.append(f"{stage} report artifact could not be loaded.")
        if stale and status == "available":
            status = "stale"
            warnings.append(
                f"{stage} report is older than the verified history export."
            )
        artifacts.append(
            {
                "stage": stage,
                "status": status,
                "stale": stale,
                "path": path.name,
                "modified_at": self._modified_at(path),
            }
        )
        return value

    def _is_stale(self, path: Path) -> bool:
        try:
            return path.stat().st_mtime_ns < self._live_history.stat().st_mtime_ns
        except OSError:
            return False

    @staticmethod
    def _modified_at(path: Path) -> str | None:
        try:
            return datetime.fromtimestamp(
                path.stat().st_mtime, tz=timezone.utc
            ).isoformat()
        except OSError:
            return None

    def _stage26_payload(
        self, report: dict[str, Any] | None, warnings: list[str]
    ) -> dict[str, object]:
        if report is None:
            return {"available": False}
        try:
            metrics = []
            for horizon, values in report["metrics"].items():
                for model, result in values[
                    "overall_mixed_unit_diagnostic"
                ].items():
                    metrics.append(
                        {
                            "horizon_days": int(horizon),
                            "model": model,
                            "mae": self._finite(result["mae"]),
                            "wape": self._finite(result["wape"]),
                            "bias": self._finite(result["signed_bias"]),
                            "actual_total": self._finite(
                                result["actual_total"]
                            ),
                            "predicted_total": self._finite(
                                result["predicted_total"]
                            ),
                        }
                    )
            replay = report["historical_replay"]
            rows = [
                {
                    "sku": row["sku"],
                    "product_name": row["product_name"],
                    "seasonal_group": row["seasonal_group"],
                    "period": int(row["period"]),
                    "origin": row["origin"],
                    "forecast_total": self._finite(row["forecast_total"]),
                    "actual_total": self._finite(row["actual_total"]),
                    "signed_error": self._finite(
                        row["signed_error_predicted_minus_actual"]
                    ),
                    "absolute_error": self._finite(row["absolute_error"]),
                }
                for row in replay["rows"]
            ]
            verification = report.get("database_verification", {}).get(
                "status", "UNKNOWN"
            )
            if verification != "PASS":
                warnings.append(
                    "Stage 2.6 artifact does not record a completed live "
                    "database comparison. Metrics remain frozen-source results."
                )
            return {
                "available": True,
                "decision": report["decision"],
                "database_verification": verification,
                "history_start": report["frozen_dataset_verification"][
                    "history_start"
                ],
                "history_end": report["frozen_dataset_verification"][
                    "history_end"
                ],
                "metrics": metrics,
                "replay": {
                    "rows": rows,
                    "improved": replay[
                        "period_to_period_absolute_error_improved"
                    ],
                    "worsened": replay[
                        "period_to_period_absolute_error_worsened"
                    ],
                    "interpretation": replay["interpretation"],
                },
            }
        except (KeyError, TypeError, ValueError):
            warnings.append("Stage 2.6 report is incomplete.")
            return {"available": False}

    def _stage27_payload(
        self, report: dict[str, Any] | None, warnings: list[str]
    ) -> dict[str, object]:
        if report is None:
            return {"available": False}
        try:
            return {
                "available": True,
                "decision": report["decision"],
                "chronological_metrics": report["chronological_metrics"],
                "final_evaluation": report["final_36_month_evaluation"],
                "future_year_confirmation": {
                    key: value
                    for key, value in report[
                        "future_year_confirmation"
                    ].items()
                    if key != "rows"
                },
            }
        except (KeyError, TypeError):
            warnings.append("Stage 2.7 report is incomplete.")
            return {"available": False}

    def _stage27b_payload(
        self,
        report: dict[str, Any] | None,
        chronology: list[dict[str, object]],
        warnings: list[str],
    ) -> dict[str, object]:
        if report is None:
            return {"available": False}
        try:
            comparison = {}
            for model, value in report["final_comparison"].items():
                comparison[model] = {
                    "classification_metrics": value[
                        "classification_metrics"
                    ],
                    "fourth_year_confirmation": value[
                        "fourth_year_confirmation"
                    ],
                }
            return {
                "available": True,
                "decision": report["decision"],
                "selected_policy": report["selected_policy"],
                "genuinely_better_than_baseline": report[
                    "genuinely_better_than_simple_baseline"
                ],
                "final_comparison": comparison,
                "chronological_comparison": chronology,
                "conclusion": report["conclusion"],
            }
        except (KeyError, TypeError):
            warnings.append("Stage 2.7B report is incomplete.")
            return {"available": False}

    def _read_products(
        self, path: Path, warnings: list[str]
    ) -> list[dict[str, object]]:
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.DictReader(handle))
        except OSError:
            warnings.append("Product-level classification artifact is missing.")
            return []
        products = []
        for row in rows:
            try:
                sku = self._required(row, "sku")
                products.append(
                    {
                        "product_id": self._required(row, "product_id"),
                        "sku": sku,
                        "product_name": self._required(row, "product_name"),
                        "is_simulation": sku.startswith("SIM-"),
                        "frozen_simulation_label": self._required(
                            row, "frozen_hypothesis_label"
                        ),
                        "original_discovered": self._required(
                            row, "original_evidence_gated"
                        ),
                        "baseline_discovered": self._required(
                            row, "simple_baseline"
                        ),
                        "refined_discovered": self._required(row, "refined"),
                    }
                )
            except ValueError:
                warnings.append(
                    "A product classification row was incomplete and omitted."
                )
        return products

    def _read_chronology(
        self, path: Path, warnings: list[str]
    ) -> list[dict[str, object]]:
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.DictReader(handle))
        except OSError:
            warnings.append("Chronological classification artifact is missing.")
            return []
        parsed = []
        for row in rows:
            try:
                parsed.append(
                    {
                        "window_months": int(row["window_months"]),
                        "model": self._required(row, "model"),
                        "accuracy": self._finite(row["accuracy"]),
                        "coverage": self._finite(row["coverage"]),
                        "covered_accuracy": self._optional_finite(
                            row.get("covered_accuracy")
                        ),
                        "unknown_rate": self._finite(row["unknown_rate"]),
                        "seasonal_precision": self._optional_finite(
                            row.get("seasonal_precision")
                        ),
                        "false_seasonal_assignments": int(
                            row["false_seasonal_assignments"]
                        ),
                    }
                )
            except (KeyError, TypeError, ValueError):
                warnings.append(
                    "A chronological classification row was incomplete and omitted."
                )
        return parsed

    def _read_latest_forecast_series(
        self, path: Path, warnings: list[str]
    ) -> dict[str, list[dict[str, object]]]:
        latest_origin: dict[str, str] = {}
        rows_by_product: dict[str, list[dict[str, object]]] = {}
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                for row in csv.DictReader(handle):
                    if row.get("horizon_days") != "28":
                        continue
                    product_id = self._required(row, "product_id")
                    origin = self._required(row, "origin")
                    if origin < latest_origin.get(product_id, ""):
                        continue
                    if origin > latest_origin.get(product_id, ""):
                        latest_origin[product_id] = origin
                        rows_by_product[product_id] = []
                    forecast_date = self._required(row, "forecast_date")
                    if forecast_date <= origin:
                        warnings.append(
                            "A historical replay row failed the future-date "
                            "check and was omitted."
                        )
                        continue
                    rows_by_product[product_id].append(
                        {
                            "origin": origin,
                            "forecast_date": forecast_date,
                            "model": self._required(row, "requested_model"),
                            "actual": self._finite(row["actual"]),
                            "predicted": self._finite(row["predicted"]),
                            "signed_error": self._finite(row["signed_error"]),
                            "unit": self._required(row, "unit"),
                        }
                    )
        except OSError:
            warnings.append("Historical forecast-versus-actual artifact is missing.")
            return {}
        except (KeyError, TypeError, ValueError):
            warnings.append(
                "Historical forecast-versus-actual artifact is incomplete."
            )
            return {}
        return rows_by_product

    @staticmethod
    def _required(row: dict[str, Any], field: str) -> str:
        value = str(row.get(field, "")).strip()
        if not value:
            raise ValueError(f"{field} is required")
        return value

    @staticmethod
    def _finite(value: object) -> float:
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ValueError("numeric report value must be finite")
        return parsed

    @classmethod
    def _optional_finite(cls, value: object) -> float | None:
        text = str(value or "").strip()
        return None if not text else cls._finite(text)
