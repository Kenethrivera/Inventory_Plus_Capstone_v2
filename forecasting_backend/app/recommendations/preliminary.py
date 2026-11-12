from __future__ import annotations

from decimal import Decimal, ROUND_CEILING

from .models import (
    DemandForecastSnapshot,
    InventorySnapshot,
    PreliminaryInsightStatus,
    PreliminaryRestockingInsight,
)


PRELIMINARY_RESTOCKING_ASSUMPTIONS_V1 = (
    "Uses the existing validated LightGBM forecast for a fixed 28-day planning horizon.",
    "Uses current saleable inventory in the same inventory unit.",
    "Supplier lead time, review period, incoming orders, backorders, safety stock, MOQ, and pack size are excluded from this preliminary estimate.",
    "Missing incoming orders or backorders are not interpreted as verified zero.",
)


class PreliminaryRestockingInsightCalculator:
    """Build a demand-minus-stock estimate without supplier-policy assumptions."""

    PLANNING_HORIZON_DAYS = 28

    def calculate(
        self,
        *,
        forecast: DemandForecastSnapshot,
        inventory: InventorySnapshot,
    ) -> PreliminaryRestockingInsight:
        values = forecast.forecasts
        if not values:
            raise ValueError("preliminary insight requires forecast values")

        first = values[0]
        if len(values) != self.PLANNING_HORIZON_DAYS:
            raise ValueError("preliminary insight requires exactly 28 forecast days")
        if (
            first.location_id != inventory.location_id
            or first.product_id != inventory.product_id
        ):
            raise ValueError("forecast and inventory scope do not match")
        if first.unit.strip().lower() != inventory.unit.strip().lower():
            raise ValueError("forecast and inventory units do not match")
        if any(
            value.location_id != first.location_id
            or value.product_id != first.product_id
            or value.unit.strip().lower() != first.unit.strip().lower()
            for value in values
        ):
            raise ValueError("forecast series contains mixed product or unit values")
        if any(not value.quantity.is_finite() or value.quantity < 0 for value in values):
            raise ValueError("forecast quantities must be finite and nonnegative")

        assumptions = PRELIMINARY_RESTOCKING_ASSUMPTIONS_V1
        limitations: list[str] = []
        predicted_demand: Decimal | None
        suggested: Decimal | None = None

        cold_reason = first.metadata.cold_start_reason
        if cold_reason is not None and cold_reason.value == "no_history":
            predicted_demand = None
            limitations.append(
                "No sales history is available, so zero model output is unknown demand rather than evidence of zero demand."
            )
        else:
            predicted_demand = sum(
                (value.quantity for value in values), Decimal("0")
            )
            if first.metadata.is_cold_start:
                limitations.append(
                    "Sales history is insufficient; the forecast is provisional and requires extra owner review."
                )

        available_inventory = inventory.saleable_on_hand
        if (
            available_inventory is None
            or not available_inventory.is_finite()
            or available_inventory < 0
        ):
            available_inventory = None
            limitations.append(
                "Current saleable inventory is unavailable or invalid, so a restock quantity cannot be calculated."
            )

        if predicted_demand is not None and available_inventory is not None:
            shortfall = predicted_demand - available_inventory
            suggested = max(
                Decimal("0"),
                shortfall.to_integral_value(rounding=ROUND_CEILING),
            )

        return PreliminaryRestockingInsight(
            status=(
                PreliminaryInsightStatus.AVAILABLE
                if suggested is not None
                else PreliminaryInsightStatus.LIMITED
            ),
            location_id=first.location_id,
            product_id=first.product_id,
            inventory_unit=inventory.unit,
            planning_horizon_days=self.PLANNING_HORIZON_DAYS,
            predicted_demand=predicted_demand,
            available_inventory=available_inventory,
            suggested_restock_quantity=suggested,
            forecast_model=first.metadata.model_name,
            forecast_version=first.metadata.model_version,
            forecast_generated_at=forecast.generated_at,
            forecast_source_data_as_of=forecast.source_data_as_of,
            assumptions=assumptions,
            limitations=tuple(limitations),
        )
