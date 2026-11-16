"""Apply existing restock rules to immutable forecasts and current inventory.

This module decodes stored model output. It never prepares demand history or
invokes a forecasting model.
"""
from __future__ import annotations

from dataclasses import replace
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any, Mapping

from app.forecasting.models import (
    ColdStartReason,
    ColdStartStrategy,
    DataProvenance,
    DataQualityMetadata,
    DatasetRole,
    DemandForecast,
    ForecastMetadata,
    ModelComponent,
)
from app.recommendations.models import DemandForecastSnapshot, ManualDemandEstimate

from .contracts import AnalysisContext, DataUnavailableError, SessionProfile
from .serialization import analysis_response
from .service import ForecastAnalysisService


def _object(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise DataUnavailableError(f"Saved forecast {name} is unavailable")
    return value


def _timestamp(value: Any) -> datetime:
    result = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Saved forecast timestamp has no timezone")
    return result


def _optional_date(value: Any) -> date | None:
    return date.fromisoformat(str(value)) if value is not None else None


def _metadata(raw: Mapping[str, Any]) -> ForecastMetadata:
    quality = _object(raw.get("data_quality"), "data quality")
    return ForecastMetadata(
        model_name=str(raw["model_name"]),
        model_version=str(raw["model_version"]),
        lookback_days=int(raw["lookback_days"]),
        history_days_available=int(raw["history_days_available"]),
        sample_days_used=int(raw["sample_days_used"]),
        nonzero_demand_days=int(raw["nonzero_demand_days"]),
        is_cold_start=raw["is_cold_start"] is True,
        cold_start_reason=(
            ColdStartReason(raw["cold_start_reason"])
            if raw.get("cold_start_reason") is not None else None
        ),
        cold_start_strategy=(
            ColdStartStrategy(raw["cold_start_strategy"])
            if raw.get("cold_start_strategy") is not None else None
        ),
        history_start=_optional_date(raw.get("history_start")),
        history_end=date.fromisoformat(str(raw["history_end"])),
        dataset_role=DatasetRole(raw["dataset_role"]),
        data_provenance=DataProvenance(raw["data_provenance"]),
        forecast_horizon_days=int(raw["forecast_horizon_days"]),
        data_quality=DataQualityMetadata(
            history_calendar_days=int(quality["history_calendar_days"]),
            observed_sales_days=int(quality["observed_sales_days"]),
            assumed_zero_sales_days=int(quality["assumed_zero_sales_days"]),
            stockout_censored_days=int(quality["stockout_censored_days"]),
            availability_evidence_days=int(quality["availability_evidence_days"]),
            availability_unknown_days=int(quality["availability_unknown_days"]),
            valid_target_days=int(quality["valid_target_days"]),
            warnings=tuple(str(item) for item in quality.get("warnings", ())),
        ),
        fallback_reason=(
            str(raw["fallback_reason"])
            if raw.get("fallback_reason") is not None else None
        ),
        calibration_factor=(
            Decimal(str(raw["calibration_factor"]))
            if raw.get("calibration_factor") is not None else None
        ),
        calibration_points=int(raw.get("calibration_points") or 0),
        calibration_period_end=_optional_date(raw.get("calibration_period_end")),
        components=tuple(
            ModelComponent(
                model_name=str(component["model_name"]),
                model_version=str(component["model_version"]),
                weight=Decimal(str(component["weight"])),
            )
            for component in raw.get("components", ())
        ),
    )


def _series(
    bundle: Mapping[str, Any], role: str, *, context: AnalysisContext,
    expected_horizon: int, start_date: date,
) -> tuple[DemandForecast, ...]:
    outputs = _object(bundle.get("outputs"), "outputs")
    output = _object(outputs.get(role), role)
    series = output.get("series")
    if output.get("status") != "available" or not isinstance(series, list) or len(series) != 1:
        raise DataUnavailableError(f"Saved forecast {role} is incomplete")
    points = _object(series[0], f"{role} series").get("points")
    if not isinstance(points, list) or len(points) != expected_horizon:
        raise DataUnavailableError(f"Saved forecast {role} has an invalid horizon")
    product = context.history.product
    forecasts: list[DemandForecast] = []
    for index, raw_point in enumerate(points):
        point = _object(raw_point, f"{role} point")
        forecast_date = date.fromisoformat(str(point["date"]))
        if (
            forecast_date != start_date + timedelta(days=index)
            or str(point["unit"]).casefold() != product.unit.casefold()
        ):
            raise DataUnavailableError(f"Saved forecast {role} has mismatched dates or units")
        quantity = Decimal(str(point["quantity"]))
        if not quantity.is_finite() or quantity < 0:
            raise DataUnavailableError(f"Saved forecast {role} has an invalid quantity")
        forecasts.append(DemandForecast(
            forecast_date=forecast_date,
            location_id=product.location_id,
            product_id=product.product_id,
            product_name=product.product_name,
            unit=product.unit,
            quantity=quantity,
            metadata=_metadata(_object(point.get("metadata"), "metadata")),
            sku=product.sku,
        ))
    return tuple(forecasts)


def current_stock_analysis(
    *, service: ForecastAnalysisService, profile: SessionProfile,
    context: AnalysisContext, snapshot: Mapping[str, Any], now: datetime,
    manual_daily_demand: Decimal | None = None,
    manual_unit: str | None = None,
    manual_rationale: str | None = None,
    manual_confirmed: bool = False,
) -> dict[str, Any]:
    """Re-run only existing recommendation calculators against live stock."""
    bundle = _object(snapshot.get("bundle"), "bundle")
    execution = _object(bundle.get("execution"), "execution")
    requested_model = _object(execution.get("requested_model"), "model")
    product = context.history.product
    if (
        product.product_id != str(snapshot.get("product_id"))
        or product.location_id != str(snapshot.get("location_id"))
        or product.unit.casefold() != str(snapshot.get("inventory_unit")).casefold()
    ):
        raise DataUnavailableError("Saved forecast and current inventory scope differ")
    horizon = int(snapshot["horizon_days"])
    start_date = date.fromisoformat(str(snapshot["forecast_start_date"]))
    generated_at = _timestamp(snapshot["created_at"])
    source_data_as_of = _timestamp(snapshot["source_data_as_of"])
    requested = _series(bundle, "requested_forecasts", context=context,
                        expected_horizon=horizon, start_date=start_date)
    recommendation = _series(bundle, "recommendation_forecasts", context=context,
                             expected_horizon=horizon, start_date=start_date)
    preliminary = _series(bundle, "preliminary_forecasts", context=context,
                          expected_horizon=28, start_date=start_date)
    if requested[-1].forecast_date != date.fromisoformat(str(snapshot["forecast_end_date"])):
        raise DataUnavailableError("Saved forecast end date does not match its header")
    manual = None
    if manual_daily_demand is not None:
        if not requested[0].metadata.is_cold_start:
            raise ValueError("Manual estimates require a cold-start forecast")
        if not manual_daily_demand.is_finite() or manual_daily_demand < 0:
            raise ValueError("Manual daily demand must be finite and nonnegative")
        if not (manual_unit or "").strip() or not (manual_rationale or "").strip():
            raise ValueError("Manual unit and rationale are required")
        if not manual_confirmed:
            raise ValueError("Manual demand requires staff confirmation")
        manual = ManualDemandEstimate(
            daily_quantity=manual_daily_demand,
            unit=manual_unit or "",
            captured_at=now,
            rationale=manual_rationale or "",
        )
    preliminary_insight = service._preliminary_insights.calculate(
        forecast=DemandForecastSnapshot(
            forecasts=preliminary, generated_at=generated_at,
            source_data_as_of=source_data_as_of,
        ),
        inventory=context.inventory,
    )
    recommendation_result = service._recommendations.recommend(
        forecast=DemandForecastSnapshot(
            forecasts=recommendation, generated_at=generated_at,
            source_data_as_of=source_data_as_of,
        ),
        inventory=context.inventory,
        supplier=context.supplier,
        safety_stock=context.safety_stock,
        policy=context.policy,
        recommendation_at=now,
        conversions=context.conversions,
        manual_demand=manual,
    )
    requested_role = _object(_object(bundle["outputs"], "outputs").get("requested_forecasts"), "requested role")
    return analysis_response(
        profile=profile,
        context=replace(context, source_data_as_of=source_data_as_of),
        forecasts=list(requested),
        preliminary_insight=preliminary_insight,
        recommendation=recommendation_result,
        generated_at=generated_at,
        manual_demand=manual,
        requested_model=str(requested_model["key"]),
        requested_history_days=int(snapshot["history_window_days"]),
        experimental_fallback_reason=(
            str(requested_role["fallback_reason"])
            if requested_role.get("fallback_reason") is not None else None
        ),
        seasonal_context=None,
        recommendation_forecast_model=recommendation[0].metadata.model_name,
        experimental_forecast_used_for_replenishment=False,
    )
