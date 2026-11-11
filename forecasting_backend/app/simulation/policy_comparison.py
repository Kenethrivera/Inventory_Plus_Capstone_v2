from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR
from typing import Protocol

from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    DemandForecast,
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
from .events import settle_inventory_day, supplier_delivery_date
from .models import SimulationConfig, SyntheticDay, SyntheticProductPolicy, SyntheticScenario
from .stage6a2_models import PolicyComparisonOutcome, PolicyMetrics


class _Forecaster(Protocol):
    def forecast(self, dataset: object, *, horizon_days: int) -> list[DemandForecast]: ...


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
    maximum_consecutive_stockout_days: int = 0
    current_stockout_streak: int = 0
    orders: int = 0
    reviews: int = 0
    provisional_approvals: int = 0
    inventory_days: int = 0

    def add(self, other: _Totals) -> None:
        for field_name in self.__dataclass_fields__:
            if field_name in {
                "maximum_consecutive_stockout_days",
                "current_stockout_streak",
            }:
                continue
            setattr(
                self,
                field_name,
                getattr(self, field_name) + getattr(other, field_name),
            )
        self.maximum_consecutive_stockout_days = max(
            self.maximum_consecutive_stockout_days,
            other.maximum_consecutive_stockout_days,
        )

    def metrics(self) -> PolicyMetrics:
        return PolicyMetrics(
            underlying_demand_units=self.underlying,
            immediately_fulfilled_units=self.fulfilled,
            unmet_demand_units=self.unmet,
            late_backorder_fulfilled_units=self.late_backorder_fulfilled,
            ending_backorders=self.ending_backorders,
            stockout_days=self.stockout_days,
            maximum_consecutive_stockout_days=self.maximum_consecutive_stockout_days,
            fulfilled_demand_percentage=(
                self.fulfilled / self.underlying if self.underlying > 0 else None
            ),
            average_inventory=(
                self.inventory_sum / Decimal(self.inventory_days)
                if self.inventory_days
                else Decimal("0")
            ),
            excess_inventory_unit_days=self.excess_unit_days,
            orders_placed=self.orders,
            ordered_quantity=self.ordered,
            holding_cost=self.holding_cost,
            ordering_cost=self.ordering_cost,
            total_assumed_cost=self.holding_cost + self.ordering_cost,
            review_recommendations=self.reviews,
            provisional_approvals=self.provisional_approvals,
        )


class ExtendedInventoryPolicySimulator:
    """Four-policy comparison using only each strategy's observed history."""

    STRATEGIES = (
        "baseline_moving_average_order_up_to",
        "stage5c_mean28",
        "stage5c_lightgbm",
        "stage5c_calibrated_blend",
    )

    def __init__(self, config: SimulationConfig) -> None:
        self.config = config
        self.engine = RecommendationEngine()
        mean = Mean28Forecaster()
        lightgbm = LightGBMForecaster(
            config=LightGBMConfig(
                min_history_days=84,
                min_training_rows=40,
                n_estimators=30,
                learning_rate=0.06,
                num_leaves=12,
                random_seed=config.seed,
            ),
            mean28=mean,
        )
        blend = CalibratedBlendForecaster(
            config=CalibratedBlendConfig(
                minimum_calibration_points=28,
                rolling_origin=RollingOriginConfig(
                    initial_training_days=112,
                    horizon_days=config.forecast_horizon_days,
                    step_days=84,
                ),
            ),
            lightgbm=lightgbm,
            mean28=mean,
        )
        self.forecasters: dict[str, _Forecaster] = {
            "stage5c_mean28": mean,
            "stage5c_lightgbm": lightgbm,
            "stage5c_calibrated_blend": blend,
        }

    def compare(
        self,
        scenario: SyntheticScenario,
        *,
        strategies: tuple[str, ...] | None = None,
    ) -> tuple[PolicyComparisonOutcome, ...]:
        selected = strategies or self.STRATEGIES
        unknown = set(selected) - set(self.STRATEGIES)
        if unknown:
            raise ValueError(f"unknown inventory strategies: {sorted(unknown)}")
        return tuple(self._run(scenario, strategy) for strategy in selected)

    def _run(
        self, scenario: SyntheticScenario, strategy: str
    ) -> PolicyComparisonOutcome:
        overall = _Totals()
        by_category: dict[str, _Totals] = defaultdict(_Totals)
        actual_models: Counter[str] = Counter()
        end = self.config.start_date + timedelta(days=self.config.days - 1)
        evaluation_start = end - timedelta(days=self.config.evaluation_days - 1)
        for policy in scenario.policies:
            totals = self._run_series(
                scenario,
                policy,
                scenario.series(policy.location_id, policy.product_id),
                evaluation_start=evaluation_start,
                strategy=strategy,
                actual_models=actual_models,
            )
            overall.add(totals)
            by_category[policy.category.value].add(totals)
        return PolicyComparisonOutcome(
            strategy=strategy,
            overall=overall.metrics(),
            by_category={
                category: totals.metrics()
                for category, totals in sorted(by_category.items())
            },
            requested_forecast_model=(
                "baseline_fulfilled_sales_mean28"
                if strategy == "baseline_moving_average_order_up_to"
                else strategy.removeprefix("stage5c_")
            ),
            actual_forecast_models=dict(sorted(actual_models.items())),
        )

    def _run_series(
        self,
        scenario: SyntheticScenario,
        policy: SyntheticProductPolicy,
        series: tuple[SyntheticDay, ...],
        *,
        evaluation_start: date,
        strategy: str,
        actual_models: Counter[str],
    ) -> _Totals:
        totals = _Totals()
        prior = [value for value in series if value.business_date < evaluation_start]
        already_launched = evaluation_start > policy.launch_date
        on_hand = (
            prior[-1].reference_on_hand_end
            if prior and already_launched
            else Decimal("0")
        )
        backlog = Decimal("0")
        returnable = Decimal("0")
        inbound: dict[date, Decimal] = defaultdict(lambda: Decimal("0"))
        observed: list[SyntheticDay] = list(prior)
        for source in series:
            day = source.business_date
            if day < evaluation_start or day < policy.launch_date:
                continue
            if day == policy.launch_date and not already_launched:
                on_hand = policy.opening_stock
                already_launched = True
            arrival = inbound.pop(day, Decimal("0"))
            realized_return = min(source.returned_units, returnable)
            returnable -= realized_return
            settlement = settle_inventory_day(
                on_hand=on_hand,
                backorders=backlog,
                delivery=arrival,
                returns=realized_return,
                underlying_demand=source.underlying_net_demand,
                capacity=policy.capacity,
                backorder_fraction=self.config.backorder_fraction,
            )
            on_hand = settlement.on_hand_end
            backlog = settlement.backorders_end
            returnable += settlement.immediate_fulfilled
            observed.append(
                SyntheticDay(
                    business_date=day,
                    location_id=policy.location_id,
                    product_id=policy.product_id,
                    customer_demand=source.customer_demand,
                    cancelled_units=source.cancelled_units,
                    underlying_net_demand=source.underlying_net_demand,
                    returned_units=realized_return,
                    fulfilled_sales=settlement.immediate_fulfilled,
                    unmet_demand=settlement.unmet_demand,
                    supplier_delay_days=source.supplier_delay_days,
                    reference_delivery_units=arrival,
                    reference_on_hand_end=on_hand,
                    stockout=settlement.stockout,
                )
            )
            totals.underlying += source.underlying_net_demand
            totals.fulfilled += settlement.immediate_fulfilled
            totals.unmet += settlement.unmet_demand
            totals.late_backorder_fulfilled += settlement.late_backorders_fulfilled
            totals.stockout_days += int(settlement.stockout)
            if settlement.stockout:
                totals.current_stockout_streak += 1
                totals.maximum_consecutive_stockout_days = max(
                    totals.maximum_consecutive_stockout_days,
                    totals.current_stockout_streak,
                )
            else:
                totals.current_stockout_streak = 0
            totals.inventory_sum += on_hand
            totals.inventory_days += 1
            target = (
                policy.base_daily_demand
                * Decimal(str(policy.lead_time_days + self.config.review_period_days))
                + policy.safety_stock
            )
            totals.excess_unit_days += max(Decimal("0"), on_hand - target)
            totals.holding_cost += (
                on_hand * self.config.daily_holding_cost_per_unit
            )

            age = (day - policy.launch_date).days
            if age % self.config.review_period_days != 0:
                continue
            totals.reviews += 1
            on_order = sum(inbound.values(), Decimal("0"))
            if strategy == "baseline_moving_average_order_up_to":
                quantity = self._baseline_quantity(
                    policy,
                    tuple(observed),
                    on_hand=on_hand,
                    on_order=on_order,
                    backlog=backlog,
                )
                actual_models["baseline_fulfilled_sales_mean28"] += 1
                provisional = False
            else:
                quantity, provisional, actual_model = self._stage5c_quantity(
                    scenario,
                    policy,
                    tuple(observed),
                    day=day,
                    on_hand=on_hand,
                    on_order=on_order,
                    backlog=backlog,
                    forecaster=self.forecasters[strategy],
                )
                actual_models[actual_model] += 1
            totals.provisional_approvals += int(provisional and quantity > 0)
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
            totals.ordering_cost += self.config.fixed_order_cost
        totals.ending_backorders += backlog
        return totals

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
        forecaster: _Forecaster,
    ) -> tuple[Decimal, bool, str]:
        dataset = historical_dataset(
            scenario,
            policy,
            history_end=day,
            observed_days=observed,
        )
        forecasts = forecaster.forecast(
            dataset, horizon_days=self.config.forecast_horizon_days
        )
        at = datetime.combine(day, time(hour=12), timezone.utc)
        manual = (
            ManualDemandEstimate(
                daily_quantity=policy.manual_daily_estimate,
                unit=policy.unit,
                captured_at=at,
                rationale="Stage 6A.2 configured cold-start assumption",
            )
            if forecasts[0].metadata.is_cold_start
            else None
        )
        result = self.engine.recommend(
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
                supplier_id=f"synthetic-stage6a2-{policy.product_id}",
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
                version="stage6a2-synthetic-comparison-v1",
                review_period_days=self.config.review_period_days,
                max_forecast_age=timedelta(days=1),
                max_inventory_age=timedelta(days=1),
                max_supplier_age=timedelta(days=1),
                max_safety_stock_age=timedelta(days=1),
            ),
            recommendation_at=at,
            manual_demand=manual,
        )
        return (
            result.recommended_quantity_inventory_units or Decimal("0"),
            manual is not None,
            forecasts[0].metadata.model_name,
        )

    def _baseline_quantity(
        self,
        policy: SyntheticProductPolicy,
        observed: tuple[SyntheticDay, ...],
        *,
        on_hand: Decimal,
        on_order: Decimal,
        backlog: Decimal,
    ) -> Decimal:
        window = [
            value
            for value in observed
            if value.business_date >= policy.launch_date
        ][-28:]
        mean = (
            sum((value.fulfilled_sales for value in window), Decimal("0"))
            / Decimal(len(window))
            if window
            else policy.manual_daily_estimate
        )
        target = min(
            policy.capacity,
            mean
            * Decimal(str(policy.lead_time_days + self.config.review_period_days))
            + policy.safety_stock,
        )
        inventory_position = on_hand + on_order - backlog
        required = max(Decimal("0"), target - inventory_position)
        if required <= 0:
            return Decimal("0")
        required = max(required, policy.minimum_order_quantity)
        rounded = (required / policy.pack_size).to_integral_value(
            rounding=ROUND_CEILING
        ) * policy.pack_size
        available_capacity = max(
            Decimal("0"), policy.capacity - on_hand - on_order
        )
        if available_capacity < policy.minimum_order_quantity:
            return Decimal("0")
        maximum = (available_capacity / policy.pack_size).to_integral_value(
            rounding=ROUND_FLOOR
        ) * policy.pack_size
        return min(rounded, maximum)
