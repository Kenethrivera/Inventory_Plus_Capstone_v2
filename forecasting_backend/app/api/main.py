from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
from threading import Lock
from typing import Callable, Literal, Mapping
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from app.classification import (
    GeminiConfigurationError,
    GeminiHardwareClassifier,
    GeminiRateLimitError,
    GeminiServiceError,
    GeminiTimeoutError,
    HardwareProductClassifier,
)
from app.data.validation import DemandDataError
from app.recommendations.preliminary import PRELIMINARY_RESTOCKING_ASSUMPTIONS_V1

from .adapters import SyntheticDevelopmentAdapter, SupabaseForecastAdapter
from .contracts import (
    AuthenticationError,
    AuthorizationError,
    DataUnavailableError,
    ForecastDataAdapter,
    ProductNotFoundError,
    RecommendationConflictError,
    RecommendationPersistenceAdapter,
    RecommendationPersistenceUnavailableError,
    ReplenishmentConfigurationInput,
    ReplenishmentConfigurationUnavailableError,
    TrustedRecommendationSnapshot,
)
from .forecast_performance import ForecastPerformanceEvaluator
from .recommendation_persistence import SupabaseRecommendationPersistenceAdapter
from .service import ForecastAnalysisService
from .research_reports import SeasonalLearningReportService
from .settings import ApiSettings


logger = logging.getLogger("inventory_plus.forecasting")


class AnalysisRequest(BaseModel):
    location_id: str | None = None
    model: Literal[
        "mean28",
        "lightgbm",
        "blend",
        "calibrated_blend",
        "seasonal_experimental",
    ] = "blend"
    horizon_days: int = Field(default=28, ge=1, le=90)
    manual_daily_demand: Decimal | None = None
    manual_unit: str | None = None
    manual_rationale: str | None = None
    manual_confirmed: bool = False


class ReplenishmentConfigurationRequest(BaseModel):
    location_id: str | None = None
    supplier_lead_time_days: int | None = Field(default=None, ge=0, le=3650)
    review_period_days: int | None = Field(default=None, ge=0, le=365)
    safety_stock: Decimal | None = Field(default=None, ge=0)
    minimum_order_quantity: Decimal | None = Field(default=None, ge=0)
    supplier_pack_size: Decimal | None = Field(default=None, gt=0)
    supplier_order_unit: str | None = None
    unit_conversion_factor: Decimal | None = Field(default=None, gt=0)
    confirmed_incoming_quantity: Decimal | None = Field(default=None, ge=0)
    incoming_quantity_verified: bool = False
    backorder_quantity: Decimal | None = Field(default=None, ge=0)
    backorder_quantity_verified: bool = False
    supplier_availability: Literal["available", "unavailable", "unknown"] | None = None
    data_source: Literal["admin_estimate", "verified_record"]
    source_captured_at: datetime | None = None
    rationale: str | None = Field(default=None, max_length=500)


class ClassificationRequest(BaseModel):
    product_name: str = Field(min_length=1, max_length=200)
    category: str | None = Field(default=None, max_length=120)
    description: str | None = Field(default=None, max_length=1000)
    engine: Literal["existing", "gemini"] = "existing"


class RecommendationSnapshotRequest(BaseModel):
    request_id: UUID
    location_id: str | None = None
    forecast_model: Literal["lightgbm"]
    forecast_version: Literal["1"]
    training_history_days: Literal[365]
    experimental_model: Literal[False]
    forecast_generated_at: datetime
    forecast_source_data_as_of: datetime
    planning_horizon_days: Literal[28]
    forecast_period_start: date
    forecast_period_end: date
    predicted_demand: Decimal = Field(ge=0)
    available_inventory: Decimal = Field(ge=0)
    recommended_restock_quantity: Decimal = Field(ge=0)
    inventory_unit: str = Field(min_length=1, max_length=50)


class ReceiptAllocationRequest(BaseModel):
    location_id: str | None = None
    transaction_history_id: UUID
    allocated_inventory_quantity: Decimal = Field(gt=0)


class RecommendationReconciliationRequest(BaseModel):
    request_id: UUID
    location_id: str | None = None
    confirm_no_receipts: bool = False
    confirmation_note: str | None = Field(default=None, max_length=500)


def create_app(
    *,
    adapter: ForecastDataAdapter | None = None,
    classifier: HardwareProductClassifier | None = None,
    gemini_classifier: GeminiHardwareClassifier | None = None,
    research_report_service: SeasonalLearningReportService | None = None,
    recommendation_persistence_adapter: RecommendationPersistenceAdapter
    | None = None,
    clock: Callable[[], datetime] | None = None,
    settings: ApiSettings | None = None,
) -> FastAPI:
    configured = settings or ApiSettings.from_environment()
    selected_adapter = adapter or (
        SyntheticDevelopmentAdapter(configured)
        if configured.mode == "synthetic"
        else SupabaseForecastAdapter(configured)
    )
    service = ForecastAnalysisService(selected_adapter)
    forecast_performance = ForecastPerformanceEvaluator(selected_adapter)
    selected_recommendation_persistence = recommendation_persistence_adapter
    if (
        selected_recommendation_persistence is None
        and configured.recommendation_persistence_enabled
    ):
        selected_recommendation_persistence = (
            SupabaseRecommendationPersistenceAdapter(configured)
        )
    hardware_classifier = classifier or HardwareProductClassifier.load_default()
    seasonal_learning_reports = (
        research_report_service or SeasonalLearningReportService()
    )
    selected_gemini_classifier = gemini_classifier
    gemini_classifier_lock = Lock()

    def get_gemini_classifier() -> GeminiHardwareClassifier:
        nonlocal selected_gemini_classifier
        if selected_gemini_classifier is None:
            with gemini_classifier_lock:
                if selected_gemini_classifier is None:
                    selected_gemini_classifier = (
                        GeminiHardwareClassifier.from_environment(
                            knowledge_classifier=hardware_classifier
                        )
                    )
        return selected_gemini_classifier

    now = clock or (lambda: datetime.now(timezone.utc))

    def recommendation_persistence() -> RecommendationPersistenceAdapter:
        if selected_recommendation_persistence is None:
            raise RecommendationPersistenceUnavailableError(
                "Recommendation tracking is not activated"
            )
        return selected_recommendation_persistence

    app = FastAPI(
        title="Inventory Plus Forecasting API",
        version="stage5f-v1",
        description=(
            "Authenticated forecasting and recommendation API with a scoped "
            "Admin-only replenishment-configuration write and an optional, "
            "server-only recommendation-tracking boundary."
        ),
    )
    if configured.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(configured.cors_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", "Accept"],
        )

    @app.post("/v1/classification")
    def classify_product(
        request: ClassificationRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        """Classify supplied text without reading or changing product records."""
        token = _bearer_token(authorization)
        try:
            profile = selected_adapter.authenticate(token)
            if profile.role.casefold() != "admin":
                raise AuthorizationError(
                    "Hardware classification is available to Admin users only"
                )
            active_classifier = (
                get_gemini_classifier()
                if request.engine == "gemini"
                else hardware_classifier
            )
            result = active_classifier.classify(
                product_name=request.product_name,
                category=request.category,
                description=request.description,
            )
            return {
                "schema_version": "classification-v3",
                "classifier_version": active_classifier.version,
                "engine": request.engine,
                "read_only": True,
                "result": result.to_dict(),
            }
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except GeminiConfigurationError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except GeminiRateLimitError as error:
            raise HTTPException(status_code=429, detail=str(error)) from error
        except GeminiTimeoutError as error:
            raise HTTPException(status_code=504, detail=str(error)) from error
        except GeminiServiceError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504, detail="Authentication data source timed out"
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503, detail="Authentication data source is unavailable"
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.post("/v1/forecasting/products/{product_id}/analysis")
    def analyze_product(
        product_id: str,
        request: AnalysisRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            return service.analyze(
                session_token=token,
                requested_location_id=request.location_id,
                product_id=product_id,
                model=request.model,
                horizon_days=request.horizon_days,
                now=now(),
                manual_daily_demand=request.manual_daily_demand,
                manual_unit=request.manual_unit,
                manual_rationale=request.manual_rationale,
                manual_confirmed=request.manual_confirmed,
            )
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except ProductNotFoundError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ReplenishmentConfigurationUnavailableError as error:
            _log_forecast_data_failure(error, requested_model=request.model)
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            _log_forecast_data_failure(error, requested_model=request.model)
            raise HTTPException(
                status_code=504, detail="Forecast data source timed out"
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            _log_forecast_data_failure(error, requested_model=request.model)
            raise HTTPException(
                status_code=503, detail="Forecast data source is unavailable"
            ) from error
        except (ValueError, DemandDataError) as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.get("/v1/forecasting/research/seasonal-learning")
    def seasonal_learning_laboratory(
        product_id: str | None = None,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        """Return immutable offline evaluation artifacts.

        Authentication reuses the operational session adapter, but the report
        loader performs no Supabase reads or writes and never changes product
        classifications, forecasts, or replenishment decisions.
        """
        token = _bearer_token(authorization)
        try:
            selected_adapter.authenticate(token)
            return seasonal_learning_reports.load(product_id=product_id)
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504, detail="Authentication data source timed out"
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503,
                detail="Authentication data source is unavailable",
            ) from error

    @app.get("/v1/forecasting/products/{product_id}/replenishment-config")
    def get_replenishment_configuration(
        product_id: str,
        location_id: str | None = None,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            return service.get_replenishment_configuration(
                session_token=token,
                requested_location_id=location_id,
                product_id=product_id,
            )
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except ProductNotFoundError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ReplenishmentConfigurationUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504, detail="Forecast data source timed out"
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503, detail="Forecast data source is unavailable"
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.put("/v1/forecasting/products/{product_id}/replenishment-config")
    def save_replenishment_configuration(
        product_id: str,
        request: ReplenishmentConfigurationRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        captured_at = request.source_captured_at or now()
        try:
            return service.save_replenishment_configuration(
                session_token=token,
                requested_location_id=request.location_id,
                product_id=product_id,
                configuration=ReplenishmentConfigurationInput(
                    supplier_lead_time_days=request.supplier_lead_time_days,
                    review_period_days=request.review_period_days,
                    safety_stock=request.safety_stock,
                    minimum_order_quantity=request.minimum_order_quantity,
                    supplier_pack_size=request.supplier_pack_size,
                    supplier_order_unit=request.supplier_order_unit,
                    unit_conversion_factor=request.unit_conversion_factor,
                    confirmed_incoming_quantity=(
                        request.confirmed_incoming_quantity
                    ),
                    incoming_quantity_verified=request.incoming_quantity_verified,
                    backorder_quantity=request.backorder_quantity,
                    backorder_quantity_verified=request.backorder_quantity_verified,
                    supplier_availability=request.supplier_availability,
                    data_source=request.data_source,
                    source_captured_at=captured_at,
                    rationale=request.rationale,
                ),
                now=now(),
            )
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except ProductNotFoundError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ReplenishmentConfigurationUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504, detail="Forecast data source timed out"
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503, detail="Forecast data source is unavailable"
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.post(
        "/v1/forecasting/products/{product_id}/recommendation-snapshots"
    )
    def save_recommendation_snapshot(
        product_id: str,
        request: RecommendationSnapshotRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            persistence = recommendation_persistence()
            profile = service.authorize_admin(
                session_token=token,
                requested_location_id=request.location_id,
            )
            try:
                UUID(product_id)
            except ValueError as error:
                raise ValueError("product_id must be a UUID") from error

            existing = persistence.snapshot_by_request(
                session_token=token,
                request_id=request.request_id,
            )
            if existing is not None:
                _verify_existing_snapshot(
                    existing=existing,
                    request=request,
                    product_id=product_id,
                    location_id=profile.location_id,
                )
                return _existing_snapshot_response(existing)

            request_now = now()
            _validate_new_snapshot_freshness(request, request_now)
            trusted = service.trusted_preliminary_snapshot(
                session_token=token,
                requested_location_id=request.location_id,
                product_id=product_id,
                forecast_generated_at=request.forecast_generated_at,
            )
            _verify_trusted_snapshot(request=request, trusted=trusted)
            saved = persistence.save_snapshot(
                session_token=token,
                request_id=request.request_id,
                snapshot=trusted,
            )
            return _trusted_snapshot_response(
                request_id=request.request_id,
                snapshot=trusted,
                persistence_result=saved,
            )
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except ProductNotFoundError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except RecommendationConflictError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        except RecommendationPersistenceUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504,
                detail="Recommendation persistence data source timed out",
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503,
                detail="Recommendation persistence data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.post(
        "/v1/forecasting/recommendations/{recommendation_id}/receipt-allocations"
    )
    def match_recommendation_receipt(
        recommendation_id: int,
        request: ReceiptAllocationRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            if recommendation_id <= 0:
                raise ValueError("recommendation_id must be positive")
            service.authorize_admin(
                session_token=token,
                requested_location_id=request.location_id,
            )
            result = recommendation_persistence().match_receipt(
                session_token=token,
                recommendation_id=recommendation_id,
                transaction_history_id=request.transaction_history_id,
                allocated_inventory_quantity=request.allocated_inventory_quantity,
            )
            return {
                "schema_version": "recommendation-tracking-v2",
                "operation": "receipt_allocation",
                **dict(result),
            }
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except RecommendationConflictError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        except RecommendationPersistenceUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504,
                detail="Recommendation persistence data source timed out",
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503,
                detail="Recommendation persistence data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.post("/v1/forecasting/recommendations/{recommendation_id}/reconcile")
    def reconcile_recommendation(
        recommendation_id: int,
        request: RecommendationReconciliationRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            if recommendation_id <= 0:
                raise ValueError("recommendation_id must be positive")
            service.authorize_admin(
                session_token=token,
                requested_location_id=request.location_id,
            )
            result = recommendation_persistence().reconcile(
                session_token=token,
                request_id=request.request_id,
                recommendation_id=recommendation_id,
                confirm_no_receipts=request.confirm_no_receipts,
                confirmation_note=(
                    request.confirmation_note.strip()
                    if request.confirmation_note
                    and request.confirmation_note.strip()
                    else None
                ),
            )
            return {
                "schema_version": "recommendation-tracking-v2",
                "operation": "reconciliation",
                **dict(result),
            }
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except RecommendationConflictError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        except RecommendationPersistenceUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504,
                detail="Recommendation persistence data source timed out",
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503,
                detail="Recommendation persistence data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.get("/v1/forecasting/recommendations")
    def recommendation_tracking(
        product_id: str | None = None,
        location_id: str | None = None,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            service.authorize_admin(
                session_token=token,
                requested_location_id=location_id,
            )
            parsed_product_id = UUID(product_id) if product_id else None
            rows = recommendation_persistence().tracking(
                session_token=token,
                product_id=parsed_product_id,
            )
            return {
                "schema_version": "recommendation-tracking-v2",
                "read_only": True,
                "items": [
                    {
                        **dict(row),
                        # These fields are guaranteed by the deployed save RPC
                        # and its table constraints. The assumptions are the
                        # same versioned server-side values used for every
                        # trusted snapshot; Flutter never supplies them.
                        "forecast_model": "lightgbm",
                        "forecast_version": "1",
                        "training_history_days": 365,
                        "experimental_model": False,
                        "assumptions": list(
                            PRELIMINARY_RESTOCKING_ASSUMPTIONS_V1
                        ),
                    }
                    for row in rows
                ],
            }
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except RecommendationPersistenceUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504,
                detail="Recommendation persistence data source timed out",
            ) from error
        except (httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(
                status_code=503,
                detail="Recommendation persistence data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.get("/v1/forecasting/forecast-performance")
    def forecast_performance_monitoring(
        product_id: str,
        location_id: str | None = None,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        """Compare saved predictions with completed sales; never writes data."""
        token = _bearer_token(authorization)
        try:
            profile = service.authorize_admin(
                session_token=token,
                requested_location_id=location_id,
            )
            parsed_product_id = UUID(product_id)
            rows = recommendation_persistence().tracking(
                session_token=token,
                product_id=parsed_product_id,
            )
            return forecast_performance.evaluate(
                profile=profile,
                session_token=token,
                product_id=str(parsed_product_id),
                tracking_rows=rows,
                now=now(),
            )
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except RecommendationPersistenceUnavailableError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        except httpx.TimeoutException as error:
            raise HTTPException(
                status_code=504,
                detail="Forecast performance data source timed out",
            ) from error
        except (httpx.NetworkError, DataUnavailableError, DemandDataError) as error:
            raise HTTPException(
                status_code=503,
                detail="Forecast performance data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    return app


def _bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Bearer session token is required")
    scheme, separator, token = authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="Bearer session token is invalid")
    return token.strip()


def _log_forecast_data_failure(
    error: BaseException,
    *,
    requested_model: str,
) -> None:
    cause = error.__cause__
    stage = getattr(error, "stage", None) or getattr(
        error, "data_stage", "unknown"
    )
    logger.error(
        "forecast_data_source_failure endpoint=%s requested_model=%s "
        "stage=%s exception_type=%s cause_type=%s",
        "/v1/forecasting/products/{product_id}/analysis",
        requested_model,
        stage,
        type(error).__name__,
        type(cause).__name__ if cause is not None else "none",
        exc_info=True,
    )


def _validate_new_snapshot_freshness(
    request: RecommendationSnapshotRequest,
    now: datetime,
) -> None:
    if now.tzinfo is None:
        raise ValueError("Server clock must include a timezone")
    if request.forecast_generated_at.tzinfo is None:
        raise ValueError("forecast_generated_at must include a timezone")
    if request.forecast_source_data_as_of.tzinfo is None:
        raise ValueError("forecast_source_data_as_of must include a timezone")
    if not request.predicted_demand.is_finite():
        raise ValueError("predicted_demand must be finite")
    if not request.available_inventory.is_finite():
        raise ValueError("available_inventory must be finite")
    if not request.recommended_restock_quantity.is_finite():
        raise ValueError("recommended_restock_quantity must be finite")
    if request.forecast_generated_at < now - timedelta(hours=24):
        raise ValueError("The displayed forecast is stale; refresh before saving")
    if request.forecast_generated_at > now + timedelta(minutes=5):
        raise ValueError("forecast_generated_at cannot be in the future")
    if request.forecast_source_data_as_of < now - timedelta(hours=24):
        raise ValueError("The displayed forecast source data is stale")
    if request.forecast_source_data_as_of > now + timedelta(minutes=5):
        raise ValueError("forecast_source_data_as_of cannot be in the future")
    if request.forecast_source_data_as_of < (
        request.forecast_generated_at - timedelta(hours=24)
    ) or request.forecast_source_data_as_of > (
        request.forecast_generated_at + timedelta(minutes=5)
    ):
        raise ValueError("Forecast and source-data timestamps are inconsistent")
    if request.forecast_period_end != request.forecast_period_start + timedelta(
        days=27
    ):
        raise ValueError("The approved planning horizon must contain 28 days")
    manila_date = request.forecast_generated_at.astimezone(
        ZoneInfo("Asia/Manila")
    ).date()
    if request.forecast_period_start != manila_date:
        raise ValueError("Forecast period does not start on the generation date")
    expected = max(
        Decimal("0"),
        (request.predicted_demand - request.available_inventory).to_integral_value(
            rounding=ROUND_CEILING
        ),
    )
    if request.recommended_restock_quantity != expected:
        raise RecommendationConflictError(
            "Submitted restock quantity does not match demand minus inventory"
        )


def _verify_trusted_snapshot(
    *,
    request: RecommendationSnapshotRequest,
    trusted: TrustedRecommendationSnapshot,
) -> None:
    comparisons = (
        (request.forecast_model, trusted.forecast_model),
        (request.forecast_version, trusted.forecast_version),
        (request.training_history_days, trusted.training_history_days),
        (request.experimental_model, trusted.experimental_model),
        (request.forecast_generated_at, trusted.forecast_generated_at),
        (
            request.forecast_source_data_as_of,
            trusted.forecast_source_data_as_of,
        ),
        (request.planning_horizon_days, trusted.planning_horizon_days),
        (request.forecast_period_start, trusted.forecast_period_start),
        (request.forecast_period_end, trusted.forecast_period_end),
        (request.predicted_demand, trusted.predicted_demand),
        (request.available_inventory, trusted.available_inventory),
        (
            request.recommended_restock_quantity,
            trusted.recommended_restock_quantity,
        ),
        (request.inventory_unit.strip().casefold(), trusted.inventory_unit.casefold()),
    )
    if any(submitted != calculated for submitted, calculated in comparisons):
        raise RecommendationConflictError(
            "Submitted recommendation does not match the trusted server calculation"
        )


def _verify_existing_snapshot(
    *,
    existing: Mapping[str, object],
    request: RecommendationSnapshotRequest,
    product_id: str,
    location_id: str,
) -> None:
    try:
        comparisons = (
            (str(existing["request_id"]), str(request.request_id)),
            (str(existing["location_id_snapshot"]), location_id),
            (str(existing["product_id_snapshot"]), product_id),
            (str(existing["forecast_model"]), request.forecast_model),
            (str(existing["forecast_version"]), request.forecast_version),
            (int(existing["training_history_days"]), request.training_history_days),
            (existing["experimental_model"], request.experimental_model),
            (
                _database_datetime(existing["forecast_generated_at"]),
                request.forecast_generated_at,
            ),
            (
                _database_datetime(existing["forecast_source_data_as_of"]),
                request.forecast_source_data_as_of,
            ),
            (
                int(existing["planning_horizon_days"]),
                request.planning_horizon_days,
            ),
            (
                date.fromisoformat(str(existing["forecast_period_start"])),
                request.forecast_period_start,
            ),
            (
                date.fromisoformat(str(existing["forecast_period_end"])),
                request.forecast_period_end,
            ),
            (Decimal(str(existing["predicted_demand"])), request.predicted_demand),
            (
                Decimal(str(existing["available_inventory"])),
                request.available_inventory,
            ),
            (
                Decimal(str(existing["recommended_restock_quantity"])),
                request.recommended_restock_quantity,
            ),
            (
                str(existing["inventory_unit_snapshot"]).strip().casefold(),
                request.inventory_unit.strip().casefold(),
            ),
        )
    except (KeyError, TypeError, ValueError, ArithmeticError) as error:
        raise DataUnavailableError(
            "Saved recommendation snapshot is malformed",
            stage="trusted_recommendation:existing_snapshot",
        ) from error
    if any(saved != submitted for saved, submitted in comparisons):
        raise RecommendationConflictError(
            "Recommendation request ID was already used for a different payload"
        )


def _database_datetime(value: object) -> datetime:
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Database timestamp has no timezone")
    return parsed


def _existing_snapshot_response(existing: Mapping[str, object]) -> dict[str, object]:
    return {
        "schema_version": "recommendation-tracking-v2",
        "recommendation_id": existing["recommendation_id"],
        "request_id": existing["request_id"],
        "reused": True,
        "snapshot": {
            **{
                key: existing[key]
                for key in (
                    "location_id_snapshot",
                    "product_id_snapshot",
                    "product_name_snapshot",
                    "product_sku_snapshot",
                    "inventory_unit_snapshot",
                    "forecast_model",
                    "forecast_version",
                    "training_history_days",
                    "experimental_model",
                    "forecast_generated_at",
                    "forecast_source_data_as_of",
                    "planning_horizon_days",
                    "forecast_period_start",
                    "forecast_period_end",
                    "predicted_demand",
                    "available_inventory",
                    "recommended_restock_quantity",
                )
            },
            "assumptions": list(
                existing.get(
                    "assumptions", PRELIMINARY_RESTOCKING_ASSUMPTIONS_V1
                )
            ),
        },
    }


def _trusted_snapshot_response(
    *,
    request_id: UUID,
    snapshot: TrustedRecommendationSnapshot,
    persistence_result: Mapping[str, object],
) -> dict[str, object]:
    return {
        "schema_version": "recommendation-tracking-v2",
        "recommendation_id": persistence_result.get("recommendation_id"),
        "request_id": str(request_id),
        "reused": persistence_result.get("reused") is True,
        "snapshot": {
            "location_id_snapshot": snapshot.location_id,
            "product_id_snapshot": snapshot.product_id,
            "inventory_unit_snapshot": snapshot.inventory_unit,
            "forecast_model": snapshot.forecast_model,
            "forecast_version": snapshot.forecast_version,
            "training_history_days": snapshot.training_history_days,
            "experimental_model": snapshot.experimental_model,
            "forecast_generated_at": snapshot.forecast_generated_at,
            "forecast_source_data_as_of": snapshot.forecast_source_data_as_of,
            "planning_horizon_days": snapshot.planning_horizon_days,
            "forecast_period_start": snapshot.forecast_period_start,
            "forecast_period_end": snapshot.forecast_period_end,
            "predicted_demand": snapshot.predicted_demand,
            "available_inventory": snapshot.available_inventory,
            "recommended_restock_quantity": (
                snapshot.recommended_restock_quantity
            ),
            "assumptions": list(snapshot.assumptions),
        },
    }
