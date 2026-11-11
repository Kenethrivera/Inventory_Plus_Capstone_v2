from __future__ import annotations

from decimal import Decimal
from typing import Any

from app.forecasting import DemandForecast
from app.recommendations import (
    ManualDemandEstimate,
    PreliminaryRestockingInsight,
    RecommendationResult,
)

from .contracts import (
    AnalysisContext,
    ReplenishmentConfiguration,
    SessionProfile,
)


def replenishment_configuration_response(
    configuration: ReplenishmentConfiguration,
) -> dict[str, Any]:
    return {
        "configured": configuration.configured,
        "product_id": configuration.product_id,
        "location_id": configuration.location_id,
        "inventory_unit": configuration.inventory_unit,
        "persistence_available": configuration.persistence_available,
        "supplier_lead_time_days": configuration.supplier_lead_time_days,
        "review_period_days": configuration.review_period_days,
        "safety_stock": _number(configuration.safety_stock),
        "minimum_order_quantity": _number(
            configuration.minimum_order_quantity
        ),
        "supplier_pack_size": _number(configuration.supplier_pack_size),
        "supplier_order_unit": configuration.supplier_order_unit,
        "unit_conversion_factor": _number(
            configuration.unit_conversion_factor
        ),
        "confirmed_incoming_quantity": _number(
            configuration.confirmed_incoming_quantity
        ),
        "incoming_quantity_verified": configuration.incoming_quantity_verified,
        "backorder_quantity": _number(configuration.backorder_quantity),
        "backorder_quantity_verified": configuration.backorder_quantity_verified,
        "supplier_availability": configuration.supplier_availability,
        "data_source": configuration.data_source,
        "source_captured_at": (
            configuration.source_captured_at.isoformat()
            if configuration.source_captured_at
            else None
        ),
        "rationale": configuration.rationale,
        "updated_at": (
            configuration.updated_at.isoformat()
            if configuration.updated_at
            else None
        ),
        "updated_by_profile_id": configuration.updated_by_profile_id,
        "manual_estimate": configuration.data_source == "admin_estimate",
        "capabilities": {
            "inventory_mutation": False,
            "purchase_order_creation": False,
        },
    }


def analysis_response(
    *,
    profile: SessionProfile,
    context: AnalysisContext,
    forecasts: list[DemandForecast],
    preliminary_insight: PreliminaryRestockingInsight,
    recommendation: RecommendationResult,
    generated_at: object,
    manual_demand: ManualDemandEstimate | None,
    requested_model: str,
    requested_history_days: int,
    experimental_fallback_reason: str | None,
    seasonal_context: dict[str, object] | None,
    recommendation_forecast_model: str,
    experimental_forecast_used_for_replenishment: bool,
) -> dict[str, Any]:
    first = forecasts[0]
    metadata = first.metadata
    total = sum((value.quantity for value in forecasts), Decimal("0"))
    calculation = recommendation.calculation
    if (
        calculation.inventory_position is not None
        and calculation.reorder_point is not None
    ):
        at_reorder_point = calculation.inventory_position <= calculation.reorder_point
        alert_status = "at_or_below_reorder_point" if at_reorder_point else "above_reorder_point"
    else:
        at_reorder_point = None
        alert_status = "unknown"
    if (
        recommendation.recommended_quantity_inventory_units is not None
        and recommendation.recommended_quantity_inventory_units > 0
        and at_reorder_point is False
    ):
        policy_message = (
            "Inventory is above the continuous-review reorder alert, but the "
            "periodic review policy recommends topping up to the protection-period target."
        )
    elif at_reorder_point is True:
        policy_message = (
            "Inventory is at or below the reorder point; replenishment requires priority review."
        )
    else:
        policy_message = (
            "The periodic review policy uses the order-up-to target for quantity; "
            "the reorder point is an urgency indicator, not a contradictory order gate."
        )
    synthetic = metadata.data_provenance.value == "synthetic"
    forecast_warnings = list(metadata.data_quality.warnings)
    if metadata.fallback_reason:
        forecast_warnings.append(f"fallback:{metadata.fallback_reason}")
    if metadata.cold_start_reason:
        forecast_warnings.append(f"cold_start:{metadata.cold_start_reason.value}")
    if synthetic:
        forecast_warnings.append(
            "synthetic_development_data_not_production_sales"
        )
    seasonal_by_date = {
        str(value.get("date")): value
        for value in (seasonal_context or {}).get("daily", [])
        if isinstance(value, dict)
    }
    return {
        "schema_version": "stage5d-v1",
        "data_adapter": context.adapter_name,
        "synthetic": synthetic,
        "authorized_scope": {
            "profile_id": profile.profile_id,
            "role": profile.role,
            "location_id": profile.location_id,
        },
        "product": {
            "product_id": context.history.product.product_id,
            "location_id": context.history.product.location_id,
            "sku": context.history.product.sku,
            "name": context.history.product.product_name,
            "unit": context.history.product.unit,
        },
        "replenishment_configuration": (
            replenishment_configuration_response(
                context.replenishment_configuration
            )
            if context.replenishment_configuration is not None
            else None
        ),
        "forecast": {
            "requested_model": requested_model,
            "model": metadata.model_name,
            "version": metadata.model_version,
            "history_window_days_requested": requested_history_days,
            "experimental": requested_model == "seasonal_experimental",
            "fallback": {
                "used": experimental_fallback_reason is not None,
                "reason": experimental_fallback_reason,
                "model": (
                    metadata.model_name
                    if experimental_fallback_reason is not None
                    else None
                ),
            },
            "provenance": metadata.data_provenance.value,
            "generated_at": generated_at.isoformat(),
            "source_data_as_of": context.source_data_as_of.isoformat(),
            "period_start": forecasts[0].forecast_date.isoformat(),
            "period_end": forecasts[-1].forecast_date.isoformat(),
            "horizon_days": len(forecasts),
            "unit": first.unit,
            "total_quantity": _number(total),
            "daily": [
                {
                    "date": value.forecast_date.isoformat(),
                    "quantity": _number(value.quantity),
                    **(
                        {
                            "season": seasonal_by_date[
                                value.forecast_date.isoformat()
                            ].get("season"),
                            "transition": seasonal_by_date[
                                value.forecast_date.isoformat()
                            ].get("transition"),
                        }
                        if value.forecast_date.isoformat() in seasonal_by_date
                        else {}
                    ),
                }
                for value in forecasts
            ],
            "seasonal_context": seasonal_context,
            "cold_start": {
                "is_cold_start": metadata.is_cold_start,
                "reason": (
                    metadata.cold_start_reason.value
                    if metadata.cold_start_reason
                    else None
                ),
                "strategy": (
                    metadata.cold_start_strategy.value
                    if metadata.cold_start_strategy
                    else None
                ),
                "zero_is_unknown_demand": (
                    metadata.is_cold_start
                    and metadata.cold_start_reason is not None
                    and metadata.cold_start_reason.value == "no_history"
                ),
            },
            "calibration": {
                "factor": _number(metadata.calibration_factor),
                "points": metadata.calibration_points,
                "period_end": (
                    metadata.calibration_period_end.isoformat()
                    if metadata.calibration_period_end
                    else None
                ),
            },
            "data_quality": {
                "history_calendar_days": metadata.data_quality.history_calendar_days,
                "observed_sales_days": metadata.data_quality.observed_sales_days,
                "assumed_zero_sales_days": metadata.data_quality.assumed_zero_sales_days,
                "stockout_censored_days": metadata.data_quality.stockout_censored_days,
                "availability_unknown_days": metadata.data_quality.availability_unknown_days,
                "warnings": forecast_warnings,
            },
        },
        "preliminary_restocking_insight": {
            "status": preliminary_insight.status.value,
            "planning_horizon_days": preliminary_insight.planning_horizon_days,
            "predicted_demand": _number(preliminary_insight.predicted_demand),
            "available_inventory": _number(
                preliminary_insight.available_inventory
            ),
            "suggested_restock_quantity": _number(
                preliminary_insight.suggested_restock_quantity
            ),
            "inventory_unit": preliminary_insight.inventory_unit,
            "formula": "max(0, ceiling(predicted demand - available inventory))",
            "forecast_basis": {
                "requested_model": "lightgbm",
                "model": preliminary_insight.forecast_model,
                "version": preliminary_insight.forecast_version,
                "history_window_days": 365,
                "uses_experimental_seasonal_forecast": False,
            },
            "forecast_generated_at": (
                preliminary_insight.forecast_generated_at.isoformat()
            ),
            "forecast_source_data_as_of": (
                preliminary_insight.forecast_source_data_as_of.isoformat()
            ),
            "assumptions": list(preliminary_insight.assumptions),
            "limitations": list(preliminary_insight.limitations),
            "requires_owner_review": preliminary_insight.requires_owner_review,
            "incoming_and_backorders_treated_as_zero": False,
            "inventory_mutation": False,
            "purchase_order_created": False,
        },
        "recommendation": {
            "status": recommendation.status.value,
            "policy_type": "periodic_review_order_up_to",
            "policy_version": recommendation.audit.policy_version,
            "forecast_basis": {
                "model": recommendation_forecast_model,
                "uses_experimental_seasonal_forecast": (
                    experimental_forecast_used_for_replenishment
                ),
                "history_window_days": 365,
                "explanation": (
                    "Replenishment remains isolated on the existing validated "
                    "LightGBM forecast; the experimental seasonal forecast is "
                    "display-only."
                    if requested_model == "seasonal_experimental"
                    else "Replenishment uses the selected forecast output."
                ),
            },
            "reorder_alert": {
                "status": alert_status,
                "at_or_below_reorder_point": at_reorder_point,
                "message": policy_message,
            },
            "inventory_position": _number(calculation.inventory_position),
            "expected_lead_time_demand": _number(
                calculation.expected_lead_time_demand
            ),
            "reorder_point": _number(calculation.reorder_point),
            "safety_stock": _number(calculation.safety_stock),
            "protection_period_days": calculation.protection_period_days,
            "target_inventory": _number(calculation.target_inventory),
            "preliminary_quantity": _number(
                calculation.preliminary_quantity_inventory_units
            ),
            "suggested_quantity": {
                "order_units": _number(
                    recommendation.recommended_quantity_order_units
                ),
                "order_unit": recommendation.supplier_order_unit,
                "inventory_units": _number(
                    recommendation.recommended_quantity_inventory_units
                ),
                "inventory_unit": recommendation.inventory_unit,
            },
            "human_approval_required": recommendation.requires_human_approval,
            "approved_purchase_decision": False,
            "purchase_order_created": recommendation.purchase_order_created,
            "manual_demand_estimate": (
                {
                    "daily_quantity": _number(manual_demand.daily_quantity),
                    "unit": manual_demand.unit,
                    "rationale": manual_demand.rationale,
                    "source": "authenticated_admin_manual_input",
                    "staff_confirmed": True,
                    "confirmed_by_profile_id": profile.profile_id,
                    "confirmed_at": manual_demand.captured_at.isoformat(),
                    "provisional": True,
                    "creates_historical_sales": False,
                }
                if manual_demand is not None
                else None
            ),
            "warnings": list(recommendation.warnings),
            "explanations": list(recommendation.explanations),
            "inventory_snapshot": {
                "captured_at": recommendation.inventory_snapshot.captured_at.isoformat(),
                "saleable_on_hand": _number(
                    recommendation.inventory_snapshot.saleable_on_hand
                ),
                "confirmed_on_order": _number(
                    recommendation.inventory_snapshot.confirmed_on_order
                ),
                "unfulfilled_reservations": _number(
                    recommendation.inventory_snapshot.unfulfilled_reservations
                ),
                "backorders": _number(recommendation.inventory_snapshot.backorders),
                "max_capacity": _number(
                    recommendation.inventory_snapshot.max_capacity
                ),
                "balance_basis": recommendation.inventory_snapshot.balance_basis.value,
            },
            "supplier_snapshot": {
                "supplier_id": recommendation.supplier_snapshot.supplier_id,
                "captured_at": recommendation.supplier_snapshot.captured_at.isoformat(),
                "lead_time_days": recommendation.supplier_snapshot.lead_time_days,
                "minimum_order_quantity": _number(
                    recommendation.supplier_snapshot.minimum_order_quantity
                ),
                "pack_size": _number(recommendation.supplier_snapshot.pack_size),
                "availability": recommendation.supplier_snapshot.availability.value,
            },
        },
        "capabilities": {
            "read_only": True,
            "inventory_mutation": False,
            "purchase_order_creation": False,
        },
    }


def _number(value: Decimal | None) -> float | None:
    return float(value) if value is not None else None
