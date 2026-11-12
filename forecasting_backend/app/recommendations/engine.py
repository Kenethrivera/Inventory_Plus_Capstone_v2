from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timedelta
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR
from typing import Callable, Iterable

from app.forecasting.models import ColdStartReason, DemandForecast

from .models import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    ManualDemandEstimate,
    RecommendationAuditMetadata,
    RecommendationCalculation,
    RecommendationPolicy,
    RecommendationResult,
    RecommendationStatus,
    SafetyStockInput,
    SupplierAvailability,
    SupplierPolicySnapshot,
    UnitConversion,
)


class RecommendationEngine:
    """Pure, deterministic replenishment math; never creates purchase orders."""

    def recommend(
        self,
        *,
        forecast: DemandForecastSnapshot,
        inventory: InventorySnapshot,
        supplier: SupplierPolicySnapshot,
        safety_stock: SafetyStockInput | None,
        policy: RecommendationPolicy,
        recommendation_at: datetime,
        conversions: Iterable[UnitConversion] = (),
        manual_demand: ManualDemandEstimate | None = None,
    ) -> RecommendationResult:
        warnings: list[str] = []
        explanations: list[str] = []
        calculations = RecommendationCalculation()
        forecast_values = list(forecast.forecasts)
        first = forecast_values[0] if forecast_values else None
        audit = RecommendationAuditMetadata(
            recommendation_at=recommendation_at,
            forecast_generated_at=forecast.generated_at,
            forecast_source_data_as_of=forecast.source_data_as_of,
            inventory_snapshot_at=inventory.captured_at,
            supplier_snapshot_at=supplier.captured_at,
            safety_stock_snapshot_at=(
                safety_stock.captured_at if safety_stock is not None else None
            ),
            safety_stock_source=(
                safety_stock.source if safety_stock is not None else None
            ),
            manual_estimate_at=(
                manual_demand.captured_at if manual_demand is not None else None
            ),
            forecast_model=(first.metadata.model_name if first else None),
            forecast_version=(first.metadata.model_version if first else None),
            forecast_provenance=(first.metadata.data_provenance if first else None),
            forecast_data_quality=(first.metadata.data_quality if first else None),
            policy_version=policy.version,
        )

        def review(code: str, explanation: str) -> None:
            if code not in warnings:
                warnings.append(code)
            explanations.append(explanation)

        if not self._timestamp_is_aware(recommendation_at):
            review("recommendation_timestamp_invalid", "Recommendation time must be timezone-aware.")
        if policy.review_period_days is None:
            review(
                "review_period_missing",
                "Inventory review period is required; an unknown value is not zero.",
            )
        elif policy.review_period_days < 0:
            review("review_period_invalid", "Review period cannot be negative.")
        if not policy.version.strip():
            review("policy_version_missing", "A recommendation policy version is required.")

        self._check_age(
            forecast.generated_at,
            recommendation_at,
            policy.max_forecast_age,
            "forecast",
            review,
        )
        self._check_age(
            forecast.source_data_as_of,
            recommendation_at,
            policy.max_forecast_age,
            "forecast_source_data",
            review,
        )
        self._check_age(
            inventory.captured_at,
            recommendation_at,
            policy.max_inventory_age,
            "inventory_snapshot",
            review,
        )
        self._check_age(
            supplier.captured_at,
            recommendation_at,
            policy.max_supplier_age,
            "supplier_snapshot",
            review,
        )
        if safety_stock is not None:
            self._check_age(
                safety_stock.captured_at,
                recommendation_at,
                policy.max_safety_stock_age,
                "safety_stock",
                review,
            )
        if manual_demand is not None:
            self._check_age(
                manual_demand.captured_at,
                recommendation_at,
                policy.max_manual_estimate_age,
                "manual_demand",
                review,
            )

        if not forecast_values:
            review("forecast_missing", "No numerical forecast was supplied.")
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )
        if any(
            value.location_id != inventory.location_id
            or value.product_id != inventory.product_id
            for value in forecast_values
        ):
            review(
                "forecast_identity_mismatch",
                "Forecast product/location does not match the inventory snapshot.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )
        if not self._forecast_is_consistent(forecast_values):
            review(
                "forecast_contract_invalid",
                "Forecast dates or metadata are not one consistent chronological series.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )

        numeric_inventory = {
            "saleable_on_hand": inventory.saleable_on_hand,
            "confirmed_on_order": inventory.confirmed_on_order,
            "unfulfilled_reservations": inventory.unfulfilled_reservations,
            "backorders": inventory.backorders,
        }
        for name, value in numeric_inventory.items():
            if value is None:
                review(f"{name}_missing", f"{name.replace('_', ' ').title()} is required.")
            elif not self._nonnegative_finite(value):
                review(f"{name}_invalid", f"{name.replace('_', ' ').title()} must be finite and nonnegative.")
        if supplier.lead_time_days is None:
            review("supplier_lead_time_missing", "Supplier lead time is required.")
        elif supplier.lead_time_days < 0:
            review("supplier_lead_time_invalid", "Supplier lead time cannot be negative.")
        if safety_stock is None:
            review(
                "safety_stock_missing",
                "Safety stock must be actual, configured, or an explicit assumption.",
            )
        if supplier.minimum_order_quantity is None:
            review("supplier_moq_missing", "Supplier MOQ must be explicitly configured.")
        elif not self._nonnegative_finite(supplier.minimum_order_quantity):
            review("supplier_moq_invalid", "Supplier MOQ must be finite and nonnegative.")
        if supplier.pack_size is None:
            review("supplier_pack_size_missing", "Supplier pack size must be explicitly configured.")
        elif not self._positive_finite(supplier.pack_size):
            review("supplier_pack_size_invalid", "Supplier pack size must be finite and positive.")
        if supplier.availability is not SupplierAvailability.AVAILABLE:
            review(
                "supplier_unavailable_or_unknown",
                "Supplier availability is unavailable or unknown; ordering requires review.",
            )

        blocking_codes = {
            "review_period_missing",
            "review_period_invalid",
            "saleable_on_hand_missing",
            "saleable_on_hand_invalid",
            "confirmed_on_order_missing",
            "confirmed_on_order_invalid",
            "unfulfilled_reservations_missing",
            "unfulfilled_reservations_invalid",
            "backorders_missing",
            "backorders_invalid",
            "supplier_lead_time_missing",
            "supplier_lead_time_invalid",
            "safety_stock_missing",
        }
        if any(code in blocking_codes for code in warnings):
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )

        assert policy.review_period_days is not None
        assert inventory.saleable_on_hand is not None
        assert inventory.confirmed_on_order is not None
        assert inventory.unfulfilled_reservations is not None
        assert inventory.backorders is not None
        assert supplier.lead_time_days is not None
        assert supplier.lead_time_days >= 0
        assert safety_stock is not None
        if inventory.balance_basis is InventoryBalanceBasis.NET_OF_RESERVATIONS:
            gross_equivalent = (
                inventory.saleable_on_hand + inventory.unfulfilled_reservations
            )
            explanations.append(
                "On-hand is net of reservations; reservations are added back only to "
                "form a gross equivalent before applying the inventory-position formula."
            )
        else:
            gross_equivalent = inventory.saleable_on_hand
        inventory_position = (
            gross_equivalent
            + inventory.confirmed_on_order
            - inventory.unfulfilled_reservations
            - inventory.backorders
        )
        calculations = replace(
            calculations,
            gross_on_hand_equivalent=gross_equivalent,
            inventory_position=inventory_position,
        )
        explanations.append(
            "Inventory position = gross on-hand equivalent + confirmed on-order "
            "− unfulfilled reservations − backorders "
            f"= {inventory_position} {inventory.unit}."
        )

        conversion_list = tuple(conversions)
        safety_value = self._convert(
            safety_stock.quantity, safety_stock.unit, inventory.unit, conversion_list
        )
        if safety_value is None or not self._nonnegative_finite(safety_value):
            review(
                "safety_stock_unit_incompatible",
                "Safety stock cannot be converted to the inventory unit.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )

        cold_reason = first.metadata.cold_start_reason
        use_manual = cold_reason is not None and manual_demand is not None
        if cold_reason is ColdStartReason.NO_HISTORY and manual_demand is None:
            review(
                "no_history_demand_unknown",
                "A no-history zero forecast is unknown demand, not confirmed zero demand; "
                "provide a manual estimate.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )
        if cold_reason is not None and manual_demand is None:
            review(
                "cold_start_forecast_requires_review",
                "Insufficient history makes the numerical recommendation provisional.",
            )
        if use_manual:
            assert manual_demand is not None
            review(
                "cold_start_manual_demand_estimate_used",
                "Historical demand is insufficient; calculations use a manual estimate "
                "and require human review.",
            )
            manual_daily = self._convert(
                manual_demand.daily_quantity,
                manual_demand.unit,
                inventory.unit,
                conversion_list,
            )
            if not manual_demand.rationale.strip():
                review(
                    "manual_demand_rationale_missing",
                    "A cold-start manual demand estimate requires a rationale.",
                )
            if manual_daily is None or not self._nonnegative_finite(manual_daily):
                review(
                    "manual_demand_unit_incompatible",
                    "Manual demand cannot be converted to the inventory unit.",
                )
                return self._result(
                    inventory, supplier, calculations, warnings, explanations, audit
                )
            explanations.append(
                f"Cold-start demand uses the explicit manual estimate: "
                f"{manual_daily} {inventory.unit}/day ({manual_demand.rationale})."
            )
        else:
            manual_daily = None

        lead_days = supplier.lead_time_days
        protection_days = lead_days + policy.review_period_days
        lead_demand = self._demand_for_days(
            forecast_values,
            lead_days,
            inventory.unit,
            conversion_list,
            manual_daily,
            warnings,
            explanations,
        )
        protection_demand = self._demand_for_days(
            forecast_values,
            protection_days,
            inventory.unit,
            conversion_list,
            manual_daily,
            warnings,
            explanations,
        )
        if lead_demand is None or protection_demand is None:
            review(
                "forecast_unit_incompatible",
                "Forecast demand cannot be converted to the inventory unit.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )

        reorder_point = lead_demand + safety_value
        target = protection_demand + safety_value
        preliminary = max(Decimal("0"), target - inventory_position)
        calculations = replace(
            calculations,
            expected_lead_time_demand=lead_demand,
            safety_stock=safety_value,
            reorder_point=reorder_point,
            protection_period_days=protection_days,
            forecasted_protection_period_demand=protection_demand,
            target_inventory=target,
            preliminary_quantity_inventory_units=preliminary,
        )
        explanations.extend(
            [
                f"Reorder point = lead-time demand {lead_demand} + safety stock "
                f"{safety_value} = {reorder_point} {inventory.unit}.",
                f"Protection period = lead time {lead_days} + review period "
                f"{policy.review_period_days} = {protection_days} days.",
                f"Target inventory = protection-period demand {protection_demand} + "
                f"safety stock {safety_value} = {target} {inventory.unit}.",
                f"Preliminary quantity = max(0, {target} − {inventory_position}) "
                f"= {preliminary} {inventory.unit}.",
            ]
        )
        if preliminary == 0:
            status = (
                RecommendationStatus.NEEDS_REVIEW
                if warnings
                else RecommendationStatus.SUFFICIENT_INVENTORY
            )
            return RecommendationResult(
                status=status,
                location_id=inventory.location_id,
                product_id=inventory.product_id,
                inventory_unit=inventory.unit,
                supplier_order_unit=supplier.order_unit,
                inventory_snapshot=inventory,
                supplier_snapshot=supplier,
                recommended_quantity_order_units=Decimal("0"),
                recommended_quantity_inventory_units=Decimal("0"),
                calculation=calculations,
                warnings=tuple(warnings),
                explanations=tuple(explanations),
                audit=audit,
                requires_human_approval=status is RecommendationStatus.NEEDS_REVIEW,
            )

        if (
            supplier.minimum_order_quantity is None
            or not self._nonnegative_finite(supplier.minimum_order_quantity)
            or supplier.pack_size is None
            or not self._positive_finite(supplier.pack_size)
        ):
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )
        inventory_per_order_unit = self._convert(
            Decimal("1"), supplier.order_unit, inventory.unit, conversion_list
        )
        if inventory_per_order_unit is None or not self._positive_finite(
            inventory_per_order_unit
        ):
            review(
                "supplier_unit_incompatible",
                "Supplier order unit cannot be converted to the inventory unit.",
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )
        order_units = preliminary / inventory_per_order_unit
        order_units = max(order_units, supplier.minimum_order_quantity)
        order_units = self._round_up(order_units, supplier.pack_size)
        inventory_units = order_units * inventory_per_order_unit
        explanations.append(
            f"MOQ and pack rounding produce {order_units} {supplier.order_unit} "
            f"= {inventory_units} {inventory.unit}."
        )

        if inventory.max_capacity is None or not self._nonnegative_finite(
            inventory.max_capacity
        ):
            review(
                "storage_capacity_missing_or_invalid",
                "A valid configured maximum capacity is required before ordering.",
            )
            calculations = replace(
                calculations,
                rounded_quantity_order_units=order_units,
                rounded_quantity_inventory_units=inventory_units,
            )
            return self._result(
                inventory, supplier, calculations, warnings, explanations, audit
            )

        physical_on_hand = gross_equivalent
        capacity_room = max(
            Decimal("0"),
            inventory.max_capacity
            - physical_on_hand
            - inventory.confirmed_on_order,
        )
        calculations = replace(
            calculations,
            rounded_quantity_order_units=order_units,
            rounded_quantity_inventory_units=inventory_units,
            capacity_room_inventory_units=capacity_room,
        )
        if inventory_units > capacity_room:
            feasible_order_units = self._round_down(
                capacity_room / inventory_per_order_unit, supplier.pack_size
            )
            if feasible_order_units < supplier.minimum_order_quantity:
                review(
                    "capacity_conflicts_with_supplier_constraints",
                    "Storage capacity cannot fit the supplier MOQ/pack requirement.",
                )
                return self._result(
                    inventory, supplier, calculations, warnings, explanations, audit
                )
            review(
                "capacity_limits_recommendation",
                "Capacity permits less than the target quantity; the feasible packed "
                "quantity requires human review.",
            )
            order_units = feasible_order_units
            inventory_units = order_units * inventory_per_order_unit

        status = (
            RecommendationStatus.NEEDS_REVIEW
            if warnings
            else RecommendationStatus.RECOMMEND_ORDER
        )
        return RecommendationResult(
            status=status,
            location_id=inventory.location_id,
            product_id=inventory.product_id,
            inventory_unit=inventory.unit,
            supplier_order_unit=supplier.order_unit,
            inventory_snapshot=inventory,
            supplier_snapshot=supplier,
            recommended_quantity_order_units=order_units,
            recommended_quantity_inventory_units=inventory_units,
            calculation=calculations,
            warnings=tuple(warnings),
            explanations=tuple(explanations),
            audit=audit,
            requires_human_approval=True,
        )

    @staticmethod
    def _result(
        inventory: InventorySnapshot,
        supplier: SupplierPolicySnapshot,
        calculation: RecommendationCalculation,
        warnings: list[str],
        explanations: list[str],
        audit: RecommendationAuditMetadata,
    ) -> RecommendationResult:
        return RecommendationResult(
            status=RecommendationStatus.NEEDS_REVIEW,
            location_id=inventory.location_id,
            product_id=inventory.product_id,
            inventory_unit=inventory.unit,
            supplier_order_unit=supplier.order_unit,
            inventory_snapshot=inventory,
            supplier_snapshot=supplier,
            recommended_quantity_order_units=None,
            recommended_quantity_inventory_units=None,
            calculation=calculation,
            warnings=tuple(warnings),
            explanations=tuple(explanations),
            audit=audit,
            requires_human_approval=True,
        )

    @staticmethod
    def _nonnegative_finite(value: Decimal) -> bool:
        return isinstance(value, Decimal) and value.is_finite() and value >= 0

    @staticmethod
    def _positive_finite(value: Decimal) -> bool:
        return isinstance(value, Decimal) and value.is_finite() and value > 0

    @staticmethod
    def _timestamp_is_aware(value: datetime) -> bool:
        return value.tzinfo is not None and value.utcoffset() is not None

    def _check_age(
        self,
        captured_at: datetime,
        now: datetime,
        maximum_age: timedelta,
        label: str,
        review: Callable[[str, str], None],
    ) -> None:
        if not self._timestamp_is_aware(captured_at) or not self._timestamp_is_aware(now):
            review(f"{label}_timestamp_invalid", f"{label} timestamp must be timezone-aware.")
        elif captured_at > now:
            review(f"{label}_timestamp_future", f"{label} timestamp is in the future.")
        elif now - captured_at > maximum_age:
            review(f"{label}_stale", f"{label} is older than policy allows.")

    @staticmethod
    def _forecast_is_consistent(values: list[DemandForecast]) -> bool:
        first = values[0]
        for index, value in enumerate(values):
            if value.forecast_date != first.forecast_date + timedelta(days=index):
                return False
            if (
                value.metadata.model_name != first.metadata.model_name
                or value.metadata.model_version != first.metadata.model_version
                or value.metadata.data_provenance != first.metadata.data_provenance
            ):
                return False
            if not value.quantity.is_finite() or value.quantity < 0:
                return False
        return True

    @staticmethod
    def _convert(
        quantity: Decimal,
        from_unit: str,
        to_unit: str,
        conversions: tuple[UnitConversion, ...],
    ) -> Decimal | None:
        source = from_unit.strip().lower()
        target = to_unit.strip().lower()
        if not source or not target:
            return None
        if source == target:
            return quantity
        for conversion in conversions:
            if not conversion.factor.is_finite() or conversion.factor <= 0:
                continue
            left = conversion.from_unit.strip().lower()
            right = conversion.to_unit.strip().lower()
            if left == source and right == target:
                return quantity * conversion.factor
            if left == target and right == source:
                return quantity / conversion.factor
        return None

    def _demand_for_days(
        self,
        forecasts: list[DemandForecast],
        days: int,
        inventory_unit: str,
        conversions: tuple[UnitConversion, ...],
        manual_daily: Decimal | None,
        warnings: list[str],
        explanations: list[str],
    ) -> Decimal | None:
        if days == 0:
            return Decimal("0")
        if manual_daily is not None:
            return manual_daily * Decimal(days)
        converted: list[Decimal] = []
        for value in forecasts:
            quantity = self._convert(
                value.quantity, value.unit, inventory_unit, conversions
            )
            if quantity is None:
                return None
            converted.append(quantity)
        if days <= len(converted):
            return sum(converted[:days], Decimal("0"))
        daily_average = sum(converted, Decimal("0")) / Decimal(len(converted))
        code = "protection_period_exceeds_forecast_horizon_average_rate_scaling"
        if code not in warnings:
            warnings.append(code)
            explanations.append(
                "The requested demand period exceeds the forecast horizon; demand "
                "is approximated as forecast-horizon average daily demand × days."
            )
        return daily_average * Decimal(days)

    @staticmethod
    def _round_up(value: Decimal, increment: Decimal) -> Decimal:
        return (value / increment).to_integral_value(rounding=ROUND_CEILING) * increment

    @staticmethod
    def _round_down(value: Decimal, increment: Decimal) -> Decimal:
        return (value / increment).to_integral_value(rounding=ROUND_FLOOR) * increment
