from __future__ import annotations

import math
import random
from collections import defaultdict
from datetime import date, timedelta
from decimal import Decimal, ROUND_CEILING
from uuid import NAMESPACE_URL, uuid5

from .models import (
    DemandCategory,
    SimulationConfig,
    SyntheticDay,
    SyntheticProductPolicy,
    SyntheticScenario,
)


class SyntheticHardwareStoreGenerator:
    """Pure seeded generator with latent demand separated from fulfilled sales."""

    def generate(self, config: SimulationConfig) -> SyntheticScenario:
        rng = random.Random(config.seed)
        policies = tuple(self._policies(config, rng))
        records: list[SyntheticDay] = []
        for policy in policies:
            records.extend(self._series(config, policy, rng))
        return SyntheticScenario(
            config=config,
            policies=policies,
            days=tuple(records),
        )

    def _policies(
        self, config: SimulationConfig, rng: random.Random
    ) -> list[SyntheticProductPolicy]:
        policies: list[SyntheticProductPolicy] = []
        categories = tuple(DemandCategory)
        for location_index in range(config.location_count):
            location_id = str(
                uuid5(
                    NAMESPACE_URL,
                    f"inventory-plus-stage6a-location-{location_index + 1}",
                )
            )
            for product_index in range(config.product_count):
                category = categories[product_index % len(categories)]
                if category is DemandCategory.SLOW:
                    base = _uniform_decimal(rng, config.slow_daily_demand_range)
                    frequency = _uniform_decimal(rng, config.slow_frequency_range)
                elif category is DemandCategory.MEDIUM:
                    base = _uniform_decimal(rng, config.medium_daily_demand_range)
                    frequency = _uniform_decimal(rng, config.medium_frequency_range)
                else:
                    base = _uniform_decimal(rng, config.fast_daily_demand_range)
                    frequency = _uniform_decimal(rng, config.fast_frequency_range)
                late_launch = rng.random() < float(config.new_product_probability)
                minimum_launch, maximum_launch = config.new_product_launch_offset_range
                maximum_launch = min(maximum_launch, config.days - 1)
                launch_offset = (
                    rng.randint(min(minimum_launch, maximum_launch), maximum_launch)
                    if late_launch and maximum_launch > 0
                    else 0
                )
                lead = rng.randint(*config.supplier_lead_time_range)
                pack = Decimal(str(rng.choice(config.pack_size_options)))
                base_decimal = base
                safety = _ceil(
                    base_decimal
                    * Decimal(
                        str(max(config.minimum_safety_stock_days, lead // 2))
                    )
                )
                capacity = _ceil(
                    base_decimal * Decimal(str(config.capacity_coverage_days))
                    + safety
                )
                opening = min(
                    capacity,
                    _ceil(
                        base_decimal
                        * Decimal(
                            str(max(config.opening_stock_coverage_days, lead))
                        )
                        + safety
                    ),
                )
                policies.append(
                    SyntheticProductPolicy(
                        product_id=str(
                            uuid5(
                                NAMESPACE_URL,
                                f"inventory-plus-stage6a-product-{product_index + 1}",
                            )
                        ),
                        location_id=location_id,
                        sku=f"SYN-{product_index + 1:04d}",
                        name=f"Synthetic hardware item {product_index + 1:04d}",
                        category=category,
                        unit="pcs",
                        launch_date=config.start_date + timedelta(days=launch_offset),
                        base_daily_demand=base_decimal,
                        demand_frequency=frequency,
                        variability=_uniform_decimal(
                            rng, config.demand_variability_range
                        ),
                        weekly_seasonality=_uniform_decimal(
                            rng, config.weekly_seasonality_range
                        ),
                        annual_seasonality=_uniform_decimal(
                            rng, config.annual_seasonality_range
                        ),
                        lead_time_days=lead,
                        minimum_order_quantity=pack
                        * Decimal(str(rng.choice(config.moq_pack_multiple_options))),
                        pack_size=pack,
                        capacity=capacity,
                        opening_stock=opening,
                        safety_stock=safety,
                        manual_daily_estimate=_decimal(
                            float(base) * rng.uniform(0.80, 1.20)
                        ),
                    )
                )
        return policies

    def _series(
        self,
        config: SimulationConfig,
        policy: SyntheticProductPolicy,
        rng: random.Random,
    ) -> list[SyntheticDay]:
        on_hand = Decimal("0")
        previous_sales = Decimal("0")
        inbound: dict[object, Decimal] = defaultdict(lambda: Decimal("0"))
        records: list[SyntheticDay] = []
        for offset in range(config.days):
            day = config.start_date + timedelta(days=offset)
            delay = (
                rng.randint(1, config.maximum_delivery_delay_days)
                if rng.random() < float(config.delivery_delay_probability)
                else 0
            )
            delivery = inbound.pop(day, Decimal("0"))
            if day == policy.launch_date:
                on_hand = policy.opening_stock
            if day < policy.launch_date:
                records.append(
                    SyntheticDay(
                        business_date=day,
                        location_id=policy.location_id,
                        product_id=policy.product_id,
                        customer_demand=Decimal("0"),
                        cancelled_units=Decimal("0"),
                        underlying_net_demand=Decimal("0"),
                        returned_units=Decimal("0"),
                        fulfilled_sales=Decimal("0"),
                        unmet_demand=Decimal("0"),
                        supplier_delay_days=delay,
                        reference_delivery_units=Decimal("0"),
                        reference_on_hand_end=Decimal("0"),
                        stockout=False,
                    )
                )
                continue

            on_hand = min(policy.capacity, on_hand + delivery)
            returns = _binomial(rng, int(previous_sales), config.return_probability)
            returned = Decimal(returns)
            on_hand = min(policy.capacity, on_hand + returned)
            demand = Decimal(self._demand(day, policy, rng, config))
            cancelled = Decimal(
                _binomial(rng, int(demand), config.cancellation_probability)
            )
            net_demand = demand - cancelled
            fulfilled = min(net_demand, on_hand)
            unmet = net_demand - fulfilled
            on_hand -= fulfilled
            previous_sales = fulfilled

            launch_age = (day - policy.launch_date).days
            if launch_age % config.review_period_days == 0:
                on_order = sum(inbound.values(), Decimal("0"))
                target = min(
                    policy.capacity,
                    _ceil(
                        policy.base_daily_demand
                        * Decimal(str(policy.lead_time_days + config.review_period_days))
                        + policy.safety_stock
                    ),
                )
                quantity = max(Decimal("0"), target - on_hand - on_order)
                quantity = _supplier_round(quantity, policy)
                quantity = _fit_supplier_capacity(
                    quantity,
                    available_capacity=max(
                        Decimal("0"), policy.capacity - on_hand - on_order
                    ),
                    policy=policy,
                )
                if quantity > 0:
                    due = day + timedelta(days=policy.lead_time_days + delay)
                    inbound[due] += quantity

            records.append(
                SyntheticDay(
                    business_date=day,
                    location_id=policy.location_id,
                    product_id=policy.product_id,
                    customer_demand=demand,
                    cancelled_units=cancelled,
                    underlying_net_demand=net_demand,
                    returned_units=returned,
                    fulfilled_sales=fulfilled,
                    unmet_demand=unmet,
                    supplier_delay_days=delay,
                    reference_delivery_units=delivery,
                    reference_on_hand_end=on_hand,
                    stockout=unmet > 0,
                )
            )
        return records

    @staticmethod
    def _demand(
        day: date,
        policy: SyntheticProductPolicy,
        rng: random.Random,
        config: SimulationConfig,
    ) -> int:
        if rng.random() > float(policy.demand_frequency):
            return 0
        weekday = day.weekday()
        year_day = day.timetuple().tm_yday
        weekly = 1 + float(policy.weekly_seasonality) * math.sin(
            2 * math.pi * weekday / 7
        )
        annual = 1 + float(policy.annual_seasonality) * math.sin(
            2 * math.pi * year_day / 365.25
        )
        expected = float(policy.base_daily_demand) * weekly * annual
        noisy = expected + rng.gauss(0, max(0.25, expected * float(policy.variability)))
        if rng.random() < float(config.spike_probability):
            noisy *= rng.uniform(2.0, 4.5)
        return max(0, int(round(noisy)))


def _binomial(rng: random.Random, units: int, probability: Decimal) -> int:
    return sum(1 for _ in range(max(0, units)) if rng.random() < float(probability))


def _decimal(value: float) -> Decimal:
    return Decimal(format(value, ".6f"))


def _uniform_decimal(
    rng: random.Random, bounds: tuple[Decimal, Decimal]
) -> Decimal:
    low, high = bounds
    return _decimal(rng.uniform(float(low), float(high)))


def _ceil(value: Decimal) -> Decimal:
    return value.to_integral_value(rounding=ROUND_CEILING)


def _supplier_round(
    quantity: Decimal, policy: SyntheticProductPolicy
) -> Decimal:
    if quantity <= 0:
        return Decimal("0")
    quantity = max(quantity, policy.minimum_order_quantity)
    packs = (quantity / policy.pack_size).to_integral_value(rounding=ROUND_CEILING)
    return packs * policy.pack_size


def _fit_supplier_capacity(
    quantity: Decimal,
    *,
    available_capacity: Decimal,
    policy: SyntheticProductPolicy,
) -> Decimal:
    """Keep reference orders pack-valid; an infeasible MOQ produces no order."""
    if quantity <= 0 or available_capacity < policy.minimum_order_quantity:
        return Decimal("0")
    maximum_packs = (available_capacity / policy.pack_size).to_integral_value(
        rounding="ROUND_FLOOR"
    )
    return min(quantity, maximum_packs * policy.pack_size)
