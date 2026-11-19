from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
from threading import Lock
from typing import Callable, Literal, Mapping
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, Header, HTTPException, Query, Request, Response
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
from app.performance_diagnostics import (
    configure_performance_logging,
    diagnostics_enabled,
    log_duration,
    log_event,
    log_startup_duration,
    performance_request,
    start_timer,
)
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
from .job_materialization import (
    ForecastJobMaterializer,
    SupabaseForecastJobRepository,
    forecast_model_identity,
)
from .recommendation_persistence import (
    SupabaseRecommendationPersistenceAdapter,
    SupabaseRecommendationTrackingReader,
)
from .snapshot_reads import ForecastSnapshotReadRepository
from .snapshot_guidance import current_stock_analysis
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


class SnapshotManualGuidanceRequest(BaseModel):
    location_id: str | None = None
    model: Literal[
        "mean28", "lightgbm", "blend", "calibrated_blend", "seasonal_experimental"
    ] = "blend"
    manual_daily_demand: Decimal = Field(ge=0)
    manual_unit: str = Field(min_length=1)
    manual_rationale: str = Field(min_length=1)
    manual_confirmed: Literal[True]


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
    performance_diagnostics_enabled = diagnostics_enabled(
        configured.deployment_environment
    )
    configure_performance_logging(performance_diagnostics_enabled)
    app_initialization_started = start_timer(
        enabled=performance_diagnostics_enabled
    )
    selected_adapter = adapter or (
        SyntheticDevelopmentAdapter(configured)
        if configured.mode == "synthetic"
        else SupabaseForecastAdapter(configured)
    )
    service_initialization_started = start_timer(
        enabled=performance_diagnostics_enabled
    )
    service = ForecastAnalysisService(selected_adapter)
    job_materializer = None
    if configured.forecast_job_materialization_enabled:
        if (
            configured.mode != "supabase"
            or configured.supabase_url is None
            or configured.supabase_secret_key is None
            or not callable(getattr(selected_adapter, "list_active_products", None))
        ):
            raise RuntimeError(
                "Trusted forecast job materialization requires the Supabase adapter and server-side credentials"
            )
        job_repository = SupabaseForecastJobRepository(
            url=configured.supabase_url,
            secret_key=configured.supabase_secret_key,
            timeout_seconds=configured.request_timeout_seconds,
        )
        job_materializer = ForecastJobMaterializer(
            catalog=selected_adapter,
            repository=job_repository,
            service=service,
        )
    snapshot_repository = None
    if configured.forecast_snapshot_reads_enabled:
        if (
            configured.mode != "supabase"
            or configured.supabase_url is None
            or configured.supabase_secret_key is None
        ):
            raise RuntimeError(
                "Forecast snapshot reads require Supabase mode and a server-only secret"
            )
        snapshot_repository = ForecastSnapshotReadRepository(
            url=configured.supabase_url,
            secret_key=configured.supabase_secret_key,
            timeout_seconds=configured.request_timeout_seconds,
        )
    log_startup_duration(
        "analysis_service.initialize",
        service_initialization_started,
        enabled=performance_diagnostics_enabled,
        environment=configured.deployment_environment,
    )
    analysis_request_count = 0
    analysis_request_lock = Lock()

    def next_analysis_request_number() -> int:
        nonlocal analysis_request_count
        with analysis_request_lock:
            analysis_request_count += 1
            return analysis_request_count
    forecast_performance = ForecastPerformanceEvaluator(selected_adapter)
    selected_recommendation_persistence = recommendation_persistence_adapter
    if (
        selected_recommendation_persistence is None
        and configured.recommendation_persistence_enabled
    ):
        selected_recommendation_persistence = (
            SupabaseRecommendationPersistenceAdapter(configured)
        )
    tracking_reader = selected_recommendation_persistence
    if tracking_reader is None and configured.forecast_snapshot_reads_enabled:
        tracking_reader = SupabaseRecommendationTrackingReader(configured)
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

    app = FastAPI(
        title="Inventory Plus Forecasting API",
        version="stage5f-v1",
        description=(
            "Authenticated forecasting and recommendation API with a scoped "
            "Admin-only replenishment-configuration write and an optional, "
            "server-only recommendation-tracking boundary."
        ),
    )

    @app.post("/v1/forecasting/jobs/bootstrap")
    def bootstrap_forecast_jobs(
        product_id: str = Query(..., min_length=36, max_length=36),
        model: Literal["mean28", "lightgbm", "blend", "calibrated_blend", "seasonal_experimental"] = "blend",
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        """Prepare one requested model for one Admin-scoped product."""
        if job_materializer is None:
            raise HTTPException(
                status_code=503,
                detail="Forecast job materialization is not enabled",
            )
        token = _bearer_token(authorization)
        with performance_request(enabled=performance_diagnostics_enabled):
            try:
                profile = service.authorize_admin(
                    session_token=token,
                    requested_location_id=None,
                )

                requested_model = "blend" if model == "calibrated_blend" else model
                if snapshot_repository is not None:
                    identity = forecast_model_identity(service, requested_model)
                    # A completed snapshot is reusable only for the deployed
                    # model/configuration identity and current source revisions.
                    saved = snapshot_repository.product(
                        location_id=profile.location_id, product_id=str(UUID(product_id)), model_key=requested_model,
                    )
                    for item in saved.get("items", []):
                        snap = item.get("snapshot") or {}
                        model_identity = snap.get("requested_model") or {}
                        if (item.get("status") == "completed"
                            and model_identity.get("key") == identity.model_key
                            and model_identity.get("version") == identity.model_version
                            and model_identity.get("config_digest") == identity.config_digest
                            and model_identity.get("implementation_digest") == identity.implementation_digest
                            and snap.get("horizon_days") == 28
                            and snap.get("history_window_days") == (1095 if requested_model == "seasonal_experimental" else 365)):
                            return {"business_date": snap["as_of_business_date"], "active_products": 1,
                                    "prepared": 0, "queued": 0, "duplicate": 1, "stale": 0, "skipped": 0,
                                    "jobs": [{"status": "succeeded", "outcome": "available"}],
                                    "result_id": snap["result_id"]}

                report = job_materializer.bootstrap(
                    profile=profile,
                    session_token=token,
                    now=now(),
                    product_id=product_id,
                    model_key=requested_model,
                )
                return {
                    "business_date": report.business_date.isoformat(),
                    "active_products": report.active_products,
                    "prepared": report.prepared,
                    "queued": report.queued,
                    "duplicate": report.duplicate,
                    "stale": report.stale,
                    "skipped": report.skipped,
                    "jobs": list(report.jobs),
                }
            except AuthenticationError as error:
                raise HTTPException(status_code=401, detail=str(error)) from error
            except AuthorizationError as error:
                raise HTTPException(status_code=403, detail=str(error)) from error
            except ProductNotFoundError as error:
                raise HTTPException(status_code=404, detail=str(error)) from error
            except httpx.TimeoutException as error:
                log_event(
                    "forecast_job.bootstrap.failed",
                    stage=getattr(error, "data_stage", "unknown"),
                    category=type(error).__name__,
                )
                raise HTTPException(
                    status_code=504, detail="Forecast job preparation timed out"
                ) from error
            except (httpx.NetworkError, DataUnavailableError) as error:
                log_event(
                    "forecast_job.bootstrap.failed",
                    stage=(
                        getattr(error, "data_stage", None)
                        or getattr(error, "stage", None)
                        or "unknown"
                    ),
                    category=type(error).__name__,
                )
                raise HTTPException(
                    status_code=503, detail="Forecast job preparation is unavailable"
                ) from error
            except (PermissionError, ValueError) as error:
                raise HTTPException(status_code=422, detail=str(error)) from error

    @app.get("/v1/forecasting/snapshots/overview")
    def forecast_snapshot_overview(
        response: Response,
        location_id: str | None = None,
        model: Literal["mean28", "lightgbm", "blend", "calibrated_blend", "seasonal_experimental"] = "blend",
        unit: str | None = Query(default=None, max_length=50),
        search: str | None = Query(default=None, max_length=120),
        scope_category: str | None = Query(default=None, max_length=120),
        scope_product_id: UUID | None = None,
        page: int = Query(default=1, ge=1, le=10000),
        page_size: int = Query(default=25, ge=1, le=50),
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        response.headers["Cache-Control"] = "no-store"
        if snapshot_repository is None:
            raise HTTPException(status_code=503, detail="Forecast snapshot reads are not enabled")
        token = _bearer_token(authorization)
        try:
            profile = service.authorize_admin(
                session_token=token,
                requested_location_id=location_id,
            )
            normalized_model = "blend" if model == "calibrated_blend" else model
            with performance_request(enabled=performance_diagnostics_enabled):
                started = start_timer(enabled=performance_diagnostics_enabled)
                result = snapshot_repository.overview(
                    location_id=profile.location_id,
                    model_key=normalized_model,
                    page=page,
                    page_size=page_size,
                    unit=unit,
                    search=search,
                    category=scope_category,
                    product_id=str(scope_product_id) if scope_product_id else None,
                )
                rows = result.get("items")
                # Bound guidance work independently of the page size. Reuse the
                # product read path, which only decodes saved demand and applies
                # the existing calculators to live stock (never fits models).
                guidance_rows = []
                if isinstance(rows, list):
                    for row in rows:
                        if row.get("status") != "completed":
                            continue
                        if len(guidance_rows) >= 5:
                            break
                        product_id = row["product"]["product_id"]
                        try:
                            detail = forecast_product_snapshot(
                                response=Response(), product_id=product_id,
                                location_id=profile.location_id, model=normalized_model,
                                authorization=authorization,
                            )
                            if detail.get("status") == "completed" and detail.get("analysis") is not None:
                                row["analysis"] = detail["analysis"]
                            row["guidance_error"] = detail.get("guidance_error")
                        except HTTPException as error:
                            if error.status_code in (401, 403):
                                raise
                            row["guidance_error"] = "Current-stock guidance is unavailable."
                        guidance_rows.append(product_id)
                result["guidance_coverage"] = {
                    "evaluated_product_ids": guidance_rows,
                    "scope": "current_page", "limit": 5,
                }
                try:
                    result["sales_history_coverage"] = snapshot_repository.history_coverage(
                        location_id=profile.location_id, model_key=normalized_model,
                        unit=unit, search=search, category=scope_category,
                        product_id=str(scope_product_id) if scope_product_id else None,
                    )
                except (DataUnavailableError, httpx.HTTPError) as error:
                    logger.warning("snapshot_history_coverage_unavailable category=%s", type(error).__name__)
                    result["sales_history_coverage"] = {"available": False}
                log_duration(
                    "snapshot.overview.read",
                    started,
                    enabled=performance_diagnostics_enabled,
                    page=page,
                    page_size=page_size,
                    result_count=len(rows) if isinstance(rows, list) else 0,
                )
            return result
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except (httpx.TimeoutException, DataUnavailableError) as error:
            raise HTTPException(status_code=503, detail="Forecast snapshot service is unavailable") from error

    @app.get("/v1/forecasting/products/{product_id}/snapshot")
    def forecast_product_snapshot(
        response: Response,
        product_id: str,
        location_id: str | None = None,
        model: Literal["mean28", "lightgbm", "blend", "calibrated_blend", "seasonal_experimental"] = "blend",
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        response.headers["Cache-Control"] = "no-store"
        if snapshot_repository is None:
            raise HTTPException(status_code=503, detail="Forecast snapshot reads are not enabled")
        token = _bearer_token(authorization)
        try:
            parsed_product = UUID(product_id)
            profile = service.authorize_admin(
                session_token=token,
                requested_location_id=location_id,
            )
            normalized_model = "blend" if model == "calibrated_blend" else model
            with performance_request(enabled=performance_diagnostics_enabled):
                started = start_timer(enabled=performance_diagnostics_enabled)
                result = snapshot_repository.product(
                    location_id=profile.location_id,
                    product_id=str(parsed_product),
                    model_key=normalized_model,
                )
                items = result.get("items")
                log_duration(
                    "snapshot.product.read",
                    started,
                    enabled=performance_diagnostics_enabled,
                    result_count=len(items) if isinstance(items, list) else 0,
                )
            if not isinstance(items, list) or not items:
                raise HTTPException(status_code=404, detail="Product snapshot is unavailable")
            item = items[0]
            snapshot = item.get("snapshot") if isinstance(item, dict) else None
            if item.get("status") in {"completed", "stale"} and isinstance(snapshot, dict):
                load_operational = getattr(selected_adapter, "load_operational_context", None)
                if callable(load_operational):
                    try:
                        context = load_operational(
                            profile=profile,
                            session_token=token,
                            product_id=str(parsed_product),
                            now=now(),
                        )
                        item["analysis"] = current_stock_analysis(
                            service=service,
                            profile=profile,
                            context=context,
                            snapshot={
                                **snapshot,
                                "product_id": str(parsed_product),
                                "location_id": profile.location_id,
                            },
                            now=now(),
                        )
                        if item.get("status") == "stale":
                            # Keep the saved chart visible, but do not present
                            # guidance based on obsolete demand as actionable.
                            analysis = item["analysis"]
                            preliminary = analysis["preliminary_restocking_insight"]
                            preliminary["status"] = "limited"
                            preliminary["reliability"] = "unavailable"
                            preliminary["suggested_restock_quantity"] = None
                            preliminary["limitations"].append("Saved demand is stale; prepare a current forecast before restocking.")
                            recommendation = analysis["recommendation"]
                            recommendation["status"] = "needs_review"
                            recommendation["suggested_quantity"]["inventory_units"] = None
                            recommendation["suggested_quantity"]["order_units"] = None
                            recommendation["warnings"].append("stale_saved_demand")
                    except (DataUnavailableError, DemandDataError, ValueError,
                            KeyError, TypeError, ProductNotFoundError) as error:
                        logger.warning(
                            "snapshot_guidance_unavailable category=%s",
                            type(error).__name__,
                        )
                        item["guidance_error"] = (
                            "Current-stock restock guidance is unavailable. "
                            "The saved demand forecast remains available."
                        )
            return item
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail="product_id must be a UUID") from error
        except (httpx.TimeoutException, DataUnavailableError) as error:
            raise HTTPException(status_code=503, detail="Forecast snapshot service is unavailable") from error

    @app.post("/v1/forecasting/products/{product_id}/snapshot-guidance")
    def preview_saved_forecast_guidance(
        product_id: str,
        request: SnapshotManualGuidanceRequest,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        """Preview a confirmed cold-start estimate using saved demand forecasts."""
        if snapshot_repository is None:
            raise HTTPException(status_code=503, detail="Forecast snapshot reads are not enabled")
        token = _bearer_token(authorization)
        try:
            parsed_product = UUID(product_id)
            profile = service.authorize_admin(
                session_token=token,
                requested_location_id=request.location_id,
            )
            model_key = "blend" if request.model == "calibrated_blend" else request.model
            result = snapshot_repository.product(
                location_id=profile.location_id,
                product_id=str(parsed_product),
                model_key=model_key,
            )
            items = result.get("items")
            if not isinstance(items, list) or not items:
                raise HTTPException(status_code=404, detail="Product snapshot is unavailable")
            item = items[0]
            snapshot = item.get("snapshot") if isinstance(item, dict) else None
            if item.get("status") != "completed" or not isinstance(snapshot, dict):
                raise HTTPException(status_code=409, detail="A current saved forecast is required")
            load_operational = getattr(selected_adapter, "load_operational_context", None)
            if not callable(load_operational):
                raise DataUnavailableError("Current stock context is unavailable")
            current_time = now()
            context = load_operational(
                profile=profile,
                session_token=token,
                product_id=str(parsed_product),
                now=current_time,
            )
            return current_stock_analysis(
                service=service,
                profile=profile,
                context=context,
                snapshot={
                    **snapshot,
                    "product_id": str(parsed_product),
                    "location_id": profile.location_id,
                },
                now=current_time,
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
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except (httpx.TimeoutException, httpx.NetworkError, DataUnavailableError) as error:
            raise HTTPException(status_code=503, detail="Saved forecast guidance is unavailable") from error

    def recommendation_persistence() -> RecommendationPersistenceAdapter:
        if selected_recommendation_persistence is None:
            raise RecommendationPersistenceUnavailableError(
                "Recommendation tracking is not activated"
            )
        return selected_recommendation_persistence

    def recommendation_tracking_source():
        if tracking_reader is None:
            raise RecommendationPersistenceUnavailableError(
                "Recommendation tracking is not activated"
            )
        return tracking_reader

    @app.middleware("http")
    async def measure_analysis_http_request(request: Request, call_next):
        path = request.url.path
        is_analysis = (
            path.startswith("/v1/forecasting/products/")
            and path.endswith("/analysis")
        )
        if not performance_diagnostics_enabled or not is_analysis:
            return await call_next(request)
        with performance_request(enabled=True):
            request_started = start_timer()
            try:
                response = await call_next(request)
            except Exception:
                log_duration(
                "api.analysis.middleware_elapsed",
                    request_started,
                    status="exception",
                )
                raise
            log_duration(
                "api.analysis.middleware_elapsed",
                request_started,
                status_code=response.status_code,
                response_body_completion_not_measured=True,
            )
            return response
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
        process_request_number = (
            next_analysis_request_number()
            if performance_diagnostics_enabled
            else 0
        )
        handler_started = start_timer()
        log_event(
            "api.analysis.start",
            process_request_number=process_request_number,
            model=request.model,
            horizon_days=request.horizon_days,
        )
        try:
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
        finally:
            log_duration(
                "api.analysis.handler",
                handler_started,
                process_request_number=process_request_number,
            )

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

    @app.get("/v1/forecasting/restock-records")
    def applied_restock_records(
        product_id: str, location_id: str | None = None,
        authorization: str | None = Header(default=None),
    ) -> dict[str, object]:
        token = _bearer_token(authorization)
        try:
            service.authorize_admin(session_token=token, requested_location_id=location_id)
            UUID(product_id)
            loader = getattr(selected_adapter, "load_applied_restocks", None)
            if loader is None:
                raise DataUnavailableError("Applied inventory records are unavailable")
            rows = loader(session_token=token, product_id=product_id)
            from .restock_records import validate_restock_rows
            rows = validate_restock_rows(rows)
            # Evidence is captured independently by the background capture process.
            return {"read_only": True, "inventory_read_only": True, "items": rows}
        except AuthenticationError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        except AuthorizationError as error:
            raise HTTPException(status_code=403, detail=str(error)) from error
        except (httpx.HTTPError, DataUnavailableError) as error:
            raise HTTPException(status_code=503, detail="Applied restock records unavailable") from error
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
            rows = recommendation_tracking_source().tracking(
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
            if performance_diagnostics_enabled:
                log_event(
                    "tracking.read_failed",
                    category=type(error).__name__,
                    data_stage=getattr(error, "stage", None),
                )
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
            rows = recommendation_tracking_source().tracking(
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
            if performance_diagnostics_enabled:
                log_event(
                    "forecast_performance.read_failed",
                    category=type(error).__name__,
                    data_stage=getattr(error, "stage", None),
                )
            raise HTTPException(
                status_code=503,
                detail="Forecast performance data source is unavailable",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    log_startup_duration(
        "api.create_app",
        app_initialization_started,
        enabled=performance_diagnostics_enabled,
        environment=configured.deployment_environment,
    )
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
