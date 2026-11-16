from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timedelta
from typing import Any, Mapping

from app.api.job_materialization import demand_input_digest
from app.forecasting.execution import DemandForecastExecution
from app.forecasting.models import DemandForecast, HistoricalDemandDataset

from .json_codec import json_safe


def _producer_key(forecast: DemandForecast, requested_key: str) -> str:
    name = forecast.metadata.model_name.lower()
    if "blend" in name:
        return "blend"
    if "mean28" in name or "mean_28" in name:
        return "mean28"
    if "seasonal" in name and "experimental" in name:
        return "seasonal_experimental"
    if "lightgbm" in name or "lgbm" in name:
        return "lightgbm"
    raise ValueError("executor returned an unrecognized producing model")


def _series_bundle(
    forecasts: tuple[DemandForecast, ...],
    *,
    requested_key: str,
    history: HistoricalDemandDataset,
    input_digest: str,
    implementation_digest: str,
    producer_config_digests: Mapping[str, str],
    expected_horizon: int,
) -> dict[str, Any]:
    if not forecasts:
        raise ValueError("executor returned an empty forecast series")
    first = forecasts[0]
    if len(forecasts) != expected_horizon:
        raise ValueError("executor returned a forecast with the wrong horizon")
    if any(
        value.location_id != first.location_id
        or value.product_id != first.product_id
        or value.unit != first.unit
        or value.unit != history.product.unit
        or value.product_id != history.product.product_id
        or value.location_id != history.product.location_id
        for value in forecasts
    ):
        raise ValueError("executor returned inconsistent forecast identity")
    start_date = forecasts[0].forecast_date
    if start_date != history.history_end + timedelta(days=1):
        raise ValueError("forecast period does not begin after the frozen history")
    if tuple(value.forecast_date for value in forecasts) != tuple(
        start_date + timedelta(days=index) for index in range(expected_horizon)
    ):
        raise ValueError("executor returned a non-contiguous forecast period")
    if any(not value.quantity.is_finite() or value.quantity < 0 for value in forecasts):
        raise ValueError("executor returned an invalid forecast quantity")
    producer_key = _producer_key(first, requested_key)
    config_digest = producer_config_digests.get(producer_key)
    if not config_digest:
        raise ValueError("worker does not have the producing model configuration digest")
    if len(config_digest) != 64 or any(character not in "0123456789abcdef" for character in config_digest):
        raise ValueError("forecast producer configuration digest is invalid")
    return {
        "producer": {
            "key": producer_key,
            "version": first.metadata.model_version,
            "config_digest": config_digest,
            "implementation_digest": implementation_digest,
            "model_name": first.metadata.model_name,
        },
        "input": {
            "input_digest": input_digest,
            "history_window_days": (
                (history.history_end - history.history_start).days + 1
                if history.history_start is not None
                else 0
            ),
            "history_start": history.history_start.isoformat()
            if history.history_start
            else None,
            "history_end": history.history_end.isoformat(),
            "provenance": history.provenance.value,
        },
        "forecast_start_date": first.forecast_date.isoformat(),
        "forecast_end_date": forecasts[-1].forecast_date.isoformat(),
        "points": [
            {
                "date": value.forecast_date.isoformat(),
                "quantity": value.quantity,
                "unit": value.unit,
                "metadata": json_safe(asdict(value.metadata)),
            }
            for value in forecasts
        ],
    }


def build_output_bundle(
    *,
    execution: DemandForecastExecution,
    job: Mapping[str, Any],
    history: HistoricalDemandDataset,
    implementation_digest: str,
    producer_config_digests: Mapping[str, str],
    recommendation_history: HistoricalDemandDataset | None = None,
    preliminary_history: HistoricalDemandDataset | None = None,
) -> dict[str, Any]:
    requested_key = str(job["requested_model_key"])
    requested_input_digest = str(job["request_input_digest"])
    requested_history_digest = demand_input_digest(
        history, source_data_as_of=execution.source_data_as_of
    )
    if requested_history_digest != requested_input_digest:
        raise ValueError("frozen demand input digest differs from the queued job")

    roles: dict[str, dict[str, Any]] = {}
    recommendation_history = recommendation_history or history
    preliminary_history = preliminary_history or history
    requested_history = (
        recommendation_history
        if requested_key == "seasonal_experimental"
        and execution.experimental_fallback_reason
        else history
    )
    role_values = (
        ("requested_forecasts", execution.requested_forecasts, requested_history),
        ("recommendation_forecasts", execution.recommendation_forecasts, recommendation_history),
        ("preliminary_forecasts", execution.preliminary_forecasts, preliminary_history),
    )
    for role, forecasts, role_history in role_values:
        digest = demand_input_digest(
            role_history, source_data_as_of=execution.source_data_as_of
        )
        roles[role] = {
            "status": "available",
            "series": [
                _series_bundle(
                    tuple(forecasts),
                    requested_key=requested_key,
                    history=role_history,
                    input_digest=digest,
                    implementation_digest=implementation_digest,
                    producer_config_digests=producer_config_digests,
                    expected_horizon=(
                        28 if role == "preliminary_forecasts" else int(job["horizon_days"])
                    ),
                )
            ],
        }
    # Seasonal fallback is tracked on the execution, while Blend and
    # LightGBM fallbacks are tracked on the actual requested forecast metadata.
    # Persist the reason at the role level whenever the producing model differs
    # from the requested model, as required by result publication validation.
    requested_producer = roles["requested_forecasts"]["series"][0]["producer"]["key"]
    fallback_reason = (
        execution.experimental_fallback_reason
        or execution.requested_forecasts[0].metadata.fallback_reason
    )
    if requested_producer != requested_key and (
        not fallback_reason or not fallback_reason.strip()
    ):
        raise ValueError("requested-model fallback has no reason")
    if fallback_reason:
        roles["requested_forecasts"]["fallback_reason"] = fallback_reason

    requested = tuple(execution.requested_forecasts)
    start = requested[0].forecast_date
    end = requested[-1].forecast_date
    return {
        "schema_version": 1,
        "execution": {
            "requested_model": {
                "key": requested_key,
                "version": str(job["requested_model_version"]),
                "config_digest": str(job["requested_model_config_digest"]),
                "implementation_digest": str(
                    job["requested_implementation_digest"]
                ),
            },
            "horizon_days": int(job["horizon_days"]),
            "as_of_business_date": str(job["as_of_business_date"]),
            "as_of_at": _iso_timestamp(job["as_of_at"]),
            "sales_revision": int(job["sales_revision"]),
            "product_revision": int(job["product_revision"]),
            "request_input_digest": requested_input_digest,
            "inventory_unit": history.product.unit,
            "forecast_start_date": start.isoformat(),
            "forecast_end_date": end.isoformat(),
            "source_data_as_of": _iso_timestamp(execution.source_data_as_of),
            "history_window_days": int(job["history_window_days"]),
        },
        "outputs": roles,
    }


def _iso_timestamp(value: Any) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).isoformat()
