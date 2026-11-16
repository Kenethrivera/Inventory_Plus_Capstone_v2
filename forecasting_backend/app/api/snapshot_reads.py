from __future__ import annotations

import logging
from typing import Any

import httpx

from .contracts import DataUnavailableError

_logger = logging.getLogger("inventory_plus.forecasting.snapshots")


class ForecastSnapshotReadRepository:
    """Server-only, bounded reads from immutable execution result bundles."""

    def __init__(
        self,
        *,
        url: str,
        secret_key: str,
        timeout_seconds: float,
        client: httpx.Client | None = None,
    ) -> None:
        if not secret_key or secret_key.startswith("sb_publishable_"):
            raise RuntimeError("Snapshot reads require a server-only Supabase secret")
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

    def overview(
        self,
        *,
        location_id: str,
        model_key: str,
        page: int,
        page_size: int,
        unit: str | None = None,
        search: str | None = None,
    ) -> dict[str, Any]:
        return self._rpc({
            "p_location_id": location_id,
            "p_product_id": None,
            "p_model_key": model_key,
            "p_page": page,
            "p_page_size": page_size,
            "p_unit": unit,
            "p_search": search,
            "p_include_bundle": False,
        })

    def product(
        self, *, location_id: str, product_id: str, model_key: str
    ) -> dict[str, Any]:
        return self._rpc({
            "p_location_id": location_id,
            "p_product_id": product_id,
            "p_model_key": model_key,
            "p_page": 1,
            "p_page_size": 1,
            "p_unit": None,
            "p_search": None,
            "p_include_bundle": True,
        })

    def _rpc(self, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            response = self._client.post(
                f"{self._url}/rest/v1/rpc/forecast_snapshot_page_v1",
                headers=self._headers,
                json=payload,
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise DataUnavailableError(
                "Forecast snapshot service is temporarily unavailable",
                stage="forecast_snapshot_rpc:network",
            ) from error
        if response.status_code >= 400:
            _logger.warning(
                "snapshot_read_rpc_failed status=%d category=upstream_http_error",
                response.status_code,
            )
            raise DataUnavailableError(
                "Forecast snapshot service is temporarily unavailable",
                stage=f"forecast_snapshot_rpc:http_{response.status_code}",
            )
        try:
            result = response.json()
        except (ValueError, TypeError) as error:
            raise DataUnavailableError(
                "Forecast snapshot service returned invalid data",
                stage="forecast_snapshot_rpc:invalid_json",
            ) from error
        if not isinstance(result, dict):
            raise DataUnavailableError(
                "Forecast snapshot service returned invalid data",
                stage="forecast_snapshot_rpc:invalid_shape",
            )
        self._validate_page(result)
        return result

    @staticmethod
    def _validate_page(result: dict[str, Any]) -> None:
        items = result.get("items")
        numeric_fields = ("page", "page_size", "total_count", "page_count")
        if (
            any(
                isinstance(result.get(field), bool)
                or not isinstance(result.get(field), int)
                for field in numeric_fields
            )
            or not isinstance(items, list)
        ):
            raise DataUnavailableError(
                "Forecast snapshot service returned invalid data",
                stage="forecast_snapshot_rpc:invalid_shape",
            )
        for item in items:
            if not isinstance(item, dict):
                raise DataUnavailableError(
                    "Forecast snapshot service returned invalid data",
                    stage="forecast_snapshot_rpc:invalid_item",
                )
            product = item.get("product")
            job = item.get("job")
            snapshot = item.get("snapshot")
            if (
                not isinstance(product, dict)
                or not isinstance(product.get("product_id"), str)
                or not isinstance(product.get("location_id"), str)
                or not isinstance(product.get("name"), str)
                or not isinstance(product.get("unit"), str)
                or not isinstance(job, dict)
                or snapshot is not None and not isinstance(snapshot, dict)
                or item.get("status") not in {
                    "completed",
                    "stale",
                    "queued",
                    "running",
                    "failed",
                    "superseded",
                    "cancelled",
                    "no_forecast",
                }
            ):
                raise DataUnavailableError(
                    "Forecast snapshot service returned invalid data",
                    stage="forecast_snapshot_rpc:invalid_item",
                )
