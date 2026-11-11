from __future__ import annotations

from datetime import datetime, time, timedelta, timezone
from decimal import Decimal

from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    ColdStartReason,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    RollingOriginConfig,
)
from app.recommendations import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    ManualDemandEstimate,
    RecommendationEngine,
    RecommendationPolicy,
    SafetyStockInput,
    SafetyStockSource,
    SupplierAvailability,
    SupplierPolicySnapshot,
)

from .datasets import historical_dataset
from .models import ColdStartLifecycleReport, SyntheticScenario


def evaluate_cold_start_lifecycle(
    scenario: SyntheticScenario,
) -> ColdStartLifecycleReport:
    end = scenario.config.start_date + timedelta(days=scenario.config.days - 1)
    eligible = [
        policy
        for policy in scenario.policies
        if (end - policy.launch_date).days >= 220
    ]
    policy = min(eligible or list(scenario.policies), key=lambda value: value.launch_date)
    registration_origin = policy.launch_date - timedelta(days=1)
    registration = historical_dataset(
        scenario, policy, history_end=registration_origin
    )
    mean = Mean28Forecaster()
    initial_forecast = mean.forecast(
        registration, horizon_days=scenario.config.forecast_horizon_days
    )
    at = datetime.combine(registration_origin, time(hour=12), timezone.utc)
    result = RecommendationEngine().recommend(
        forecast=DemandForecastSnapshot(
            forecasts=tuple(initial_forecast),
            generated_at=at,
            source_data_as_of=at,
        ),
        inventory=InventorySnapshot(
            location_id=policy.location_id,
            product_id=policy.product_id,
            unit=policy.unit,
            saleable_on_hand=policy.opening_stock,
            confirmed_on_order=Decimal("0"),
            unfulfilled_reservations=Decimal("0"),
            backorders=Decimal("0"),
            max_capacity=policy.capacity,
            balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
            captured_at=at,
        ),
        supplier=SupplierPolicySnapshot(
            supplier_id="synthetic-lifecycle-supplier",
            order_unit=policy.unit,
            lead_time_days=policy.lead_time_days,
            minimum_order_quantity=policy.minimum_order_quantity,
            pack_size=policy.pack_size,
            availability=SupplierAvailability.AVAILABLE,
            captured_at=at,
        ),
        safety_stock=SafetyStockInput(
            quantity=policy.safety_stock,
            unit=policy.unit,
            source=SafetyStockSource.EXPLICIT_ASSUMPTION,
            captured_at=at,
        ),
        policy=RecommendationPolicy(
            version="stage6a-cold-start-v1",
            review_period_days=scenario.config.review_period_days,
            max_forecast_age=timedelta(days=1),
            max_inventory_age=timedelta(days=1),
            max_supplier_age=timedelta(days=1),
            max_safety_stock_age=timedelta(days=1),
        ),
        recommendation_at=at,
        manual_demand=ManualDemandEstimate(
            daily_quantity=policy.manual_daily_estimate,
            unit=policy.unit,
            captured_at=at,
            rationale="Stage 6A configured launch estimate",
        ),
    )
    lightgbm = LightGBMForecaster(
        config=LightGBMConfig(
            min_history_days=84,
            min_training_rows=40,
            n_estimators=20,
            num_leaves=10,
            random_seed=scenario.config.seed,
        ),
        mean28=mean,
    )
    blend = CalibratedBlendForecaster(
        config=CalibratedBlendConfig(
            minimum_calibration_points=28,
            rolling_origin=RollingOriginConfig(
                initial_training_days=112,
                horizon_days=28,
                step_days=28,
            ),
        ),
        lightgbm=lightgbm,
        mean28=mean,
    )
    first_insufficient = None
    first_lightgbm = None
    first_blend = None
    current = policy.launch_date
    latest_origin = end - timedelta(days=scenario.config.forecast_horizon_days)
    while current <= latest_origin:
        history = historical_dataset(scenario, policy, history_end=current)
        mean_value = mean.forecast(history, horizon_days=1)[0]
        if (
            first_insufficient is None
            and mean_value.metadata.cold_start_reason
            is ColdStartReason.INSUFFICIENT_HISTORY
        ):
            first_insufficient = current
        if first_lightgbm is None:
            ml_value = lightgbm.forecast(history, horizon_days=1)[0]
            if ml_value.metadata.model_name == "lightgbm":
                first_lightgbm = current
        if first_blend is None:
            blend_value = blend.forecast(history, horizon_days=1)[0]
            if blend_value.metadata.model_name == blend.MODEL_NAME:
                first_blend = current
        if first_lightgbm is not None and first_blend is not None:
            break
        current += timedelta(days=scenario.config.review_period_days)
    return ColdStartLifecycleReport(
        product_id=policy.product_id,
        location_id=policy.location_id,
        registration_state=initial_forecast[0].metadata.cold_start_reason.value,
        zero_is_unknown_demand=True,
        manual_estimate_used=True,
        initial_recommendation_status=result.status.value,
        first_insufficient_history_date=first_insufficient,
        first_lightgbm_eligible_date=first_lightgbm,
        first_blend_eligible_date=first_blend,
        selection_rule=(
            "Eligibility is recorded only when the requested model returns its own "
            "validated model name rather than a Mean28 fallback."
        ),
    )
