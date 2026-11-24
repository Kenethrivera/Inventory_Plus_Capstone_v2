"""Read-only, location-scoped access to the service-only forecast jobs RPC."""
from __future__ import annotations

from datetime import date
from typing import Any

import httpx

from .contracts import DataUnavailableError


_JOB_FIELDS = (
    "job_id", "product_id", "product_name", "sku", "model_key",
    "model_version", "as_of_business_date", "horizon_days", "status",
    "display_status", "created_at", "started_at", "completed_at",
    "updated_at", "duration_seconds", "attempt_count", "max_attempts",
    "safe_error_code", "result_id", "result_created_at",
)
_COUNT_FIELDS = (
    "total_jobs", "queued", "retry_pending", "running", "succeeded",
    "failed", "cancelled", "superseded",
)
_STATUSES = {"queued", "running", "succeeded", "failed", "cancelled", "superseded"}
_DISPLAY_STATUSES = _STATUSES | {"retry_pending"}
_MODELS = {"blend", "lightgbm", "mean28", "seasonal_experimental"}


class ForecastJobReadRepository:
    def __init__(self, *, url: str, secret_key: str, timeout_seconds: float,
                 client: httpx.Client | None = None) -> None:
        if not secret_key or secret_key.startswith("sb_publishable_"):
            raise RuntimeError("Forecast job reads require a server-only Supabase secret")
        self._url = url.rstrip("/")
        self._headers = {
            "apikey": secret_key,
            "Content-Type": "application/json",
            "Accept-Profile": "public",
            "Content-Profile": "public",
        }
        if not secret_key.startswith("sb_secret_"):
            self._headers["Authorization"] = f"Bearer {secret_key}"
        self._client = client or httpx.Client(timeout=timeout_seconds)

    def close(self) -> None:
        self._client.close()

    def page(self, *, location_id: str, page: int, page_size: int,
             latest_only: bool, search: str | None, model_key: str | None,
             status: str | None, from_date: date | None,
             to_date: date | None) -> dict[str, Any]:
        try:
            response = self._client.post(
                f"{self._url}/rest/v1/rpc/forecast_jobs_page_v1",
                headers=self._headers,
                json={
                    "p_location_id": location_id,
                    "p_page": page,
                    "p_page_size": page_size,
                    "p_latest_only": latest_only,
                    "p_search": search,
                    "p_model_key": model_key,
                    "p_status": status,
                    "p_from_business_date": from_date.isoformat() if from_date else None,
                    "p_to_business_date": to_date.isoformat() if to_date else None,
                },
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise DataUnavailableError("Forecast jobs are temporarily unavailable") from error
        if response.status_code >= 400:
            raise DataUnavailableError("Forecast jobs are temporarily unavailable")
        try:
            value = response.json()
        except (ValueError, TypeError) as error:
            raise DataUnavailableError("Forecast jobs response is invalid") from error
        if (not isinstance(value, dict)
            or any(isinstance(value.get(key), bool) or not isinstance(value.get(key), int)
                   for key in ("page", "page_size", "total_count", "page_count"))
            or not isinstance(value.get("latest_only"), bool)
            or not isinstance(value.get("generated_at"), str)
            or not isinstance(value.get("counts"), dict)
            or not isinstance(value.get("items"), list)):
            raise DataUnavailableError("Forecast jobs response is invalid")
        counts = value["counts"]
        if any(isinstance(counts.get(key), bool) or not isinstance(counts.get(key), int)
               for key in _COUNT_FIELDS):
            raise DataUnavailableError("Forecast jobs response is invalid")
        items = value["items"]
        if len(items) > page_size or any(
            not isinstance(item, dict)
            or not isinstance(item.get("job_id"), str)
            or not isinstance(item.get("product_id"), str)
            or item.get("status") not in _STATUSES
            or item.get("display_status") not in _DISPLAY_STATUSES
            or item.get("model_key") not in _MODELS
            or not isinstance(item.get("created_at"), str)
            for item in items
        ):
            raise DataUnavailableError("Forecast jobs response is invalid")
        return {
            "page": value["page"],
            "page_size": value["page_size"],
            "total_count": value["total_count"],
            "page_count": value["page_count"],
            "latest_only": value["latest_only"],
            "generated_at": value["generated_at"],
            "counts": {key: counts[key] for key in _COUNT_FIELDS},
            "items": [{key: item.get(key) for key in _JOB_FIELDS} for item in items],
        }
