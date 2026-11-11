from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Iterable, Mapping
from zoneinfo import ZoneInfo

from app.data import DailyDemand
from app.data.validation import DemandDataError

from .contracts import DataUnavailableError, ForecastDataAdapter, SessionProfile


BUSINESS_TIMEZONE = "Asia/Manila"
ELIGIBLE_STATUSES = frozenset(
    {"completed_evaluable", "completed_zero_sales"}
)


@dataclass(frozen=True)
class _SavedForecast:
    recommendation_id: int
    product_id: str
    product_name: str
    product_sku: str
    inventory_unit: str
    recommendation_date: datetime
    period_start: date
    period_end: date
    predicted_demand: Decimal


class ForecastPerformanceEvaluator:
    """Evaluate immutable saved forecasts against later completed sales.

    The evaluator never recalculates an old prediction. It reads only the
    trusted recommendation snapshot returned by the deployed tracking RPC and
    completed, non-returned sales returned by ``forecast_daily_demand_v1``.
    """

    def __init__(self, adapter: ForecastDataAdapter) -> None:
        self._adapter = adapter

    def evaluate(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        tracking_rows: Iterable[Mapping[str, object]],
        now: datetime,
    ) -> dict[str, object]:
        if now.tzinfo is None:
            raise ValueError("now must include a timezone")
        manila = ZoneInfo(BUSINESS_TIMEZONE)
        today = now.astimezone(manila).date()
        forecasts = tuple(
            _parse_saved_forecast(row, expected_product_id=product_id)
            for row in tracking_rows
        )
        completed = tuple(value for value in forecasts if value.period_end < today)

        demand_rows: tuple[DailyDemand, ...] = ()
        retrieval_error: str | None = None
        if completed:
            try:
                demand_rows = self._load_completed_windows(
                    profile=profile,
                    session_token=session_token,
                    forecasts=completed,
                    manila=manila,
                )
            except (DataUnavailableError, DemandDataError, ValueError):
                # The monitoring panel remains read-only and non-blocking. A
                # failed authoritative read must not be presented as zero sales.
                retrieval_error = (
                    "Completed-sales data is unavailable or failed validation. "
                    "No actual quantity was inferred."
                )

        items = [
            self._evaluate_one(
                forecast=value,
                location_id=profile.location_id,
                today=today,
                demand_rows=demand_rows,
                retrieval_error=retrieval_error,
            )
            for value in forecasts
        ]
        return {
            "schema_version": "forecast-performance-v1",
            "read_only": True,
            "business_timezone": BUSINESS_TIMEZONE,
            "scope": "saved_recommendation_forecasts_only",
            "generated_at": now,
            "data_source_available": retrieval_error is None,
            "data_source_warning": retrieval_error,
            "items": items,
            "summaries_by_unit": _summaries_by_unit(items),
            "limitations": [
                "Only immutable 28-day LightGBM forecasts saved with a restock recommendation are evaluated.",
                "Completed sales measure observed purchases, not unmet demand during stockouts.",
                "Restock receipts and recommendation variance are excluded from forecast accuracy.",
            ],
        }

    def _load_completed_windows(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        forecasts: tuple[_SavedForecast, ...],
        manila: ZoneInfo,
    ) -> tuple[DailyDemand, ...]:
        rows: list[DailyDemand] = []
        for start, end_exclusive in _coalesced_windows(forecasts):
            rows.extend(
                self._adapter.load_daily_demand(
                    profile=profile,
                    session_token=session_token,
                    period_start=datetime.combine(start, time.min, manila),
                    period_end=datetime.combine(end_exclusive, time.min, manila),
                    business_timezone=BUSINESS_TIMEZONE,
                )
            )
        if any(row.location_id != profile.location_id for row in rows):
            raise DataUnavailableError(
                "Forecast performance sales are outside the session location"
            )
        return tuple(rows)

    @staticmethod
    def _evaluate_one(
        *,
        forecast: _SavedForecast,
        location_id: str,
        today: date,
        demand_rows: tuple[DailyDemand, ...],
        retrieval_error: str | None,
    ) -> dict[str, object]:
        base: dict[str, object] = {
            "recommendation_id": forecast.recommendation_id,
            "location_id": location_id,
            "product_id": forecast.product_id,
            "product_name": forecast.product_name,
            "product_sku": forecast.product_sku,
            "inventory_unit": forecast.inventory_unit,
            "recommendation_date": forecast.recommendation_date,
            "forecast_period_start": forecast.period_start,
            "forecast_period_end": forecast.period_end,
            "predicted_demand": forecast.predicted_demand,
            "forecast_model": "lightgbm",
            "forecast_version": "1",
            "training_history_days": 365,
            "synthetic_sales": _is_simulation_sku(forecast.product_sku),
            "sales_provenance": (
                "synthetic_simulation_history"
                if _is_simulation_sku(forecast.product_sku)
                else "live_supabase_completed_sales"
            ),
            "stock_availability_known": False,
        }
        if (forecast.period_end - forecast.period_start).days != 27:
            return {
                **base,
                "evaluation_status": "insufficient_sales_data",
                "status_explanation": "Saved forecast period is not exactly 28 calendar days.",
                "evaluable": False,
                "actual_completed_sales": None,
                "signed_forecast_error": None,
                "absolute_error": None,
                "percentage_error": None,
                "error_direction": None,
            }
        if forecast.period_end >= today:
            return {
                **base,
                "evaluation_status": "awaiting_completion",
                "status_explanation": (
                    "The full forecast period has not ended in Asia/Manila."
                ),
                "evaluable": False,
                "actual_completed_sales": None,
                "signed_forecast_error": None,
                "absolute_error": None,
                "percentage_error": None,
                "error_direction": None,
            }
        if retrieval_error is not None:
            return {
                **base,
                "evaluation_status": "insufficient_sales_data",
                "status_explanation": retrieval_error,
                "evaluable": False,
                "actual_completed_sales": None,
                "signed_forecast_error": None,
                "absolute_error": None,
                "percentage_error": None,
                "error_direction": None,
            }

        relevant = tuple(
            row
            for row in demand_rows
            if row.product_id == forecast.product_id
            and forecast.period_start <= row.business_date <= forecast.period_end
        )
        incompatible_units = sorted(
            {
                row.unit
                for row in relevant
                if row.unit.strip().casefold()
                != forecast.inventory_unit.strip().casefold()
            }
        )
        if incompatible_units:
            return {
                **base,
                "evaluation_status": "insufficient_sales_data",
                "status_explanation": (
                    "Completed sales use an inventory unit that does not match "
                    "the immutable forecast snapshot."
                ),
                "evaluable": False,
                "actual_completed_sales": None,
                "signed_forecast_error": None,
                "absolute_error": None,
                "percentage_error": None,
                "error_direction": None,
            }

        actual = sum((row.quantity for row in relevant), Decimal("0"))
        signed = forecast.predicted_demand - actual
        absolute = abs(signed)
        percentage = signed / actual * Decimal("100") if actual > 0 else None
        direction = (
            "overprediction"
            if signed > 0
            else "underprediction"
            if signed < 0
            else "on_target"
        )
        zero_actual = actual == 0
        return {
            **base,
            "evaluation_status": (
                "completed_zero_sales" if zero_actual else "completed_evaluable"
            ),
            "status_explanation": (
                "No completed customer sales were recorded in the authoritative RPC window; percentage error is undefined."
                if zero_actual
                else "The full period ended and completed customer sales were retrieved successfully."
            ),
            "evaluable": True,
            "actual_completed_sales": actual,
            "signed_forecast_error": signed,
            "absolute_error": absolute,
            "percentage_error": percentage,
            "error_direction": direction,
        }


def _parse_saved_forecast(
    row: Mapping[str, object], *, expected_product_id: str
) -> _SavedForecast:
    try:
        product_id = str(row["product_id_snapshot"])
        if product_id != expected_product_id:
            raise DataUnavailableError(
                "Recommendation tracking returned an unexpected product"
            )
        recommendation_date = datetime.fromisoformat(
            str(row["recommendation_date"]).replace("Z", "+00:00")
        )
        if recommendation_date.tzinfo is None:
            raise ValueError("recommendation_date has no timezone")
        return _SavedForecast(
            recommendation_id=int(row["recommendation_id"]),
            product_id=product_id,
            product_name=str(row["product_name_snapshot"]).strip(),
            product_sku=str(row["product_sku_snapshot"]).strip(),
            inventory_unit=str(row["inventory_unit"]).strip(),
            recommendation_date=recommendation_date,
            period_start=date.fromisoformat(str(row["forecast_period_start"])),
            period_end=date.fromisoformat(str(row["forecast_period_end"])),
            predicted_demand=Decimal(str(row["predicted_demand"])),
        )
    except (KeyError, TypeError, ValueError, ArithmeticError) as error:
        raise DataUnavailableError(
            "Saved forecast tracking data is malformed"
        ) from error


def _coalesced_windows(
    forecasts: Iterable[_SavedForecast],
) -> tuple[tuple[date, date], ...]:
    """Merge overlapping/adjacent windows without crossing the RPC 5-year cap."""
    intervals = sorted(
        (value.period_start, value.period_end + timedelta(days=1))
        for value in forecasts
    )
    merged: list[tuple[date, date]] = []
    for start, end in intervals:
        if not merged:
            merged.append((start, end))
            continue
        prior_start, prior_end = merged[-1]
        combined_end = max(prior_end, end)
        if start <= prior_end and combined_end - prior_start <= timedelta(days=1825):
            merged[-1] = (prior_start, combined_end)
        else:
            merged.append((start, end))
    return tuple(merged)


def _summaries_by_unit(items: Iterable[Mapping[str, object]]) -> list[dict[str, object]]:
    grouped: dict[str, list[Mapping[str, object]]] = {}
    for item in items:
        if item.get("evaluation_status") not in ELIGIBLE_STATUSES:
            continue
        grouped.setdefault(str(item["inventory_unit"]), []).append(item)

    summaries: list[dict[str, object]] = []
    for unit, values in sorted(grouped.items()):
        predicted = sum(
            (Decimal(str(value["predicted_demand"])) for value in values),
            Decimal("0"),
        )
        actual = sum(
            (Decimal(str(value["actual_completed_sales"])) for value in values),
            Decimal("0"),
        )
        absolute = sum(
            (Decimal(str(value["absolute_error"])) for value in values),
            Decimal("0"),
        )
        signed = predicted - actual
        summaries.append(
            {
                "inventory_unit": unit,
                "evaluation_count": len(values),
                "zero_actual_count": sum(
                    1
                    for value in values
                    if value["evaluation_status"] == "completed_zero_sales"
                ),
                "predicted_total": predicted,
                "actual_total": actual,
                "absolute_error_total": absolute,
                "signed_error_total": signed,
                "wape": absolute / actual * Decimal("100") if actual > 0 else None,
                "forecast_bias": (
                    signed / actual * Decimal("100") if actual > 0 else None
                ),
            }
        )
    return summaries


def _is_simulation_sku(sku: str) -> bool:
    normalized = sku.strip().upper()
    return normalized.startswith("SIM-") or normalized.startswith("SYNTH-")
