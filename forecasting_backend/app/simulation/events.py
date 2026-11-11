from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal, ROUND_CEILING


@dataclass(frozen=True)
class InventoryDaySettlement:
    on_hand_end: Decimal
    backorders_end: Decimal
    immediate_fulfilled: Decimal
    unmet_demand: Decimal
    late_backorders_fulfilled: Decimal
    backorders_added: Decimal
    stockout: bool


def supplier_delivery_date(
    order_date: date, *, lead_time_days: int, delay_days: int
) -> date:
    if lead_time_days < 0 or delay_days < 0:
        raise ValueError("lead time and delay must be nonnegative")
    return order_date + timedelta(days=lead_time_days + delay_days)


def settle_inventory_day(
    *,
    on_hand: Decimal,
    backorders: Decimal,
    delivery: Decimal,
    returns: Decimal,
    underlying_demand: Decimal,
    capacity: Decimal,
    backorder_fraction: Decimal,
) -> InventoryDaySettlement:
    values = (on_hand, backorders, delivery, returns, underlying_demand, capacity)
    if any(value < 0 or not value.is_finite() for value in values):
        raise ValueError("inventory event quantities must be finite and nonnegative")
    if backorder_fraction < 0 or backorder_fraction > 1:
        raise ValueError("backorder_fraction must be between zero and one")
    late_fulfilled = min(delivery, backorders)
    remaining_delivery = delivery - late_fulfilled
    backlog = backorders - late_fulfilled
    available = min(capacity, on_hand + remaining_delivery + returns)
    immediate = min(available, underlying_demand)
    unmet = underlying_demand - immediate
    available -= immediate
    added = (unmet * backorder_fraction).to_integral_value(
        rounding=ROUND_CEILING
    )
    added = min(added, unmet)
    backlog += added
    return InventoryDaySettlement(
        on_hand_end=available,
        backorders_end=backlog,
        immediate_fulfilled=immediate,
        unmet_demand=unmet,
        late_backorders_fulfilled=late_fulfilled,
        backorders_added=added,
        stockout=unmet > 0,
    )
