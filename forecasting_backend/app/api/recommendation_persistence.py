from __future__ import annotations

from decimal import Decimal
from typing import Any, Mapping
from uuid import UUID

import httpx

from .contracts import (
    AuthenticationError,
    AuthorizationError,
    DataUnavailableError,
    RecommendationConflictError,
    RecommendationPersistenceAdapter,
    TrustedRecommendationSnapshot,
)
from .settings import ApiSettings


class SupabaseSecretRestClient:
    """Minimal RPC client whose credential is never exposed to public code.

    New ``sb_secret_`` keys authenticate through ``apikey``. Legacy JWT-based
    service-role keys additionally require the bearer header. Neither value is
    included in errors, responses, or logs.
    """

    _RPC_PAGE_SIZE = 1000
    _RPC_MAX_PAGES = 100

    def __init__(self, *, url: str, secret_key: str, timeout_seconds: float) -> None:
        if not secret_key.strip():
            raise RuntimeError("A server-only Supabase secret key is required")
        self._base_url = url.rstrip("/")
        self._headers = {
            "apikey": secret_key,
            "Content-Type": "application/json",
        }
        if not secret_key.startswith("sb_secret_"):
            self._headers["Authorization"] = f"Bearer {secret_key}"
        self._client = httpx.Client(timeout=timeout_seconds)

    def call_rpc(
        self,
        function_name: str,
        params: Mapping[str, Any],
        *,
        row_offset: int | None = None,
        row_limit: int | None = None,
    ) -> Any:
        stage = f"trusted_supabase_rpc:{function_name}"
        query_params = None
        if row_offset is not None or row_limit is not None:
            if row_offset is None or row_limit is None:
                raise ValueError("row_offset and row_limit must be provided together")
            if row_offset < 0 or row_limit <= 0:
                raise ValueError("RPC row pagination must be positive")
            query_params = {"offset": row_offset, "limit": row_limit}
            stage = f"{stage}:page_offset={row_offset}"
        try:
            response = self._client.post(
                f"{self._base_url}/rest/v1/rpc/{function_name}",
                headers=self._headers,
                params=query_params,
                json=dict(params),
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            error.data_stage = stage
            raise
        if response.status_code >= 400:
            message = _response_message(response)
            if "session is invalid or expired" in message.casefold():
                raise AuthenticationError("Session is invalid or expired")
            if "only admin accounts" in message.casefold():
                raise AuthorizationError(
                    "Recommendation tracking is restricted to Admin profiles"
                )
            if _is_conflict(message):
                raise RecommendationConflictError(_safe_business_message(message))
            if _is_validation_error(message):
                raise ValueError(_safe_business_message(message))
            raise DataUnavailableError(
                "Recommendation persistence data source is unavailable",
                stage=stage,
            )
        try:
            return response.json()
        except ValueError as error:
            raise DataUnavailableError(
                "Recommendation persistence returned invalid JSON",
                stage=stage,
            ) from error

    def call_rpc_rows(
        self,
        function_name: str,
        params: Mapping[str, Any],
    ) -> list[Mapping[str, object]]:
        rows: list[Mapping[str, object]] = []
        for page_number in range(self._RPC_MAX_PAGES):
            offset = page_number * self._RPC_PAGE_SIZE
            payload = self.call_rpc(
                function_name,
                params,
                row_offset=offset,
                row_limit=self._RPC_PAGE_SIZE,
            )
            if not isinstance(payload, list) or any(
                not isinstance(row, Mapping) for row in payload
            ):
                raise DataUnavailableError(
                    "Recommendation tracking returned an invalid row set",
                    stage=f"trusted_supabase_rpc:{function_name}:page_offset={offset}",
                )
            rows.extend(payload)
            if len(payload) < self._RPC_PAGE_SIZE:
                return rows
        raise DataUnavailableError(
            "Recommendation tracking exceeded the supported pagination limit",
            stage=f"trusted_supabase_rpc:{function_name}:pagination_limit",
        )


class SupabaseRecommendationPersistenceAdapter(RecommendationPersistenceAdapter):
    def __init__(self, settings: ApiSettings) -> None:
        if not settings.recommendation_persistence_enabled:
            raise RuntimeError("Recommendation persistence is not enabled")
        if settings.mode != "supabase" or settings.supabase_url is None:
            raise RuntimeError("Recommendation persistence requires Supabase mode")
        if settings.supabase_secret_key is None:
            raise RuntimeError("A server-only Supabase secret key is required")
        self._client = SupabaseSecretRestClient(
            url=settings.supabase_url,
            secret_key=settings.supabase_secret_key,
            timeout_seconds=settings.request_timeout_seconds,
        )

    def snapshot_by_request(
        self,
        *,
        session_token: str,
        request_id: UUID,
    ) -> Mapping[str, object] | None:
        payload = self._client.call_rpc(
            "forecast_recommendation_snapshot_by_request_v1",
            {
                "p_session_token": session_token,
                "p_request_id": str(request_id),
            },
        )
        if payload is None:
            return None
        if not isinstance(payload, Mapping):
            raise DataUnavailableError(
                "Recommendation snapshot lookup returned an invalid payload",
                stage="trusted_supabase_rpc:forecast_recommendation_snapshot_by_request_v1",
            )
        return payload

    def save_snapshot(
        self,
        *,
        session_token: str,
        request_id: UUID,
        snapshot: TrustedRecommendationSnapshot,
    ) -> Mapping[str, object]:
        payload = self._client.call_rpc(
            "save_forecast_recommendation_snapshot_v1",
            {
                "p_session_token": session_token,
                "p_request_id": str(request_id),
                "p_product_id": snapshot.product_id,
                "p_forecast_model": snapshot.forecast_model,
                "p_forecast_version": snapshot.forecast_version,
                "p_training_history_days": snapshot.training_history_days,
                "p_experimental_model": snapshot.experimental_model,
                "p_forecast_generated_at": snapshot.forecast_generated_at.isoformat(),
                "p_forecast_source_data_as_of": (
                    snapshot.forecast_source_data_as_of.isoformat()
                ),
                "p_planning_horizon_days": snapshot.planning_horizon_days,
                "p_forecast_period_start": snapshot.forecast_period_start.isoformat(),
                "p_forecast_period_end": snapshot.forecast_period_end.isoformat(),
                "p_predicted_demand": str(snapshot.predicted_demand),
                "p_available_inventory": str(snapshot.available_inventory),
                "p_inventory_unit": snapshot.inventory_unit,
                "p_assumptions": list(snapshot.assumptions),
            },
        )
        return _mapping_payload(payload, "save recommendation")

    def match_receipt(
        self,
        *,
        session_token: str,
        recommendation_id: int,
        transaction_history_id: UUID,
        allocated_inventory_quantity: Decimal,
    ) -> Mapping[str, object]:
        payload = self._client.call_rpc(
            "match_forecast_recommendation_receipt_v1",
            {
                "p_session_token": session_token,
                "p_recommendation_id": recommendation_id,
                "p_transaction_history_id": str(transaction_history_id),
                "p_allocated_inventory_quantity": str(
                    allocated_inventory_quantity
                ),
            },
        )
        return _mapping_payload(payload, "match receipt")

    def reconcile(
        self,
        *,
        session_token: str,
        request_id: UUID,
        recommendation_id: int,
        confirm_no_receipts: bool,
        confirmation_note: str | None,
    ) -> Mapping[str, object]:
        payload = self._client.call_rpc(
            "reconcile_forecast_recommendation_v1",
            {
                "p_session_token": session_token,
                "p_request_id": str(request_id),
                "p_recommendation_id": recommendation_id,
                "p_confirm_no_receipts": confirm_no_receipts,
                "p_confirmation_note": confirmation_note,
            },
        )
        return _mapping_payload(payload, "reconcile recommendation")

    def tracking(
        self,
        *,
        session_token: str,
        product_id: UUID | None,
    ) -> list[Mapping[str, object]]:
        payload = self._client.call_rpc_rows(
            "forecast_recommendation_tracking_v1",
            {
                "p_session_token": session_token,
                "p_product_id": str(product_id) if product_id is not None else None,
            },
        )
        return payload


def _mapping_payload(payload: Any, operation: str) -> Mapping[str, object]:
    if not isinstance(payload, Mapping):
        raise DataUnavailableError(
            f"Recommendation {operation} returned an invalid payload",
            stage=f"trusted_recommendation:{operation.replace(' ', '_')}",
        )
    return payload


def _response_message(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return ""
    if not isinstance(payload, Mapping):
        return ""
    return str(payload.get("message") or payload.get("error") or "").strip()


def _is_conflict(message: str) -> bool:
    normalized = message.casefold()
    return any(
        marker in normalized
        for marker in (
            "conflict",
            "already_reconciled",
            "over-allocation",
            "over_allocation",
            "allocation_exceeds",
            "inventory_snapshot_is_stale",
        )
    )


def _is_validation_error(message: str) -> bool:
    normalized = message.casefold()
    return any(
        marker in normalized
        for marker in (
            "invalid",
            "unapproved",
            "not_an_eligible",
            "unit_mismatch",
            "unit_cannot_be_verified",
            "not found",
            "outside the active location",
            "only admin",
            "explicit_zero_receipt",
        )
    )


def _safe_business_message(message: str) -> str:
    # Database errors in this proposal are fixed identifiers/messages and never
    # include credentials. Avoid returning arbitrary upstream detail.
    normalized = message.strip()
    return normalized if len(normalized) <= 240 else "Recommendation request rejected"

