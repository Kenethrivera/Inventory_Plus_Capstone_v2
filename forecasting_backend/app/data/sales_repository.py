from __future__ import annotations

from datetime import datetime
from typing import Any, Mapping, Protocol

from .models import DailyDemand
from .preprocessing import parse_rpc_daily_demand


class RpcResult(Protocol):
    @property
    def data(self) -> list[Mapping[str, Any]]: ...


class RpcRequest(Protocol):
    def execute(self) -> RpcResult: ...


class SupabaseRpcClient(Protocol):
    def rpc(self, function_name: str, params: Mapping[str, Any]) -> RpcRequest: ...


class SalesRepository:
    """Reads only authenticated, location-scoped aggregate sales history."""

    def __init__(self, client: SupabaseRpcClient, session_token: str) -> None:
        if not session_token.strip():
            raise ValueError("session_token is required")
        self._client = client
        self._session_token = session_token

    def daily_demand(
        self,
        *,
        period_start: datetime,
        period_end: datetime,
        business_timezone: str = "Asia/Manila",
    ) -> list[DailyDemand]:
        if period_start.tzinfo is None or period_end.tzinfo is None:
            raise ValueError("period bounds must include timezones")
        response = self._client.rpc(
            "forecast_daily_demand_v1",
            {
                "p_session_token": self._session_token,
                "p_period_start": period_start.isoformat(),
                "p_period_end": period_end.isoformat(),
                "p_business_timezone": business_timezone,
            },
        ).execute()
        return parse_rpc_daily_demand(response.data)

