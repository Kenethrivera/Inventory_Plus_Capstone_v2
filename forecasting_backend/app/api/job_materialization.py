from __future__ import annotations

import hashlib
import importlib.metadata
import inspect
import json
import platform
import re
from dataclasses import asdict, dataclass, is_dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx

from app.api.adapters import SupabaseForecastAdapter
from app.api.contracts import (
    AnalysisContext,
    DataUnavailableError,
    ProductNotFoundError,
    SessionProfile,
)
from app.api.service import ForecastAnalysisService
from app.data.models import DailyDemand
from app.data.validation import DemandDataError
from app.forecasting import (
    CalibratedBlendForecaster,
    HistoricalDemandDataset,
    LightGBMForecaster,
    Mean28Forecaster,
    ProductSpecificSeasonalLightGBMForecaster,
    RollingOriginBacktester,
)
from app.forecasting.execution import DemandForecastExecutor
from app.forecasting.series import prepare_history
from app.performance_diagnostics import log_event, log_duration, start_timer
from app.seasonality import PhilippineSeasonResolver


BUSINESS_TIMEZONE = "Asia/Manila"
MANILA = ZoneInfo(BUSINESS_TIMEZONE)
DEFAULT_MODEL = "blend"
DEFAULT_HORIZON_DAYS = 28
DEFAULT_HISTORY_DAYS = 365
MAX_MAINTENANCE_BATCH = 25


class ForecastProductCatalog(Protocol):
    def list_active_products(
        self, *, profile: SessionProfile, session_token: str
    ) -> tuple[str, ...]: ...

    def load_analysis_context(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        product_id: str,
        now: datetime,
        history_days: int = DEFAULT_HISTORY_DAYS,
    ) -> AnalysisContext: ...


class ForecastJobRepository(Protocol):
    def initialize_revisions(
        self, *, location_id: str, product_ids: Sequence[str]
    ) -> Mapping[str, Mapping[str, int]]: ...

    def enqueue_jobs(
        self, *, location_id: str, jobs: Sequence[Mapping[str, object]]
    ) -> Sequence[Mapping[str, object]]: ...


@dataclass(frozen=True)
class ForecastModelIdentity:
    model_key: str
    model_version: str
    config_digest: str
    implementation_digest: str


@dataclass(frozen=True)
class MaterializationReport:
    business_date: date
    active_products: int
    prepared: int
    queued: int
    duplicate: int
    stale: int
    skipped: int
    jobs: tuple[Mapping[str, object], ...] = ()


def _canonical_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("forecast input contains a non-finite decimal")
        return format(value.normalize(), "f") if value else "0"
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if hasattr(value, "value") and isinstance(value.value, str):
        return value.value
    if is_dataclass(value):
        return _canonical_value(asdict(value))
    if isinstance(value, Mapping):
        return {str(key): _canonical_value(item) for key, item in sorted(value.items())}
    if isinstance(value, (tuple, list)):
        return [_canonical_value(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"unsupported canonical forecast input value: {type(value).__name__}")


def _sha256_json(value: Any) -> str:
    canonical = json.dumps(
        _canonical_value(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def canonical_history_input(
    history: HistoricalDemandDataset,
    *,
    source_data_as_of: datetime | None = None,
) -> dict[str, object]:
    observations = sorted(
        history.observations,
        key=lambda item: (
            item.business_date,
            item.location_id,
            item.product_id,
            item.unit,
        ),
    )
    availability = sorted(
        history.availability_evidence,
        key=lambda item: (item.business_date, item.status.value),
    )
    return {
        "schema": "inventory-plus-demand-input-v1",
        "location_id": history.product.location_id,
        "product_id": history.product.product_id,
        "product_name": history.product.product_name,
        "sku": history.product.sku,
        "unit": history.product.unit,
        "history_start": history.history_start,
        "history_end": history.history_end,
        "source_data_as_of": source_data_as_of,
        "provenance": history.provenance.value,
        "dataset_role": history.role.value,
        "observations": [
            {
                "business_date": row.business_date,
                "location_id": row.location_id,
                "product_id": row.product_id,
                "product_name": row.product_name,
                "sku": row.sku,
                "unit": row.unit,
                "quantity": row.quantity,
                "completed_order_count": row.completed_order_count,
            }
            for row in observations
        ],
        "availability_evidence": [
            {"business_date": item.business_date, "status": item.status.value}
            for item in availability
        ],
    }


def demand_input_digest(
    history: HistoricalDemandDataset,
    *,
    source_data_as_of: datetime | None = None,
) -> str:
    return _sha256_json(
        canonical_history_input(history, source_data_as_of=source_data_as_of)
    )


def _implementation_digest() -> str:
    source_objects = (
        ForecastAnalysisService,
        ForecastJobMaterializer,
        SupabaseForecastAdapter,
        DemandForecastExecutor,
        CalibratedBlendForecaster,
        LightGBMForecaster,
        Mean28Forecaster,
        ProductSpecificSeasonalLightGBMForecaster,
        PhilippineSeasonResolver,
        RollingOriginBacktester,
        prepare_history,
        HistoricalDemandDataset,
        DailyDemand,
        DemandDataError,
        canonical_history_input,
        demand_input_digest,
    )
    paths = {Path(inspect.getsourcefile(item) or "").resolve() for item in source_objects}
    root = Path(__file__).resolve().parents[2]
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: item.as_posix()):
        if not path.is_file():
            raise RuntimeError("forecast implementation source is unavailable")
        try:
            relative = path.relative_to(root).as_posix()
        except ValueError as error:
            raise RuntimeError("forecast source is outside the application package") from error
        content = path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    runtime = {
        "python": platform.python_version(),
        "lightgbm": importlib.metadata.version("lightgbm"),
        "numpy": importlib.metadata.version("numpy"),
        "scikit-learn": importlib.metadata.version("scikit-learn"),
    }
    digest.update(json.dumps(runtime, sort_keys=True, separators=(",", ":")).encode())
    return digest.hexdigest()


def forecast_model_identity(service: ForecastAnalysisService, model_key: str = DEFAULT_MODEL) -> ForecastModelIdentity:
    if model_key == "calibrated_blend":
        model_key = "blend"
    if model_key not in {"mean28", "lightgbm", "blend", "seasonal_experimental"}:
        raise ValueError("Unsupported requested forecast model")
    if model_key != "blend":
        history_days = 1095 if model_key == "seasonal_experimental" else DEFAULT_HISTORY_DAYS
        version = {
            "mean28": service._mean28.MODEL_VERSION,
            "lightgbm": service._lightgbm.MODEL_VERSION,
            "seasonal_experimental": service._seasonal_experimental.MODEL_VERSION,
        }[model_key]
        manifest = {
            "schema": "inventory-plus-model-config-v1",
            "requested_model": model_key,
            "requested_model_version": version,
            "horizon_days": DEFAULT_HORIZON_DAYS,
            "history_window_days": history_days,
            "business_timezone": BUSINESS_TIMEZONE,
            "blend": asdict(service._blend.config),
            "lightgbm": asdict(service._lightgbm.config),
            "mean28_lookback_days": service._mean28.LOOKBACK_DAYS,
            "seasonal_experimental": {
                "config": asdict(service._seasonal_experimental.config),
                "include_seasonal_features": service._seasonal_experimental.include_seasonal_features,
                "zero_never_sold_forecasts": service._seasonal_experimental.zero_never_sold_forecasts,
                "calendar_version": service._seasonal_experimental.resolver.CALENDAR_VERSION,
            },
            "executor_auxiliary_outputs": {
                "recommendation_role": "requested_forecasts_for_nonseasonal_models",
                "seasonal_recommendation_model": "lightgbm",
                "preliminary_model": "lightgbm",
                "preliminary_horizon_days": 28,
            },
        }
        return ForecastModelIdentity(model_key, version, _sha256_json(manifest), _implementation_digest())
    blend = service._blend
    lightgbm = service._lightgbm
    mean28 = service._mean28
    manifest = {
        "schema": "inventory-plus-model-config-v1",
        "requested_model": DEFAULT_MODEL,
        "requested_model_version": blend.MODEL_VERSION,
        "horizon_days": DEFAULT_HORIZON_DAYS,
        "history_window_days": DEFAULT_HISTORY_DAYS,
        "business_timezone": BUSINESS_TIMEZONE,
        "blend": asdict(blend.config),
        "lightgbm": asdict(lightgbm.config),
        "mean28_lookback_days": mean28.LOOKBACK_DAYS,
        "executor_auxiliary_outputs": {
            "recommendation_role": "requested_forecasts_for_blend",
            "preliminary_role_model": "lightgbm",
            "preliminary_horizon_days": DEFAULT_HORIZON_DAYS,
        },
    }
    return ForecastModelIdentity(
        model_key=DEFAULT_MODEL,
        model_version=blend.MODEL_VERSION,
        config_digest=_sha256_json(manifest),
        implementation_digest=_implementation_digest(),
    )


def _stable_idempotency_key(identity: Mapping[str, object]) -> str:
    raw = bytearray(hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x50
    raw[8] = (raw[8] & 0x3F) | 0x80
    return str(UUID(bytes=bytes(raw)))


def _product_diagnostic_ref(product_id: str) -> str:
    return hashlib.sha256(product_id.encode("utf-8")).hexdigest()[:12]


_RPC_DIAGNOSTIC_REDACTIONS = (
    (re.compile(r"(?i)\bBearer\s+\S+"), "Bearer [REDACTED]"),
    (re.compile(r"\bsb_(?:secret|publishable)_[A-Za-z0-9_-]+\b"), "[REDACTED_KEY]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"), "[REDACTED_TOKEN]"),
    (re.compile(r"https?://\S+", re.IGNORECASE), "[REDACTED_URL]"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}\b"), "[REDACTED_ID]"),
    (re.compile(r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"), "[REDACTED_EMAIL]"),
    (re.compile(r"(?i)failing row contains\s*\(.*"), "failing row contains [REDACTED_ROW]"),
    (re.compile(r"(['\"])[^'\"]{1,500}\1"), "'[REDACTED_VALUE]'"),
)


def _safe_rpc_diagnostic_text(value: object, *, limit: int = 240) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    safe_value = value.replace("\r", " ").replace("\n", " ")
    for pattern, replacement in _RPC_DIAGNOSTIC_REDACTIONS:
        safe_value = pattern.sub(replacement, safe_value)
    return safe_value[:limit]


def _safe_rpc_error_fields(response: httpx.Response) -> dict[str, str]:
    """Extract bounded, redacted PostgREST diagnostics without logging its body."""
    json_reader = getattr(response, "json", None)
    if not callable(json_reader):
        return {}
    try:
        payload = json_reader()
    except (ValueError, TypeError):
        return {}
    if not isinstance(payload, Mapping):
        return {}

    fields: dict[str, str] = {}
    error_code = _safe_rpc_diagnostic_text(payload.get("code"), limit=32)
    if error_code:
        fields["error_code"] = error_code
        if re.fullmatch(r"[0-9A-Z]{5}", error_code):
            fields["sqlstate"] = error_code
    for source, target, limit in (
        ("message", "error_message", 240),
        ("details", "error_details", 180),
        ("hint", "error_hint", 180),
    ):
        value = _safe_rpc_diagnostic_text(payload.get(source), limit=limit)
        if value:
            fields[target] = value
    return fields


class ForecastJobMaterializer:
    """Build queue identities from real scoped inputs; it never fits a model."""

    def __init__(
        self,
        *,
        catalog: ForecastProductCatalog,
        repository: ForecastJobRepository,
        service: ForecastAnalysisService,
    ) -> None:
        self._catalog = catalog
        self._repository = repository
        self._identities = {key: forecast_model_identity(service, key) for key in ("blend", "mean28", "lightgbm", "seasonal_experimental")}
        self._identity = self._identities["blend"]

    def bootstrap(
        self,
        *,
        profile: SessionProfile,
        session_token: str,
        now: datetime,
        product_id: str | None = None,
        product_ids: Sequence[str] | None = None,
        model_key: str = DEFAULT_MODEL,
    ) -> MaterializationReport:
        if model_key == "calibrated_blend":
            model_key = "blend"
        identity = self._identities.get(model_key)
        if identity is None:
            raise ValueError("Unsupported requested forecast model")
        history_days = 1095 if model_key == "seasonal_experimental" else DEFAULT_HISTORY_DAYS
        if profile.role != "admin":
            raise PermissionError("Forecast job bootstrap is restricted to Admin profiles")
        if now.tzinfo is None:
            raise ValueError("bootstrap time must include a timezone")
        business_date = now.astimezone(MANILA).date()
        as_of_at = datetime.combine(business_date, time.min, MANILA)
        active_product_ids = self._catalog.list_active_products(
            profile=profile, session_token=session_token
        )
        if product_id is not None and product_ids is not None:
            raise ValueError("Select either one product or a bounded product batch")
        if product_ids is not None:
            selected = tuple(dict.fromkeys(product_ids))
            if not selected or len(selected) > MAX_MAINTENANCE_BATCH:
                raise ValueError("Product batch must contain 1 to 25 products")
            if any(item not in active_product_ids for item in selected):
                raise ProductNotFoundError(
                    "Active product was not found in the authorized location"
                )
            product_ids = selected
        elif product_id is not None:
            try:
                UUID(product_id)
            except ValueError as error:
                raise ValueError("product_id must be a UUID") from error
            if product_id not in active_product_ids:
                raise ProductNotFoundError(
                    "Active product was not found in the authorized location"
                )
            product_ids = (product_id,)
        else:
            product_ids = active_product_ids
        revisions = self._repository.initialize_revisions(
            location_id=profile.location_id, product_ids=product_ids
        )

        jobs: list[dict[str, object]] = []
        skipped = 0
        for product_id in sorted(set(product_ids)):
            revision = revisions.get(product_id)
            if revision is None:
                log_event(
                    "forecast_materialization.product_skipped",
                    product_ref=_product_diagnostic_ref(product_id),
                    stage="revision_lookup",
                    reason_code="revision_missing",
                )
                skipped += 1
                continue
            stage = "frozen_context_load"
            skip_reason: str | None = None
            try:
                context = self._catalog.load_analysis_context(
                    profile=profile,
                    session_token=session_token,
                    product_id=product_id,
                    now=as_of_at,
                    history_days=history_days,
                )
                history = context.history
                stage = "input_scope_validation"
                if history.product.location_id != profile.location_id:
                    skip_reason = "location_mismatch"
                    raise DataUnavailableError("Frozen forecast inputs failed scope/date validation")
                if history.product.product_id != product_id:
                    skip_reason = "product_mismatch"
                    raise DataUnavailableError("Frozen forecast inputs failed scope/date validation")
                if history.provenance.value != "real":
                    skip_reason = "non_real_provenance"
                    raise DataUnavailableError("Frozen forecast inputs failed scope/date validation")
                if history.history_end != business_date - timedelta(days=1):
                    skip_reason = "history_end_mismatch"
                    raise DataUnavailableError("Frozen forecast inputs failed scope/date validation")
                stage = "history_validation"
                prepare_history(history)
                stage = "input_digest"
                input_digest = demand_input_digest(
                    history, source_data_as_of=context.source_data_as_of
                )
                stage = "job_identity"
                identity_fields: dict[str, object] = {
                    "location_id": profile.location_id,
                    "product_id": product_id,
                    "requested_model_key": identity.model_key,
                    "requested_model_version": identity.model_version,
                    "requested_model_config_digest": identity.config_digest,
                    "requested_implementation_digest": identity.implementation_digest,
                    "horizon_days": DEFAULT_HORIZON_DAYS,
                    "history_window_days": history_days,
                    "as_of_business_date": business_date.isoformat(),
                    "as_of_at": as_of_at.astimezone(timezone.utc).isoformat(),
                    "sales_revision": int(revision["sales_revision"]),
                    "product_revision": int(revision["product_revision"]),
                    "request_input_digest": input_digest,
                }
                jobs.append(
                    {
                        **identity_fields,
                        "idempotency_key": _stable_idempotency_key(identity_fields),
                    }
                )
            except (ValueError, DemandDataError, DataUnavailableError, ProductNotFoundError) as error:
                if skip_reason is not None:
                    reason_code = skip_reason
                elif isinstance(error, ProductNotFoundError):
                    reason_code = "product_unavailable"
                elif isinstance(error, DemandDataError):
                    reason_code = "invalid_demand_history"
                elif isinstance(error, DataUnavailableError):
                    reason_code = "frozen_input_unavailable"
                else:
                    reason_code = "invalid_forecast_input"
                log_event(
                    "forecast_materialization.product_skipped",
                    product_ref=_product_diagnostic_ref(product_id),
                    stage=stage,
                    reason_code=reason_code,
                    category=type(error).__name__,
                )
                skipped += 1

        outcomes = self._repository.enqueue_jobs(
            location_id=profile.location_id, jobs=jobs
        ) if jobs else ()
        counts = {str(item.get("outcome")): 0 for item in outcomes}
        for item in outcomes:
            key = str(item.get("outcome"))
            counts[key] = counts.get(key, 0) + 1
        return MaterializationReport(
            business_date=business_date,
            active_products=len(product_ids),
            prepared=len(jobs),
            queued=counts.get("queued", 0),
            duplicate=counts.get("duplicate", 0),
            stale=counts.get("stale_revision", 0),
            skipped=skipped,
            jobs=tuple(dict(item) for item in outcomes),
        )


class SupabaseForecastJobRepository:
    """Trusted service-role RPC client; never constructed for client code."""

    def __init__(self, *, url: str, secret_key: str, timeout_seconds: float) -> None:
        if not secret_key or secret_key.startswith("sb_publishable_"):
            raise ValueError("A server-only Supabase secret key is required")
        self._url = url.rstrip("/")
        self._headers = {
            "apikey": secret_key,
            "Content-Type": "application/json",
            "Accept-Profile": "public",
            "Content-Profile": "public",
        }
        # Opaque sb_secret_* API keys belong in apikey only. Legacy service-role
        # JWTs still need Authorization to select their Postgres role.
        if not secret_key.startswith("sb_secret_"):
            self._headers["Authorization"] = f"Bearer {secret_key}"
        self._client = httpx.Client(timeout=timeout_seconds)

    def close(self) -> None:
        self._client.close()

    def _rpc(self, function: str, params: Mapping[str, object]) -> Any:
        operation = f"trusted_rpc:{function}"
        started = start_timer()
        try:
            response = self._client.post(
                f"{self._url}/rest/v1/rpc/{function}",
                headers=self._headers,
                json=dict(params),
            )
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            error.data_stage = operation
            log_event(
                "forecast_materialization.rpc_failed",
                rpc_name=operation,
                category=type(error).__name__,
            )
            raise
        finally:
            # No host, URL, headers, request body, or response body are logged.
            log_duration("forecast_materialization.rpc", started, rpc=function)
        if response.status_code >= 400:
            stage = f"{operation}:http_{response.status_code}"
            log_event(
                "forecast_materialization.rpc_failed",
                rpc_name=operation,
                category="upstream_http_error",
                http_status=response.status_code,
                **_safe_rpc_error_fields(response),
            )
            raise DataUnavailableError(
                f"Trusted forecast queue operation failed ({response.status_code})",
                stage=stage,
            )
        try:
            return response.json()
        except ValueError as error:
            stage = f"{operation}:invalid_response"
            log_event(
                "forecast_materialization.rpc_failed",
                rpc_name=operation,
                category="invalid_json_response",
            )
            raise DataUnavailableError(
                "Trusted forecast queue returned invalid data", stage=stage
            ) from error

    def initialize_revisions(
        self, *, location_id: str, product_ids: Sequence[str]
    ) -> Mapping[str, Mapping[str, int]]:
        result = self._rpc(
            "forecast_initialize_revisions_v1",
            {"p_location_id": location_id, "p_product_ids": list(product_ids)},
        )
        if not isinstance(result, list):
            raise DataUnavailableError("Revision initializer returned an invalid result")
        return {
            str(row["product_id"]): {
                "sales_revision": int(row["sales_revision"]),
                "product_revision": int(row["product_revision"]),
            }
            for row in result
            if isinstance(row, dict)
        }

    def enqueue_jobs(
        self, *, location_id: str, jobs: Sequence[Mapping[str, object]]
    ) -> Sequence[Mapping[str, object]]:
        result = self._rpc(
            "forecast_request_jobs_v1" if len(jobs) == 1 else "forecast_enqueue_jobs_v1",
            {"p_location_id": location_id, "p_jobs": list(jobs)},
        )
        if not isinstance(result, list) or any(not isinstance(row, dict) for row in result):
            raise DataUnavailableError("Job materializer returned an invalid result")
        return result
