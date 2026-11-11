from __future__ import annotations

from dataclasses import replace
from datetime import date, datetime, timedelta
from decimal import Decimal
from uuid import UUID

from app.forecasting import (
    CalibratedBlendForecaster,
    HistoricalDemandDataset,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver
from app.simulation.expanded_seasonal_fixture import shared_context_registry
from app.recommendations import (
    DemandForecastSnapshot,
    ManualDemandEstimate,
    PreliminaryRestockingInsightCalculator,
    RecommendationEngine,
)

from .contracts import (
    AuthorizationError,
    DataUnavailableError,
    ForecastDataAdapter,
    ReplenishmentConfiguration,
    ReplenishmentConfigurationInput,
    SessionProfile,
    TrustedRecommendationSnapshot,
)
from .serialization import analysis_response, replenishment_configuration_response


class ForecastAnalysisService:
    STANDARD_HISTORY_DAYS = 365
    EXPERIMENTAL_HISTORY_DAYS = 1095

    def __init__(self, adapter: ForecastDataAdapter) -> None:
        self._adapter = adapter
        self._mean28 = Mean28Forecaster()
        self._lightgbm = LightGBMForecaster(mean28=self._mean28)
        self._blend = CalibratedBlendForecaster(
            mean28=self._mean28, lightgbm=self._lightgbm
        )
        self._seasonal_registry = shared_context_registry()
        self._season_resolver = PhilippineSeasonResolver()
        self._seasonal_experimental = ProductSpecificSeasonalLightGBMForecaster(
            registry=self._seasonal_registry,
            include_seasonal_features=True,
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=120,
                learning_rate=0.03,
                num_leaves=10,
                random_seed=26061110,
            ),
            mean28=self._mean28,
            resolver=self._season_resolver,
            zero_never_sold_forecasts=True,
        )
        self._recommendations = RecommendationEngine()
        self._preliminary_insights = PreliminaryRestockingInsightCalculator()

    def get_replenishment_configuration(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
        product_id: str,
    ) -> dict[str, object]:
        profile = self._authorized_profile(
            session_token=session_token,
            requested_location_id=requested_location_id,
            product_id=product_id,
        )
        configuration = self._adapter.load_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
        )
        self._validate_configuration_scope(configuration, profile, product_id)
        return replenishment_configuration_response(configuration)

    def save_replenishment_configuration(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
        product_id: str,
        configuration: ReplenishmentConfigurationInput,
        now: datetime,
    ) -> dict[str, object]:
        profile = self._authorized_profile(
            session_token=session_token,
            requested_location_id=requested_location_id,
            product_id=product_id,
        )
        current = self._adapter.load_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
        )
        self._validate_configuration_scope(current, profile, product_id)
        self._validate_configuration_input(
            configuration,
            inventory_unit=current.inventory_unit,
            now=now,
        )
        saved = self._adapter.save_replenishment_configuration(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
            configuration=configuration,
        )
        self._validate_configuration_scope(saved, profile, product_id)
        return replenishment_configuration_response(saved)

    def _authorized_profile(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
        product_id: str,
    ) -> SessionProfile:
        try:
            UUID(product_id)
        except ValueError as error:
            raise ValueError("product_id must be a UUID") from error
        return self.authorize_admin(
            session_token=session_token,
            requested_location_id=requested_location_id,
        )

    def authorize_admin(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
    ) -> SessionProfile:
        profile = self._adapter.authenticate(session_token)
        if profile.role != "admin":
            raise AuthorizationError("Forecasting is restricted to Admin profiles")
        if (
            requested_location_id is not None
            and requested_location_id.strip()
            and requested_location_id.strip() != profile.location_id
        ):
            raise AuthorizationError(
                "Requested location is outside the authenticated session"
            )
        return profile

    def trusted_preliminary_snapshot(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
        product_id: str,
        forecast_generated_at: datetime,
    ) -> TrustedRecommendationSnapshot:
        """Recompute the only forecast eligible for persistence.

        No client-provided demand, stock, model, or suggested quantity enters
        this calculation. The standard 365-day context and the production
        LightGBM/preliminary calculator are reused directly.
        """
        if forecast_generated_at.tzinfo is None:
            raise ValueError("forecast_generated_at must include a timezone")
        profile = self._authorized_profile(
            session_token=session_token,
            requested_location_id=requested_location_id,
            product_id=product_id,
        )
        context = self._adapter.load_analysis_context(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
            now=forecast_generated_at,
            history_days=self.STANDARD_HISTORY_DAYS,
        )
        if (
            context.history.product.location_id != profile.location_id
            or context.history.product.product_id != product_id
            or context.inventory.location_id != profile.location_id
            or context.inventory.product_id != product_id
        ):
            raise DataUnavailableError(
                "Adapter returned data outside the authenticated product/location scope"
            )
        forecasts = self._lightgbm.forecast(
            context.history,
            horizon_days=self._preliminary_insights.PLANNING_HORIZON_DAYS,
        )
        if any(
            value.metadata.model_name != self._lightgbm.MODEL_NAME
            or value.metadata.model_version != self._lightgbm.MODEL_VERSION
            for value in forecasts
        ):
            raise DataUnavailableError(
                "The approved LightGBM forecast is unavailable for persistence",
                stage="trusted_recommendation:lightgbm_fallback",
            )
        insight = self._preliminary_insights.calculate(
            forecast=DemandForecastSnapshot(
                forecasts=tuple(forecasts),
                generated_at=forecast_generated_at,
                source_data_as_of=context.source_data_as_of,
            ),
            inventory=context.inventory,
        )
        if (
            insight.predicted_demand is None
            or insight.available_inventory is None
            or insight.suggested_restock_quantity is None
        ):
            raise DataUnavailableError(
                "A complete approved preliminary insight is required for persistence",
                stage="trusted_recommendation:incomplete_preliminary_insight",
            )
        return TrustedRecommendationSnapshot(
            location_id=profile.location_id,
            product_id=product_id,
            forecast_model=insight.forecast_model,
            forecast_version=insight.forecast_version,
            training_history_days=self.STANDARD_HISTORY_DAYS,
            experimental_model=False,
            forecast_generated_at=insight.forecast_generated_at,
            forecast_source_data_as_of=insight.forecast_source_data_as_of,
            planning_horizon_days=insight.planning_horizon_days,
            forecast_period_start=forecasts[0].forecast_date,
            forecast_period_end=forecasts[-1].forecast_date,
            predicted_demand=insight.predicted_demand,
            available_inventory=insight.available_inventory,
            recommended_restock_quantity=insight.suggested_restock_quantity,
            inventory_unit=insight.inventory_unit,
            assumptions=insight.assumptions,
        )

    @staticmethod
    def _validate_configuration_scope(
        configuration: ReplenishmentConfiguration,
        profile: SessionProfile,
        product_id: str,
    ) -> None:
        if (
            configuration.product_id != product_id
            or configuration.location_id != profile.location_id
        ):
            raise DataUnavailableError(
                "Replenishment configuration is outside the authenticated scope"
            )

    @staticmethod
    def _validate_configuration_input(
        configuration: ReplenishmentConfigurationInput,
        *,
        inventory_unit: str,
        now: datetime,
    ) -> None:
        if not configuration.source_captured_at.tzinfo:
            raise ValueError("source_captured_at must include a timezone")
        if configuration.source_captured_at > now + timedelta(minutes=5):
            raise ValueError("source_captured_at cannot be in the future")
        if configuration.data_source not in {"admin_estimate", "verified_record"}:
            raise ValueError("data_source must be admin_estimate or verified_record")
        if (
            configuration.data_source == "admin_estimate"
            and not (configuration.rationale or "").strip()
        ):
            raise ValueError("Admin estimates require a rationale")
        if configuration.supplier_lead_time_days is not None and not (
            0 <= configuration.supplier_lead_time_days <= 3650
        ):
            raise ValueError("supplier_lead_time_days must be between 0 and 3650")
        if configuration.review_period_days is not None and not (
            0 <= configuration.review_period_days <= 365
        ):
            raise ValueError("review_period_days must be between 0 and 365")
        for name, value in (
            ("safety_stock", configuration.safety_stock),
            ("minimum_order_quantity", configuration.minimum_order_quantity),
            (
                "confirmed_incoming_quantity",
                configuration.confirmed_incoming_quantity,
            ),
            ("backorder_quantity", configuration.backorder_quantity),
        ):
            if value is not None and (not value.is_finite() or value < 0):
                raise ValueError(f"{name} must be finite and nonnegative")
        for name, value in (
            ("supplier_pack_size", configuration.supplier_pack_size),
            ("unit_conversion_factor", configuration.unit_conversion_factor),
        ):
            if value is not None and (not value.is_finite() or value <= 0):
                raise ValueError(f"{name} must be finite and positive")
        if configuration.incoming_quantity_verified != (
            configuration.confirmed_incoming_quantity is not None
        ):
            raise ValueError("Incoming quantity must be present only when verified")
        if configuration.backorder_quantity_verified != (
            configuration.backorder_quantity is not None
        ):
            raise ValueError("Backorder quantity must be present only when verified")
        order_unit = (configuration.supplier_order_unit or "").strip()
        if (
            configuration.minimum_order_quantity is not None
            or configuration.supplier_pack_size is not None
        ) and not order_unit:
            raise ValueError("supplier_order_unit is required for MOQ or pack size")
        if configuration.unit_conversion_factor is not None and not order_unit:
            raise ValueError("supplier_order_unit is required for unit conversion")
        if (
            order_unit
            and order_unit.lower() != inventory_unit.lower()
            and configuration.unit_conversion_factor is None
        ):
            raise ValueError("unit_conversion_factor is required for different units")
        availability = configuration.supplier_availability
        if availability not in {None, "available", "unavailable", "unknown"}:
            raise ValueError("supplier_availability is invalid")

    def analyze(
        self,
        *,
        session_token: str,
        requested_location_id: str | None,
        product_id: str,
        model: str,
        horizon_days: int,
        now: datetime,
        manual_daily_demand: Decimal | None = None,
        manual_unit: str | None = None,
        manual_rationale: str | None = None,
        manual_confirmed: bool = False,
    ) -> dict[str, object]:
        try:
            UUID(product_id)
        except ValueError as error:
            raise ValueError("product_id must be a UUID") from error
        if not 1 <= horizon_days <= 90:
            raise ValueError("horizon_days must be between 1 and 90")
        normalized_model = model.strip().lower()
        if normalized_model == "calibrated_blend":
            normalized_model = "blend"
        if normalized_model not in {
            "mean28",
            "lightgbm",
            "blend",
            "seasonal_experimental",
        }:
            raise ValueError(
                "model must be mean28, lightgbm, blend, calibrated_blend, "
                "or seasonal_experimental"
            )

        profile = self._authorized_profile(
            session_token=session_token,
            requested_location_id=requested_location_id,
            product_id=product_id,
        )
        context = self._adapter.load_analysis_context(
            profile=profile,
            session_token=session_token,
            product_id=product_id,
            now=now,
            history_days=(
                self.EXPERIMENTAL_HISTORY_DAYS
                if normalized_model == "seasonal_experimental"
                else self.STANDARD_HISTORY_DAYS
            ),
        )
        if (
            context.history.product.location_id != profile.location_id
            or context.history.product.product_id != product_id
            or context.inventory.location_id != profile.location_id
            or context.inventory.product_id != product_id
        ):
            raise DataUnavailableError(
                "Adapter returned data outside the authenticated product/location scope"
            )

        experimental_fallback_reason = None
        seasonal_context = None
        recommendation_history = context.history
        if normalized_model == "seasonal_experimental":
            recommendation_history = self._bounded_history(
                context.history,
                history_days=self.STANDARD_HISTORY_DAYS,
            )
            candidate = self._seasonal_experimental.forecast(
                context.history, horizon_days=horizon_days
            )
            if candidate[0].metadata.model_name == self._seasonal_experimental.model_name:
                forecasts = candidate
            else:
                experimental_fallback_reason = (
                    candidate[0].metadata.fallback_reason
                    or "experimental_candidate_unavailable"
                )
                forecasts = self._lightgbm.forecast(
                    recommendation_history, horizon_days=horizon_days
                )
            seasonal_context = self._seasonal_context(
                product_id=product_id,
                location_id=profile.location_id,
                forecast_start=forecasts[0].forecast_date,
                forecast_end=forecasts[-1].forecast_date,
                fallback_reason=experimental_fallback_reason,
            )
        else:
            forecaster = {
                "mean28": self._mean28,
                "lightgbm": self._lightgbm,
                "blend": self._blend,
            }[normalized_model]
            forecasts = forecaster.forecast(
                context.history, horizon_days=horizon_days
            )
        manual = None
        manual_fields_present = any(
            (
                manual_daily_demand is not None,
                bool((manual_unit or "").strip()),
                bool((manual_rationale or "").strip()),
                manual_confirmed,
            )
        )
        if manual_fields_present and manual_daily_demand is None:
            raise ValueError(
                "manual_daily_demand is required with manual estimate metadata"
            )
        if manual_daily_demand is not None:
            if not forecasts[0].metadata.is_cold_start:
                raise ValueError(
                    "manual demand estimates are only permitted for cold-start forecasts"
                )
            if manual_daily_demand < 0 or not manual_daily_demand.is_finite():
                raise ValueError("manual_daily_demand must be finite and nonnegative")
            if not (manual_unit or "").strip() or not (manual_rationale or "").strip():
                raise ValueError(
                    "manual_unit and manual_rationale are required with manual demand"
                )
            if not manual_confirmed:
                raise ValueError(
                    "manual demand estimate requires explicit staff confirmation"
                )
            manual = ManualDemandEstimate(
                daily_quantity=manual_daily_demand,
                unit=manual_unit or "",
                captured_at=now,
                rationale=manual_rationale or "",
            )
        recommendation_forecasts = forecasts
        if normalized_model == "seasonal_experimental":
            recommendation_forecasts = self._lightgbm.forecast(
                recommendation_history, horizon_days=horizon_days
            )
        if (
            horizon_days == self._preliminary_insights.PLANNING_HORIZON_DAYS
            and normalized_model in {"lightgbm", "seasonal_experimental"}
        ):
            preliminary_forecasts = recommendation_forecasts
        else:
            preliminary_forecasts = self._lightgbm.forecast(
                recommendation_history,
                horizon_days=self._preliminary_insights.PLANNING_HORIZON_DAYS,
            )
        preliminary_insight = self._preliminary_insights.calculate(
            forecast=DemandForecastSnapshot(
                forecasts=tuple(preliminary_forecasts),
                generated_at=now,
                source_data_as_of=context.source_data_as_of,
            ),
            inventory=context.inventory,
        )
        recommendation = self._recommendations.recommend(
            forecast=DemandForecastSnapshot(
                forecasts=tuple(recommendation_forecasts),
                generated_at=now,
                source_data_as_of=context.source_data_as_of,
            ),
            inventory=context.inventory,
            supplier=context.supplier,
            safety_stock=context.safety_stock,
            policy=context.policy,
            recommendation_at=now,
            conversions=context.conversions,
            manual_demand=manual,
        )
        return analysis_response(
            profile=profile,
            context=context,
            forecasts=forecasts,
            preliminary_insight=preliminary_insight,
            recommendation=recommendation,
            generated_at=now,
            manual_demand=manual,
            requested_model=normalized_model,
            requested_history_days=(
                self.EXPERIMENTAL_HISTORY_DAYS
                if normalized_model == "seasonal_experimental"
                else self.STANDARD_HISTORY_DAYS
            ),
            experimental_fallback_reason=experimental_fallback_reason,
            seasonal_context=seasonal_context,
            recommendation_forecast_model=(
                recommendation_forecasts[0].metadata.model_name
            ),
            experimental_forecast_used_for_replenishment=False,
        )

    @staticmethod
    def _bounded_history(
        history: HistoricalDemandDataset,
        *,
        history_days: int,
    ) -> HistoricalDemandDataset:
        if history.history_start is None:
            return history
        start = max(
            history.history_start,
            history.history_end - timedelta(days=history_days - 1),
        )
        return replace(
            history,
            history_start=start,
            observations=tuple(
                value
                for value in history.observations
                if start <= value.business_date <= history.history_end
            ),
            availability_evidence=tuple(
                value
                for value in history.availability_evidence
                if start <= value.business_date <= history.history_end
            ),
        )

    def _seasonal_context(
        self,
        *,
        product_id: str,
        location_id: str,
        forecast_start: date,
        forecast_end: date,
        fallback_reason: str | None,
    ) -> dict[str, object]:
        try:
            product_context = self._seasonal_registry.require(product_id)
        except ValueError:
            product_context = None

        try:
            self._season_resolver.location_profile(location_id)
        except ValueError as error:
            return {
                "calendar_version": self._season_resolver.CALENDAR_VERSION,
                "source_name": self._season_resolver.PAGASA_SOURCE_NAME,
                "source_url": self._season_resolver.PAGASA_SOURCE_URL,
                "numerical_multiplier_applied": False,
                "classification": {
                    "seasonal_relevance": "unknown",
                    "match_type": "unavailable",
                    "evidence_level": "insufficient",
                    "registry_version": self._seasonal_registry.version,
                    "simulation_hypothesis": False,
                },
                "daily": [],
                "next_transition": None,
                "transitions_in_horizon": [],
                "experimental_fallback_reason": fallback_reason,
                "calendar_error": str(error),
            }

        daily = []
        current = forecast_start
        while current <= forecast_end:
            resolved = self._season_resolver.resolve(location_id, current)
            daily.append(
                {
                    "date": current.isoformat(),
                    "season": resolved.season.value,
                    "transition": resolved.transition.value,
                }
            )
            current += timedelta(days=1)

        transitions: list[dict[str, str]] = []
        previous = None
        current = forecast_start
        while current <= forecast_start + timedelta(days=366):
            resolved = self._season_resolver.resolve(location_id, current)
            transition = resolved.transition.value
            if transition != "none" and transition != previous:
                transitions.append(
                    {"date": current.isoformat(), "transition": transition}
                )
            previous = transition
            current += timedelta(days=1)

        return {
            "calendar_version": self._season_resolver.CALENDAR_VERSION,
            "source_name": self._season_resolver.PAGASA_SOURCE_NAME,
            "source_url": self._season_resolver.PAGASA_SOURCE_URL,
            "numerical_multiplier_applied": False,
            "classification": {
                "seasonal_relevance": (
                    product_context.seasonal_relevance
                    if product_context is not None
                    else "unknown"
                ),
                "match_type": (
                    product_context.seasonal_match_type
                    if product_context is not None
                    else "unavailable"
                ),
                "evidence_level": (
                    product_context.evidence_level
                    if product_context is not None
                    else "insufficient"
                ),
                "registry_version": self._seasonal_registry.version,
                "simulation_hypothesis": product_context is not None,
            },
            "daily": daily,
            "next_transition": transitions[0] if transitions else None,
            "transitions_in_horizon": [
                value
                for value in transitions
                if value["date"] <= forecast_end.isoformat()
            ],
            "experimental_fallback_reason": fallback_reason,
        }
