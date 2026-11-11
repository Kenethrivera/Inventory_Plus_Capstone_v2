from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_CEILING

from app.forecasting import Mean28Forecaster
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
from .events import settle_inventory_day, supplier_delivery_date
from .models import (
    InventoryOutcome,
    SimulationConfig,
    SyntheticDay,
    SyntheticProductPolicy,
    SyntheticScenario,
)


@dataclass
class _Totals:
    underlying: Decimal = Decimal("0")
    fulfilled: Decimal = Decimal("0")
    unmet: Decimal = Decimal("0")
    late_backorder_fulfilled: Decimal = Decimal("0")
    ending_backorders: Decimal = Decimal("0")
    inventory_sum: Decimal = Decimal("0")
    excess_unit_days: Decimal = Decimal("0")
    ordered: Decimal = Decimal("0")
    holding_cost: Decimal = Decimal("0")
    ordering_cost: Decimal = Decimal("0")
    stockout_days: int = 0
    orders: int = 0
    reviews: int = 0
    provisional_approvals: int = 0
    inventory_days: int = 0


class InventoryPolicySimulator:
    """Daily lost-sales/backorder simulation with no persistence side effects."""

    def __init__(self, config: SimulationConfig) -> None:
        self._config = config
        self._engine = RecommendationEngine()
        self._mean28 = Mean28Forecaster()

    def compare(self, scenario: SyntheticScenario) -> tuple[InventoryOutcome, ...]:
        return (
            self._run(scenario, strategy="stage5c_mean28"),
            self._run(scenario, strategy="moving_average_order_up_to"),
        )

    def _run(self, scenario: SyntheticScenario, *, strategy: str) -> InventoryOutcome:
        totals = _Totals()
        end = self._config.start_date + timedelta(days=self._config.days - 1)
        evaluation_start = end - timedelta(days=self._config.evaluation_days - 1)
        for policy in scenario.policies:
            series = scenario.series(policy.location_id, policy.product_id)
            self._run_series(
                scenario,
                policy,
                series,
                evaluation_start=evaluation_start,
                strategy=strategy,
                totals=totals,
            )
        percentage = (
            totals.fulfilled / totals.underlying
            if totals.underlying > 0
            else None
        )
        return InventoryOutcome(
            strategy=strategy,
            underlying_demand_units=totals.underlying,
            immediately_fulfilled_units=totals.fulfilled,
            unmet_demand_units=totals.unmet,
            late_backorder_fulfilled_units=totals.late_backorder_fulfilled,
            ending_backorders=totals.ending_backorders,
            stockout_days=totals.stockout_days,
            fulfilled_demand_percentage=percentage,
            average_inventory=(
                totals.inventory_sum / Decimal(totals.inventory_days)
                if totals.inventory_days
                else Decimal("0")
            ),
            excess_inventory_unit_days=totals.excess_unit_days,
            orders_placed=totals.orders,
            ordered_quantity=totals.ordered,
            holding_cost=totals.holding_cost,
            ordering_cost=totals.ordering_cost,
            review_recommendations=totals.reviews,
            provisional_approvals=totals.provisional_approvals,
        )

    def _run_series(
        self,
        scenario: SyntheticScenario,
        policy: SyntheticProductPolicy,
        series: tuple[SyntheticDay, ...],
        *,
        evaluation_start: date,
        strategy: str,
        totals: _Totals,
    ) -> None:
        prior = [value for value in series if value.business_date < evaluation_start]
        if prior:
            on_hand = prior[-1].reference_on_hand_end
        else:
            on_hand = policy.opening_stock
        backlog = Decimal("0")
        returnable = Decimal("0")
        inbound: dict[date, Decimal] = defaultdict(lambda: Decimal("0"))
        observed: list[SyntheticDay] = list(prior)
        for source in series:
            day = source.business_date
            if day < evaluation_start or day < policy.launch_date:
                continue
            arrival = inbound.pop(day, Decimal("0"))
            realized_return = min(source.returned_units, returnable)
            returnable -= realized_return
            demand = source.underlying_net_demand
            settlement = settle_inventory_day(
                on_hand=on_hand,
                backorders=backlog,
                delivery=arrival,
                returns=realized_return,
                underlying_demand=demand,
                capacity=policy.capacity,
                backorder_fraction=self._config.backorder_fraction,
            )
            on_hand = settlement.on_hand_end
            backlog = settlement.backorders_end
            fulfilled = settlement.immediate_fulfilled
            returnable += fulfilled
            unmet = settlement.unmet_demand
            stockout = settlement.stockout
            totals.late_backorder_fulfilled += settlement.late_backorders_fulfilled
            observed.append(
                SyntheticDay(
                    business_date=day,
                    location_id=policy.location_id,
                    product_id=policy.product_id,
                    customer_demand=source.customer_demand,
                    cancelled_units=source.cancelled_units,
                    underlying_net_demand=demand,
                    returned_units=realized_return,
                    fulfilled_sales=fulfilled,
                    unmet_demand=unmet,
                    supplier_delay_days=source.supplier_delay_days,
                    reference_delivery_units=arrival,
                    reference_on_hand_end=on_hand,
                    stockout=stockout,
                )
            )
            totals.underlying += demand
            totals.fulfilled += fulfilled
            totals.unmet += unmet
            totals.stockout_days += int(stockout)
            totals.inventory_sum += on_hand
            totals.inventory_days += 1
            evaluation_target = (
                policy.base_daily_demand
                * Decimal(str(policy.lead_time_days + self._config.review_period_days))
                + policy.safety_stock
            )
            totals.excess_unit_days += max(Decimal("0"), on_hand - evaluation_target)
            totals.holding_cost += on_hand * self._config.daily_holding_cost_per_unit

            age = (day - policy.launch_date).days
            if age % self._config.review_period_days != 0:
                continue
            totals.reviews += 1
            if strategy == "stage5c_mean28":
                quantity, provisional = self._stage5c_quantity(
                    scenario,
                    policy,
                    tuple(observed),
                    day=day,
                    on_hand=on_hand,
                    on_order=sum(inbound.values(), Decimal("0")),
                    backlog=backlog,
                )
                totals.provisional_approvals += int(provisional and quantity > 0)
            else:
                quantity = self._baseline_quantity(
                    policy,
                    tuple(observed),
                    on_hand=on_hand,
                    on_order=sum(inbound.values(), Decimal("0")),
                    backlog=backlog,
                )
            if quantity <= 0:
                continue
            due = supplier_delivery_date(
                day,
                lead_time_days=policy.lead_time_days,
                delay_days=source.supplier_delay_days,
            )
            inbound[due] += quantity
            totals.orders += 1
            totals.ordered += quantity
            totals.ordering_cost += self._config.fixed_order_cost
        totals.ending_backorders += backlog

    def _stage5c_quantity(
        self,
        scenario: SyntheticScenario,
        policy: SyntheticProductPolicy,
        observed: tuple[SyntheticDay, ...],
        *,
        day: date,
        on_hand: Decimal,
        on_order: Decimal,
        backlog: Decimal,
    ) -> tuple[Decimal, bool]:
        dataset = historical_dataset(
            scenario,
            policy,
            history_end=day,
            observed_days=observed,
        )
        forecasts = self._mean28.forecast(
            dataset, horizon_days=self._config.forecast_horizon_days
        )
        at = datetime.combine(day, time(hour=12), timezone.utc)
        manual = (
            ManualDemandEstimate(
                daily_quantity=policy.manual_daily_estimate,
                unit=policy.unit,
                captured_at=at,
                rationale="Stage 6A configured cold-start assumption",
            )
            if forecasts[0].metadata.is_cold_start
            else None
        )
        result = self._engine.recommend(
            forecast=DemandForecastSnapshot(
                forecasts=tuple(forecasts),
                generated_at=at,
                source_data_as_of=at,
            ),
            inventory=InventorySnapshot(
                location_id=policy.location_id,
                product_id=policy.product_id,
                unit=policy.unit,
                saleable_on_hand=on_hand,
                confirmed_on_order=on_order,
                unfulfilled_reservations=Decimal("0"),
                backorders=backlog,
                max_capacity=policy.capacity,
                balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
                captured_at=at,
            ),
            supplier=SupplierPolicySnapshot(
                supplier_id=f"synthetic-supplier-{policy.product_id}",
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
                version="stage6a-synthetic-policy-v1",
                review_period_days=self._config.review_period_days,
                max_forecast_age=timedelta(days=1),
                max_inventory_age=timedelta(days=1),
                max_supplier_age=timedelta(days=1),
                max_safety_stock_age=timedelta(days=1),
            ),
            recommendation_at=at,
            manual_demand=manual,
        )
        return result.recommended_quantity_inventory_units or Decimal("0"), manual is not None

    def _baseline_quantity(
        self,
        policy: SyntheticProductPolicy,
        observed: tuple[SyntheticDay, ...],
        *,
        on_hand: Decimal,
        on_order: Decimal,
        backlog: Decimal,
    ) -> Decimal:
        window = observed[-28:]
        mean = (
            sum((value.fulfilled_sales for value in window), Decimal("0"))
            / Decimal(len(window))
            if window
            else policy.manual_daily_estimate
        )
        target = min(
            policy.capacity,
            mean
            * Decimal(
                str(policy.lead_time_days + self._config.review_period_days)
            )
            + policy.safety_stock,
        )
        inventory_position = on_hand + on_order - backlog
        required = max(Decimal("0"), target - inventory_position)
        if required <= 0:
            return Decimal("0")
        required = max(required, policy.minimum_order_quantity)
        packs = (required / policy.pack_size).to_integral_value(
            rounding=ROUND_CEILING
        )
        rounded = packs * policy.pack_size
        available_capacity = max(
            Decimal("0"), policy.capacity - on_hand - on_order
        )
        if available_capacity < policy.minimum_order_quantity:
            return Decimal("0")
        maximum_packs = (available_capacity / policy.pack_size).to_integral_value(
            rounding="ROUND_FLOOR"
        )
        return min(rounded, maximum_packs * policy.pack_size)
