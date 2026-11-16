from __future__ import annotations

import json
import logging
from threading import Lock
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from hashlib import sha256
from typing import Any, Mapping
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx

from app.api.contracts import DataUnavailableError
from app.api.job_materialization import DEFAULT_HISTORY_DAYS
from app.data import DailyDemand
from app.data.preprocessing import parse_rpc_daily_demand
from app.forecasting import (
    DataProvenance,
    ForecastProduct,
    HistoricalDemandDataset,
)

from .json_codec import encode_json


_logger = logging.getLogger("inventory_plus.forecasting.worker")
_MANILA = ZoneInfo("Asia/Manila")
_PAGE_SIZE = 1000
# The 365-day per-product bound means at most 365,000 daily rows at 1,000
# products. This cap remains finite while allowing that supported inventory.
_MAX_PAGES = 400


class WorkerRpcError(RuntimeError):
    def __init__(self, function: str, status: int, error_code: str | None = None):
        super().__init__(f"worker RPC {function} failed with HTTP {status}")
        self.function = function
        self.status = status
        self.error_code = error_code

    @property
    def retryable(self) -> bool:
        return self.status in {408, 425, 429, 500, 502, 503, 504}


class WorkerNetworkError(RuntimeError):
    pass


@dataclass(frozen=True)
class FrozenJobInputs:
    history: HistoricalDemandDataset
    source_data_as_of: datetime
    source_revision_fingerprint: str


class SupabaseWorkerRepository:
    """Server-only PostgREST boundary for claims, source reads, and publication."""

    def __init__(self, *, url: str, secret_key: str, timeout_seconds: float):
        if not secret_key or secret_key.startswith("sb_publishable_"):
            raise ValueError("A server-only Supabase secret key is required")
        self._base = url.rstrip("/")
        self._headers = {
            "apikey": secret_key,
            "Accept-Profile": "public",
            "Content-Profile": "public",
            "Content-Type": "application/json",
        }
        if not secret_key.startswith("sb_secret_"):
            self._headers["Authorization"] = f"Bearer {secret_key}"
        self._client = httpx.Client(timeout=timeout_seconds)
        self._demand_cache_key: tuple[str, str, str, str] | None = None
        self._demand_cache: tuple[DailyDemand, ...] = ()
        self._demand_cache_lock = Lock()

    def close(self) -> None:
        self._client.close()

    def _rpc(self, function: str, payload: Mapping[str, object]) -> Any:
        try:
            response = self._client.post(
                f"{self._base}/rest/v1/rpc/{function}",
                headers=self._headers,
                content=encode_json(payload),
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise WorkerNetworkError(type(error).__name__) from error
        if response.status_code >= 400:
            code = None
            try:
                body = response.json()
                if isinstance(body, dict) and isinstance(body.get("code"), str):
                    code = body["code"][:32]
            except (ValueError, TypeError):
                pass
            _logger.warning(
                "worker_rpc_failed rpc=%s status=%d error_code=%s",
                function,
                response.status_code,
                code or "unavailable",
            )
            raise WorkerRpcError(function, response.status_code, code)
        try:
            return response.json(parse_float=Decimal)
        except (ValueError, TypeError) as error:
            raise DataUnavailableError(
                "Forecast worker received an invalid RPC response",
                stage=f"worker_rpc:{function}:invalid_json",
            ) from error

    def claim_job(
        self,
        *,
        worker_id: str,
        lease_seconds: int,
        job_id: str | None = None,
    ) -> Mapping[str, Any] | None:
        result = self._rpc(
            "claim_forecast_job_v1",
            {
                "p_worker_id": worker_id,
                "p_lease_seconds": lease_seconds,
                "p_job_id": job_id,
            },
        )
        return result if isinstance(result, Mapping) else None

    def renew_lease(self, *, job_id: str, lease_token: str, lease_seconds: int) -> str:
        result = self._rpc(
            "renew_forecast_job_lease_v1",
            {
                "p_job_id": job_id,
                "p_lease_token": lease_token,
                "p_lease_seconds": lease_seconds,
            },
        )
        return str(result)

    def supersede(self, *, job_id: str, lease_token: str, error_code: str) -> bool:
        return bool(self._rpc(
            "supersede_forecast_job_v1",
            {
                "p_job_id": job_id,
                "p_lease_token": lease_token,
                "p_safe_error_code": error_code,
            },
        ))

    def fail(
        self,
        *,
        job_id: str,
        lease_token: str,
        error_code: str,
        retryable: bool,
        retry_delay_seconds: int,
    ) -> str:
        result = self._rpc(
            "fail_forecast_job_v1",
            {
                "p_job_id": job_id,
                "p_lease_token": lease_token,
                "p_safe_error_code": error_code,
                "p_retryable": retryable,
                "p_retry_delay_seconds": retry_delay_seconds,
            },
        )
        return str(result)

    def publish(
        self, *, job_id: str, lease_token: str, output_bundle: Mapping[str, Any]
    ) -> Mapping[str, Any]:
        result = self._rpc(
            "publish_forecast_execution_result_v1",
            {
                "p_job_id": job_id,
                "p_lease_token": lease_token,
                "p_output_bundle": output_bundle,
            },
        )
        if not isinstance(result, Mapping):
            raise DataUnavailableError("Forecast publication returned an invalid result")
        return result

    def _get(self, table: str, params: Mapping[str, object]) -> list[Mapping[str, Any]]:
        try:
            response = self._client.get(
                f"{self._base}/rest/v1/{table}",
                headers=self._headers,
                params=params,
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise WorkerNetworkError(type(error).__name__) from error
        if response.status_code >= 400:
            raise WorkerRpcError(f"read_{table}", response.status_code)
        try:
            rows = response.json(parse_float=Decimal)
        except (ValueError, TypeError) as error:
            raise DataUnavailableError(f"Worker source {table} returned invalid JSON") from error
        if not isinstance(rows, list) or any(not isinstance(row, Mapping) for row in rows):
            raise DataUnavailableError(f"Worker source {table} returned invalid rows")
        return rows

    def _product(self, job: Mapping[str, Any]) -> Mapping[str, Any]:
        rows = self._get(
            "products",
            {
                "select": "id,location_id,product_name,sku,unit,created_at,is_active",
                "id": f"eq.{job['product_id']}",
                "location_id": f"eq.{job['location_id']}",
                "is_active": "is.true",
                "limit": "1",
            },
        )
        if len(rows) != 1:
            raise DataUnavailableError("Forecast job product is no longer active in its location")
        return rows[0]

    @staticmethod
    def _revision_fingerprint(job: Mapping[str, Any]) -> str:
        vector = job.get("scope_revision_vector")
        encoded = json.dumps(vector, sort_keys=True, separators=(",", ":"), default=str)
        return sha256(encoded.encode("utf-8")).hexdigest()

    def _location_demand(self, job: Mapping[str, Any]) -> tuple[DailyDemand, ...]:
        # PostgreSQL/PostgREST may serialize timestamptz in UTC even though
        # the materializer hashes this instant in the Manila business zone.
        # Keep the same instant but normalize its representation before using
        # it in canonical input identity.
        as_of = _parse_datetime(job["as_of_at"]).astimezone(_MANILA)
        period_start = datetime.combine(
            date.fromisoformat(str(job["as_of_business_date"]))
            - timedelta(days=int(job["history_window_days"])),
            time.min,
            _MANILA,
        )
        period_end = as_of
        cache_key = (
            str(job["location_id"]),
            period_start.isoformat(),
            period_end.isoformat(),
            self._revision_fingerprint(job),
        )
        with self._demand_cache_lock:
            if cache_key == self._demand_cache_key:
                return self._demand_cache

            rows: list[Mapping[str, Any]] = []
            for page_number in range(_MAX_PAGES):
                page = self._rpc(
                    "forecast_worker_daily_demand_v1",
                    {
                        "p_job_id": str(job["id"]),
                        "p_lease_token": str(job["lease_token"]),
                        "p_offset": page_number * _PAGE_SIZE,
                        "p_limit": _PAGE_SIZE,
                    },
                )
                if not isinstance(page, list) or any(not isinstance(row, Mapping) for row in page):
                    raise DataUnavailableError("Worker demand RPC returned invalid rows")
                rows.extend(page)
                if len(page) < _PAGE_SIZE:
                    break
            else:
                raise DataUnavailableError("Worker demand RPC exceeded its bounded page limit")

            parsed = tuple(parse_rpc_daily_demand(rows))
            if any(row.location_id != str(job["location_id"]) for row in parsed):
                raise DataUnavailableError("Worker demand data crossed the claimed location scope")
            self._demand_cache_key = cache_key
            self._demand_cache = parsed
        _logger.info(
            "worker_demand_snapshot_loaded location_ref=%s rows=%d pages=%d",
            sha256(str(job["location_id"]).encode()).hexdigest()[:12],
            len(parsed),
            page_number + 1,
        )
        return parsed

    def load_frozen_inputs(self, job: Mapping[str, Any]) -> FrozenJobInputs:
        product_row = self._product(job)
        product = ForecastProduct(
            location_id=str(product_row["location_id"]),
            product_id=str(product_row["id"]),
            product_name=str(product_row.get("product_name") or ""),
            sku=str(product_row["sku"]) if product_row.get("sku") else None,
            unit=str(product_row.get("unit") or ""),
        )
        as_of = _parse_datetime(job["as_of_at"]).astimezone(_MANILA)
        business_date = date.fromisoformat(str(job["as_of_business_date"]))
        history_end = business_date - timedelta(days=1)
        period_start = business_date - timedelta(days=int(job["history_window_days"]))
        all_demand = self._location_demand(job)
        target = tuple(
            row for row in all_demand
            if row.location_id == product.location_id and row.product_id == product.product_id
        )
        created_at = _parse_datetime(product_row["created_at"]).astimezone(_MANILA).date()
        history_start = (
            max(period_start, created_at) if target else None
        )
        history = HistoricalDemandDataset.from_real_observations(
            product=product,
            history_start=history_start,
            history_end=history_end,
            observations=target,
        )
        return FrozenJobInputs(
            history=history,
            source_data_as_of=as_of,
            source_revision_fingerprint=self._revision_fingerprint(job),
        )


def _parse_datetime(value: Any) -> datetime:
    if isinstance(value, datetime):
        parsed = value
    else:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("worker timestamp must include timezone")
    return parsed
