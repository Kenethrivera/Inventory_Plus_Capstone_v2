from __future__ import annotations

from concurrent.futures import Future
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from threading import Lock
from time import monotonic
from typing import Any, Mapping
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx

from app.data import DailyDemand
from app.data.sales_repository import SalesRepository
from app.forecasting import (
    AvailabilityEvidence,
    AvailabilityStatus,
    ForecastProduct,
    HistoricalDemandDataset,
)
from app.recommendations import (
    InventoryBalanceBasis,
    InventorySnapshot,
    RecommendationPolicy,
    SafetyStockInput,
    SafetyStockSource,
    SupplierAvailability,
    SupplierPolicySnapshot,
    UnitConversion,
)

from .contracts import (
    AnalysisContext,
    AuthenticationError,
    DataUnavailableError,
    ProductNotFoundError,
    ReplenishmentConfiguration,
    ReplenishmentConfigurationInput,
    ReplenishmentConfigurationUnavailableError,
    SessionProfile,
)
from .settings import ApiSettings


class _RpcResponse:
    def __init__(self, data: Any) -> None:
        self.data = data


class _RpcRequest:
    def __init__(
        self, client: SupabaseRestClient, function_name: str, params: Mapping[str, Any]
    ) -> None:
        self._client = client
        self._function_name = function_name
        self._params = params

    def execute(self) -> _RpcResponse:
        return _RpcResponse(
            self._client.call_rpc_rows(self._function_name, self._params)
        )


class SupabaseRestClient:
    """Minimal publishable-key REST client; never uses a service-role key."""

    _RPC_PAGE_SIZE = 1000
    _RPC_MAX_PAGES = 100

    def __init__(self, *, url: str, publishable_key: str, timeout_seconds: float) -> None:
        self._base_url = url.rstrip("/")
        self._headers = {
            "apikey": publishable_key,
            "Authorization": f"Bearer {publishable_key}",
            "Content-Type": "application/json",
        }
        self._client = httpx.Client(timeout=timeout_seconds)

    def rpc(self, function_name: str, params: Mapping[str, Any]) -> _RpcRequest:
        return _RpcRequest(self, function_name, params)

    def call_rpc(
        self,
        function_name: str,
        params: Mapping[str, Any],
        *,
        authentication_rpc: bool = False,
        row_offset: int | None = None,
        row_limit: int | None = None,
    ) -> Any:
        data_stage = f"supabase_rpc:{function_name}"
        query_params = None
        if row_offset is not None or row_limit is not None:
            if row_offset is None or row_limit is None:
                raise ValueError("row_offset and row_limit must be provided together")
            if row_offset < 0 or row_limit <= 0:
                raise ValueError("RPC row pagination must be positive")
            query_params = {"offset": row_offset, "limit": row_limit}
            data_stage = f"{data_stage}:page_offset={row_offset}"
        try:
            response = self._client.post(
                f"{self._base_url}/rest/v1/rpc/{function_name}",
                headers=self._headers,
                params=query_params,
                json=dict(params),
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            error.data_stage = data_stage
            raise
        if response.status_code >= 400:
            message = self._error_message(response)
            if authentication_rpc or response.status_code in {401, 403}:
                raise AuthenticationError("Session is invalid or expired")
            if function_name in {
                "forecast_replenishment_config_v1",
                "upsert_forecast_replenishment_config_v1",
            } and self._is_missing_function(response, message):
                raise ReplenishmentConfigurationUnavailableError(
                    "Replenishment configuration is unavailable until "
                    "database/stage_5f_forecast_replenishment_configuration.sql "
                    "is approved and applied"
                )
            raise DataUnavailableError(message, stage=data_stage)
        return response.json()

    def call_rpc_rows(
        self,
        function_name: str,
        params: Mapping[str, Any],
    ) -> list[Mapping[str, Any]]:
        """Read every page from a deterministic set-returning RPC.

        Supabase/PostgREST caps a response at the project's maximum row count
        (1,000 in staging). The demand RPC is location-wide and can exceed that
        cap, so a single successful HTTP response is not necessarily complete.
        """
        rows: list[Mapping[str, Any]] = []
        for page_number in range(self._RPC_MAX_PAGES):
            page = self.call_rpc(
                function_name,
                params,
                row_offset=page_number * self._RPC_PAGE_SIZE,
                row_limit=self._RPC_PAGE_SIZE,
            )
            if not isinstance(page, list) or any(
                not isinstance(row, Mapping) for row in page
            ):
                raise DataUnavailableError(
                    f"{function_name} returned an invalid row set",
                    stage=(
                        f"supabase_rpc:{function_name}:"
                        f"page_offset={page_number * self._RPC_PAGE_SIZE}"
                    ),
                )
            rows.extend(page)
            if len(page) < self._RPC_PAGE_SIZE:
                return rows
        raise DataUnavailableError(
            f"{function_name} exceeded the supported pagination limit",
            stage=f"supabase_rpc:{function_name}:pagination_limit",
        )

    @staticmethod
    def _is_missing_function(response: httpx.Response, message: str) -> bool:
        try:
            payload = response.json()
        except ValueError:
            payload = {}
        code = str(payload.get("code") or "") if isinstance(payload, dict) else ""
        normalized = message.lower()
        return code == "PGRST202" or (
            "could not find the function" in normalized
            or "function" in normalized and "does not exist" in normalized
        )

    @staticmethod
    def _error_message(response: httpx.Response) -> str:
        try:
            payload = response.json()
            if isinstance(payload, dict):
                message = str(
                    payload.get("message") or payload.get("error") or ""
                ).strip()
                if message:
                    return message
        except ValueError:
            pass
        return f"Supabase request failed with HTTP {response.status_code}"


@dataclass(frozen=True)
class _DemandCacheKey:
    profile_id: str
    location_id: str
    period_start: datetime
    period_end: datetime
    business_timezone: str


@dataclass(frozen=True)
class _DemandCacheEntry:
    expires_at: float
    rows: tuple[DailyDemand, ...]


class SupabaseForecastAdapter:
    _DEMAND_CACHE_TTL_SECONDS = 60.0

    def __init__(self, settings: ApiSettings) -> None:
        assert settings.supabase_url is not None
        assert settings.supabase_publishable_key is not None
        self._settings = settings
        self._client = SupabaseRestClient(
            url=settings.supabase_url,
            publishable_key=settings.supabase_publishable_key,
            timeout_seconds=settings.request_timeout_seconds,
        )
        self._demand_cache_lock = Lock()
        self._demand_cache: dict[_DemandCacheKey, _DemandCacheEntry] = {}
        self._demand_inflight: dict[
            _DemandCacheKey, Future[tuple[DailyDemand, ...]]
        ] = {}

    def authenticate(self, session_token: str) -> SessionProfile:
        payload = self._client.call_rpc(
            "profile_restore_session_v1",
            {"p_session_token": session_token},
            authentication_rpc=True,
        )
        if not isinstance(payload, dict) or not isinstance(payload.get("profile"), dict):
            raise AuthenticationError("Session is invalid or expired")
        profile = payload["profile"]
        location_id = str(profile.get("location_id") or "").strip()
        role = str(profile.get("role") or "").strip().lower()
        profile_id = str(profile.get("id") or "").strip()
        if not location_id or not role or not profile_id:
            raise AuthenticationError("Session profile is incomplete")
        return SessionProfile(
            profile_id=profile_id,
            role=role,
            location_id=location_id,
            name=str(profile.get("name") or profile.get("username") or "User"),
        )

    def load_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
    ) -> ReplenishmentConfiguration:
        payload = self._client.call_rpc(
            "forecast_replenishment_config_v1",
            {
                "p_session_token": session_token,
                "p_product_id": product_id,
            },
        )
        if payload is None:
            raise ProductNotFoundError("Product was not found in the authorized location")
        return _parse_replenishment_configuration(
            payload,
            expected_product_id=product_id,
            expected_location_id=profile.location_id,
        )

    def save_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        configuration: ReplenishmentConfigurationInput,
    ) -> ReplenishmentConfiguration:
        payload = self._client.call_rpc(
            "upsert_forecast_replenishment_config_v1",
            {
                "p_session_token": session_token,
                "p_product_id": product_id,
                "p_supplier_lead_time_days": configuration.supplier_lead_time_days,
                "p_review_period_days": configuration.review_period_days,
                "p_safety_stock": _decimal_text(configuration.safety_stock),
                "p_minimum_order_quantity": _decimal_text(
                    configuration.minimum_order_quantity
                ),
                "p_supplier_pack_size": _decimal_text(
                    configuration.supplier_pack_size
                ),
                "p_supplier_order_unit": configuration.supplier_order_unit,
                "p_unit_conversion_factor": _decimal_text(
                    configuration.unit_conversion_factor
                ),
                "p_confirmed_incoming_quantity": _decimal_text(
                    configuration.confirmed_incoming_quantity
                ),
                "p_incoming_quantity_verified": (
                    configuration.incoming_quantity_verified
                ),
                "p_backorder_quantity": _decimal_text(
                    configuration.backorder_quantity
                ),
                "p_backorder_quantity_verified": (
                    configuration.backorder_quantity_verified
                ),
                "p_supplier_availability": configuration.supplier_availability,
                "p_data_source": configuration.data_source,
                "p_source_captured_at": configuration.source_captured_at.isoformat(),
                "p_rationale": configuration.rationale,
            },
        )
        return _parse_replenishment_configuration(
            payload,
            expected_product_id=product_id,
            expected_location_id=profile.location_id,
        )

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = 365,
    ) -> AnalysisContext:
        UUID(product_id)
        if isinstance(history_days, bool) or not isinstance(history_days, int):
            raise ValueError("history_days must be an integer")
        if not 28 <= history_days <= 1825:
            raise ValueError("history_days must be between 28 and 1825")
        product_payload = self._client.call_rpc(
            "forecast_product_context_v1",
            {
                "p_session_token": session_token,
                "p_product_id": product_id,
            },
        )
        product_row = (
            dict(product_payload) if isinstance(product_payload, dict) else None
        )
        if product_row is None:
            raise ProductNotFoundError("Product was not found in the authorized location")
        if str(product_row.get("id") or "").strip() != product_id:
            raise DataUnavailableError("Forecast product context has an invalid product")
        if str(product_row.get("location_id") or "").strip() != profile.location_id:
            raise DataUnavailableError("Forecast product context is outside the session location")
        if product_row.get("is_active") is not True:
            raise ProductNotFoundError("Product was not found in the authorized location")

        manila = ZoneInfo("Asia/Manila")
        local_now = now.astimezone(manila)
        period_end_date = local_now.date()
        period_start_date = period_end_date - timedelta(days=history_days)
        period_start = datetime.combine(period_start_date, time.min, manila)
        period_end = datetime.combine(period_end_date, time.min, manila)
        location_demand = self._load_location_demand(
            profile=profile,
            session_token=session_token,
            period_start=period_start,
            period_end=period_end,
            business_timezone="Asia/Manila",
        )
        if any(row.location_id != profile.location_id for row in location_demand):
            raise DataUnavailableError("Demand history is outside the session location")
        demand = [
            row
            for row in location_demand
            if row.product_id == product_id and row.location_id == profile.location_id
        ]
        unit = str(product_row.get("unit") or "").strip()
        product_name = str(product_row.get("product_name") or "").strip()
        if not unit or not product_name:
            raise DataUnavailableError("Forecast product identity is incomplete")
        item = ForecastProduct(
            location_id=profile.location_id,
            product_id=product_id,
            sku=str(product_row.get("sku") or "").strip() or None,
            product_name=product_name,
            unit=unit,
        )
        created_at = _parse_datetime(product_row.get("created_at"))
        history_start = (
            max(period_start_date, created_at.astimezone(manila).date())
            if demand
            else None
        )
        history = HistoricalDemandDataset.from_real_observations(
            product=item,
            history_start=history_start,
            history_end=period_end_date - timedelta(days=1),
            observations=demand,
        )
        try:
            configuration = self.load_replenishment_configuration(
                profile=profile,
                session_token=session_token,
                product_id=product_id,
            )
        except ReplenishmentConfigurationUnavailableError:
            configuration = ReplenishmentConfiguration(
                configured=False,
                product_id=product_id,
                location_id=profile.location_id,
                inventory_unit=unit,
                persistence_available=False,
            )
        if configuration.inventory_unit != unit:
            raise DataUnavailableError(
                "Replenishment configuration inventory unit does not match the product"
            )
        updated_at = _parse_datetime(product_row.get("updated_at"))
        configured_at = configuration.source_captured_at or now
        inventory_captured_at = (
            min(updated_at, configured_at)
            if configuration.configured
            and (
                configuration.incoming_quantity_verified
                or configuration.backorder_quantity_verified
            )
            else updated_at
        )
        inventory = InventorySnapshot(
            location_id=profile.location_id,
            product_id=product_id,
            unit=unit,
            saleable_on_hand=_decimal_or_none(product_row.get("product_quantity")),
            confirmed_on_order=(
                configuration.confirmed_incoming_quantity
                if configuration.incoming_quantity_verified
                else None
            ),
            unfulfilled_reservations=Decimal("0"),
            backorders=(
                configuration.backorder_quantity
                if configuration.backorder_quantity_verified
                else None
            ),
            max_capacity=_decimal_or_none(product_row.get("max_quantity")),
            balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
            captured_at=inventory_captured_at,
        )
        order_unit = configuration.supplier_order_unit or unit
        supplier = SupplierPolicySnapshot(
            supplier_id=("forecast-config" if configuration.configured else "unconfigured"),
            order_unit=order_unit,
            lead_time_days=configuration.supplier_lead_time_days,
            minimum_order_quantity=configuration.minimum_order_quantity,
            pack_size=configuration.supplier_pack_size,
            availability=SupplierAvailability(
                configuration.supplier_availability or "unknown"
            ),
            captured_at=configured_at,
        )
        safety = (
            SafetyStockInput(
                quantity=configuration.safety_stock,
                unit=unit,
                source=(
                    SafetyStockSource.EXPLICIT_ASSUMPTION
                    if configuration.data_source == "admin_estimate"
                    else SafetyStockSource.CONFIGURED
                ),
                captured_at=configured_at,
            )
            if configuration.safety_stock is not None
            else None
        )
        conversions = (
            (
                UnitConversion(
                    from_unit=order_unit,
                    to_unit=unit,
                    factor=configuration.unit_conversion_factor,
                ),
            )
            if order_unit.lower() != unit.lower()
            and configuration.unit_conversion_factor is not None
            else ()
        )
        policy = RecommendationPolicy(
            version=self._settings.policy_version,
            review_period_days=configuration.review_period_days,
            max_forecast_age=timedelta(hours=24),
            max_inventory_age=timedelta(days=7),
            max_supplier_age=timedelta(days=30),
            max_safety_stock_age=timedelta(days=30),
        )
        return AnalysisContext(
            history=history,
            inventory=inventory,
            supplier=supplier,
            safety_stock=safety,
            conversions=conversions,
            policy=policy,
            source_data_as_of=period_end,
            adapter_name="supabase",
            replenishment_configuration=configuration,
        )

    def load_daily_demand(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        period_start: datetime,
        period_end: datetime,
        business_timezone: str = "Asia/Manila",
    ) -> tuple[DailyDemand, ...]:
        """Read the complete authenticated location aggregate for one window."""
        if period_start.tzinfo is None or period_end.tzinfo is None:
            raise ValueError("period bounds must include timezones")
        if period_end <= period_start:
            raise ValueError("demand-history period is invalid")
        rows = self._load_location_demand(
            profile=profile,
            session_token=session_token,
            period_start=period_start,
            period_end=period_end,
            business_timezone=business_timezone,
        )
        if any(row.location_id != profile.location_id for row in rows):
            raise DataUnavailableError("Demand history is outside the session location")
        return rows

    def _load_location_demand(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        period_start: datetime,
        period_end: datetime,
        business_timezone: str,
    ) -> tuple[DailyDemand, ...]:
        """Coalesce identical location-wide RPC reads across product analyses.

        The demand RPC returns every product for the authenticated location.
        A short cache lets one overview request reuse that canonical snapshot
        instead of downloading the same paginated rows once per product.
        Authentication still runs for every API request, and the key contains
        only non-secret profile/location/window identifiers.
        """

        key = _DemandCacheKey(
            profile_id=profile.profile_id,
            location_id=profile.location_id,
            period_start=period_start,
            period_end=period_end,
            business_timezone=business_timezone,
        )
        now_tick = monotonic()
        is_loader = False
        with self._demand_cache_lock:
            expired = [
                cached_key
                for cached_key, entry in self._demand_cache.items()
                if entry.expires_at <= now_tick
            ]
            for cached_key in expired:
                self._demand_cache.pop(cached_key, None)

            cached = self._demand_cache.get(key)
            if cached is not None:
                return cached.rows

            pending = self._demand_inflight.get(key)
            if pending is None:
                pending = Future()
                self._demand_inflight[key] = pending
                is_loader = True

        if not is_loader:
            return pending.result()

        try:
            rows = tuple(
                SalesRepository(self._client, session_token).daily_demand(
                    period_start=period_start,
                    period_end=period_end,
                    business_timezone=business_timezone,
                )
            )
        except BaseException as error:
            with self._demand_cache_lock:
                self._demand_inflight.pop(key, None)
                pending.set_exception(error)
            raise

        with self._demand_cache_lock:
            self._demand_cache[key] = _DemandCacheEntry(
                expires_at=monotonic() + self._DEMAND_CACHE_TTL_SECONDS,
                rows=rows,
            )
            self._demand_inflight.pop(key, None)
            pending.set_result(rows)
        return rows

class SyntheticDevelopmentAdapter:
    """In-memory adapter for isolated development; never writes to Supabase."""

    LOCATION_ID = "11111111-1111-4111-8111-111111111111"
    PRODUCT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    COLD_START_PRODUCT_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    def __init__(self, settings: ApiSettings) -> None:
        if not settings.synthetic_mode_enabled or settings.deployment_environment not in {
            "development",
            "test",
        }:
            raise RuntimeError(
                "Synthetic development adapter is disabled outside development/test"
            )
        if not settings.synthetic_session_token.strip():
            raise RuntimeError("Synthetic development session token is required")
        self._settings = settings
        self._saved_configurations: dict[str, ReplenishmentConfiguration] = {}

    def authenticate(self, session_token: str) -> SessionProfile:
        if session_token != self._settings.synthetic_session_token:
            raise AuthenticationError("Synthetic development session is invalid")
        return SessionProfile(
            profile_id="synthetic-admin",
            role="admin",
            location_id=self.LOCATION_ID,
            name="Synthetic Development Admin",
        )

    def load_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
    ) -> ReplenishmentConfiguration:
        if session_token != self._settings.synthetic_session_token:
            raise AuthenticationError("Synthetic development session is invalid")
        if product_id not in {
            self.PRODUCT_ID,
            self.COLD_START_PRODUCT_ID,
        } or profile.location_id != self.LOCATION_ID:
            raise ProductNotFoundError("Synthetic fixture product was not found")
        saved = self._saved_configurations.get(product_id)
        if saved is not None:
            return saved
        if product_id == self.COLD_START_PRODUCT_ID:
            return ReplenishmentConfiguration(
                configured=False,
                product_id=product_id,
                location_id=self.LOCATION_ID,
                inventory_unit="pcs",
            )
        captured_at = datetime.now(timezone.utc)
        return ReplenishmentConfiguration(
            configured=True,
            product_id=self.PRODUCT_ID,
            location_id=self.LOCATION_ID,
            inventory_unit="pcs",
            supplier_lead_time_days=5,
            review_period_days=self._settings.review_period_days,
            safety_stock=Decimal("20"),
            minimum_order_quantity=Decimal("12"),
            supplier_pack_size=Decimal("6"),
            supplier_order_unit="pcs",
            confirmed_incoming_quantity=Decimal("0"),
            incoming_quantity_verified=True,
            backorder_quantity=Decimal("0"),
            backorder_quantity_verified=True,
            supplier_availability="available",
            data_source="admin_estimate",
            source_captured_at=captured_at,
            rationale="Synthetic development fixture",
            updated_at=captured_at,
            updated_by_profile_id=profile.profile_id,
        )

    def save_replenishment_configuration(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        configuration: ReplenishmentConfigurationInput,
    ) -> ReplenishmentConfiguration:
        self.load_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
        )
        saved = ReplenishmentConfiguration(
            configured=True,
            product_id=product_id,
            location_id=profile.location_id,
            inventory_unit="pcs",
            supplier_lead_time_days=configuration.supplier_lead_time_days,
            review_period_days=configuration.review_period_days,
            safety_stock=configuration.safety_stock,
            minimum_order_quantity=configuration.minimum_order_quantity,
            supplier_pack_size=configuration.supplier_pack_size,
            supplier_order_unit=configuration.supplier_order_unit,
            unit_conversion_factor=configuration.unit_conversion_factor,
            confirmed_incoming_quantity=configuration.confirmed_incoming_quantity,
            incoming_quantity_verified=configuration.incoming_quantity_verified,
            backorder_quantity=configuration.backorder_quantity,
            backorder_quantity_verified=configuration.backorder_quantity_verified,
            supplier_availability=configuration.supplier_availability,
            data_source=configuration.data_source,
            source_captured_at=configuration.source_captured_at,
            rationale=configuration.rationale,
            updated_at=datetime.now(timezone.utc),
            updated_by_profile_id=profile.profile_id,
        )
        self._saved_configurations[product_id] = saved
        return saved

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = 365,
    ) -> AnalysisContext:
        if isinstance(history_days, bool) or not isinstance(history_days, int):
            raise ValueError("history_days must be an integer")
        if not 28 <= history_days <= 1825:
            raise ValueError("history_days must be between 28 and 1825")
        if product_id not in {
            self.PRODUCT_ID,
            self.COLD_START_PRODUCT_ID,
        } or profile.location_id != self.LOCATION_ID:
            raise ProductNotFoundError("Synthetic fixture product was not found")
        history_end = now.date() - timedelta(days=1)
        is_cold_start = product_id == self.COLD_START_PRODUCT_ID
        history_start = None if is_cold_start else history_end - timedelta(days=223)
        observations: list[DailyDemand] = []
        availability: list[AvailabilityEvidence] = []
        for index in range(0 if is_cold_start else 224):
            assert history_start is not None
            business_date = history_start + timedelta(days=index)
            quantity = Decimal(8 + (index % 7) * 2 + index // 56)
            observations.append(
                DailyDemand(
                    business_date=business_date,
                    location_id=self.LOCATION_ID,
                    product_id=product_id,
                    sku="SYNTH-001",
                    product_name="Synthetic development fixture",
                    unit="pcs",
                    quantity=quantity,
                    completed_order_count=1,
                )
            )
            availability.append(
                AvailabilityEvidence(
                    business_date=business_date,
                    status=AvailabilityStatus.IN_STOCK,
                )
            )
        item = ForecastProduct(
            location_id=self.LOCATION_ID,
            product_id=product_id,
            sku="SYNTH-COLD" if is_cold_start else "SYNTH-001",
            product_name=(
                "Synthetic cold-start fixture"
                if is_cold_start
                else "Synthetic development fixture"
            ),
            unit="pcs",
        )
        history = HistoricalDemandDataset.from_synthetic_observations(
            product=item,
            history_start=history_start,
            history_end=history_end,
            observations=observations,
            availability_evidence=availability,
        )
        inventory = InventorySnapshot(
            location_id=self.LOCATION_ID,
            product_id=product_id,
            unit="pcs",
            saleable_on_hand=Decimal("10") if is_cold_start else Decimal("100"),
            confirmed_on_order=None if is_cold_start else Decimal("0"),
            unfulfilled_reservations=Decimal("0"),
            backorders=None if is_cold_start else Decimal("0"),
            max_capacity=Decimal("500"),
            balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
            captured_at=now,
        )
        supplier = SupplierPolicySnapshot(
            supplier_id="synthetic-supplier",
            order_unit="pcs",
            lead_time_days=None if is_cold_start else 5,
            minimum_order_quantity=None if is_cold_start else Decimal("12"),
            pack_size=None if is_cold_start else Decimal("6"),
            availability=(
                SupplierAvailability.UNKNOWN
                if is_cold_start
                else SupplierAvailability.AVAILABLE
            ),
            captured_at=now,
        )
        safety = (
            None
            if is_cold_start
            else SafetyStockInput(
                quantity=Decimal("20"),
                unit="pcs",
                source=SafetyStockSource.EXPLICIT_ASSUMPTION,
                captured_at=now,
            )
        )
        configuration = self.load_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
        )
        conversions: tuple[UnitConversion, ...] = ()
        if product_id in self._saved_configurations:
            captured_at = configuration.source_captured_at or now
            order_unit = configuration.supplier_order_unit or "pcs"
            inventory = replace(
                inventory,
                confirmed_on_order=(
                    configuration.confirmed_incoming_quantity
                    if configuration.incoming_quantity_verified
                    else None
                ),
                backorders=(
                    configuration.backorder_quantity
                    if configuration.backorder_quantity_verified
                    else None
                ),
                captured_at=captured_at,
            )
            supplier = SupplierPolicySnapshot(
                supplier_id="forecast-config",
                order_unit=order_unit,
                lead_time_days=configuration.supplier_lead_time_days,
                minimum_order_quantity=configuration.minimum_order_quantity,
                pack_size=configuration.supplier_pack_size,
                availability=SupplierAvailability(
                    configuration.supplier_availability or "unknown"
                ),
                captured_at=captured_at,
            )
            safety = (
                SafetyStockInput(
                    quantity=configuration.safety_stock,
                    unit="pcs",
                    source=(
                        SafetyStockSource.EXPLICIT_ASSUMPTION
                        if configuration.data_source == "admin_estimate"
                        else SafetyStockSource.CONFIGURED
                    ),
                    captured_at=captured_at,
                )
                if configuration.safety_stock is not None
                else None
            )
            if (
                order_unit.lower() != "pcs"
                and configuration.unit_conversion_factor is not None
            ):
                conversions = (
                    UnitConversion(
                        from_unit=order_unit,
                        to_unit="pcs",
                        factor=configuration.unit_conversion_factor,
                    ),
                )
        policy = RecommendationPolicy(
            version=f"{self._settings.policy_version}-synthetic",
            review_period_days=configuration.review_period_days,
            max_forecast_age=timedelta(hours=24),
            max_inventory_age=timedelta(hours=24),
            max_supplier_age=timedelta(hours=24),
            max_safety_stock_age=timedelta(hours=24),
        )
        return AnalysisContext(
            history=history,
            inventory=inventory,
            supplier=supplier,
            safety_stock=safety,
            conversions=conversions,
            policy=policy,
            source_data_as_of=now,
            adapter_name="synthetic_development",
            replenishment_configuration=configuration,
        )

    def load_daily_demand(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        period_start: datetime,
        period_end: datetime,
        business_timezone: str = "Asia/Manila",
    ) -> tuple[DailyDemand, ...]:
        if business_timezone != "Asia/Manila":
            raise ValueError("Synthetic fixture supports Asia/Manila only")
        if period_start.tzinfo is None or period_end.tzinfo is None:
            raise ValueError("period bounds must include timezones")
        if period_end <= period_start:
            raise ValueError("demand-history period is invalid")
        if profile.location_id != self.LOCATION_ID:
            raise DataUnavailableError("Synthetic fixture location is not authorized")
        self.authenticate(session_token)
        history_days = max(
            28, min((period_end.date() - period_start.date()).days, 1825)
        )
        context = self.load_analysis_context(
            profile=profile,
            session_token=session_token,
            product_id=self.PRODUCT_ID,
            now=period_end,
            history_days=history_days,
        )
        return tuple(
            row
            for row in context.history.observations
            if period_start.date() <= row.business_date < period_end.date()
        )


def _parse_datetime(value: Any) -> datetime:
    text = str(value or "").strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise DataUnavailableError("Product timestamp is unavailable or invalid") from error
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


def _decimal_or_none(value: Any) -> Decimal | None:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except Exception:
        return None


def _decimal_text(value: Decimal | None) -> str | None:
    return None if value is None else str(value)


def _parse_replenishment_configuration(
    payload: Any,
    *,
    expected_product_id: str,
    expected_location_id: str,
) -> ReplenishmentConfiguration:
    if not isinstance(payload, Mapping):
        raise DataUnavailableError("Forecast replenishment configuration is invalid")
    product_id = str(payload.get("product_id") or "").strip()
    location_id = str(payload.get("location_id") or "").strip()
    inventory_unit = str(payload.get("inventory_unit") or "").strip()
    if product_id != expected_product_id or location_id != expected_location_id:
        raise DataUnavailableError(
            "Forecast replenishment configuration is outside the authorized scope"
        )
    if not inventory_unit:
        raise DataUnavailableError("Forecast replenishment inventory unit is missing")

    def decimal_field(name: str) -> Decimal | None:
        value = payload.get(name)
        if value is None:
            return None
        try:
            parsed = Decimal(str(value))
        except Exception as error:
            raise DataUnavailableError(
                f"Forecast replenishment {name} is invalid"
            ) from error
        if not parsed.is_finite():
            raise DataUnavailableError(f"Forecast replenishment {name} is invalid")
        return parsed

    def integer_field(name: str) -> int | None:
        value = payload.get(name)
        if value is None:
            return None
        if isinstance(value, bool):
            raise DataUnavailableError(f"Forecast replenishment {name} is invalid")
        try:
            parsed = int(value)
        except (TypeError, ValueError) as error:
            raise DataUnavailableError(
                f"Forecast replenishment {name} is invalid"
            ) from error
        if str(parsed) != str(value).strip():
            raise DataUnavailableError(f"Forecast replenishment {name} is invalid")
        return parsed

    configured = payload.get("configured") is True
    incoming_verified = payload.get("incoming_quantity_verified") is True
    backorder_verified = payload.get("backorder_quantity_verified") is True
    incoming = decimal_field("confirmed_incoming_quantity")
    backorders = decimal_field("backorder_quantity")
    if incoming_verified != (incoming is not None):
        raise DataUnavailableError("Forecast incoming verification is inconsistent")
    if backorder_verified != (backorders is not None):
        raise DataUnavailableError("Forecast backorder verification is inconsistent")
    availability = str(payload.get("supplier_availability") or "").strip().lower() or None
    if availability not in {None, "available", "unavailable", "unknown"}:
        raise DataUnavailableError("Forecast supplier availability is invalid")
    source = str(payload.get("data_source") or "").strip().lower() or None
    if source not in {None, "admin_estimate", "verified_record"}:
        raise DataUnavailableError("Forecast replenishment data source is invalid")
    source_captured_at = _optional_datetime(payload.get("source_captured_at"))
    updated_at = _optional_datetime(payload.get("updated_at"))
    if configured and (source is None or source_captured_at is None or updated_at is None):
        raise DataUnavailableError("Forecast replenishment metadata is incomplete")
    return ReplenishmentConfiguration(
        configured=configured,
        product_id=product_id,
        location_id=location_id,
        inventory_unit=inventory_unit,
        supplier_lead_time_days=integer_field("supplier_lead_time_days"),
        review_period_days=integer_field("review_period_days"),
        safety_stock=decimal_field("safety_stock"),
        minimum_order_quantity=decimal_field("minimum_order_quantity"),
        supplier_pack_size=decimal_field("supplier_pack_size"),
        supplier_order_unit=(
            str(payload.get("supplier_order_unit") or "").strip() or None
        ),
        unit_conversion_factor=decimal_field("unit_conversion_factor"),
        confirmed_incoming_quantity=incoming,
        incoming_quantity_verified=incoming_verified,
        backorder_quantity=backorders,
        backorder_quantity_verified=backorder_verified,
        supplier_availability=availability,
        data_source=source,
        source_captured_at=source_captured_at,
        rationale=str(payload.get("rationale") or "").strip() or None,
        updated_at=updated_at,
        updated_by_profile_id=(
            str(payload.get("updated_by_profile_id") or "").strip() or None
        ),
    )


def _optional_datetime(value: Any) -> datetime | None:
    if value is None or not str(value).strip():
        return None
    return _parse_datetime(value)
