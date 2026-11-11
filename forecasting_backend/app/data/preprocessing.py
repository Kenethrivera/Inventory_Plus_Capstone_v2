from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any, Iterable, Mapping
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .models import DailyDemand, DemandSeriesKey
from .validation import (
    DemandDataError,
    parse_date,
    parse_timestamp,
    positive_decimal,
    required_identifier,
)


def aggregate_completed_orders(
    rows: Iterable[Mapping[str, Any]],
    *,
    business_timezone: str = "Asia/Manila",
    period_start: datetime | None = None,
    period_end: datetime | None = None,
) -> list[DailyDemand]:
    """Convert order-history snapshots into validated daily product demand.

    This pure function mirrors the database extraction policy and supports
    deterministic tests without connecting to production Supabase.
    """
    try:
        timezone = ZoneInfo(business_timezone)
    except ZoneInfoNotFoundError as error:
        raise DemandDataError("business_timezone is invalid") from error

    if (period_start is None) is not (period_end is None):
        raise DemandDataError("period_start and period_end must be provided together")
    if period_start is not None and period_end is not None:
        if period_start.tzinfo is None or period_end.tzinfo is None:
            raise DemandDataError("demand-history period must include a timezone")
        if period_end <= period_start:
            raise DemandDataError("demand-history period is invalid")

    seen_orders: dict[str, Mapping[str, Any]] = {}
    totals: dict[tuple[date, str, str, str], Decimal] = defaultdict(Decimal)
    orders: dict[tuple[date, str, str, str], set[str]] = defaultdict(set)
    names: dict[tuple[date, str, str, str], set[str]] = defaultdict(set)
    series_units: dict[DemandSeriesKey, str] = {}

    for row in rows:
        if str(row.get("status", "")).strip().lower() != "completed":
            continue
        if row.get("returned_at") is not None:
            continue

        completed_value = row.get("completed_at")
        if completed_value is None or not str(completed_value).strip():
            if not _undated_completed_order_can_overlap(
                row, period_start=period_start, period_end=period_end
            ):
                continue
            raise DemandDataError("completed_at must be an ISO-8601 timestamp")

        completed_at = parse_timestamp(completed_value, "completed_at")
        if period_start is not None and period_end is not None:
            if completed_at < period_start or completed_at >= period_end:
                continue

        order_id = str(row.get("order_id") or row.get("id") or "").strip()
        if not order_id:
            raise DemandDataError("order_id is required")
        previous = seen_orders.get(order_id)
        if previous is not None:
            # The canonical table has a primary key, but raw exports and test
            # fixtures can repeat rows. Ignore repeats instead of double count.
            if previous != row:
                raise DemandDataError(f"duplicate order {order_id} has conflicting data")
            continue
        seen_orders[order_id] = row

        location_id = required_identifier(row.get("location_id"), "location_id")
        business_date = completed_at.astimezone(timezone).date()
        items = row.get("items")
        if not isinstance(items, list) or not items:
            raise DemandDataError(f"completed order {order_id} has no item lines")

        for index, item in enumerate(items):
            if not isinstance(item, Mapping):
                raise DemandDataError(f"order {order_id} item {index} is invalid")
            product_id = required_identifier(
                item.get("product_id") or item.get("productId"),
                f"order {order_id} item {index} product_id",
            )
            quantity = positive_decimal(
                item.get("quantity"), f"order {order_id} item {index} quantity"
            )
            name = str(
                item.get("product_name") or item.get("productName") or "Unknown product"
            ).strip() or "Unknown product"
            unit = str(item.get("unit") or "pcs").strip() or "pcs"
            series_key = DemandSeriesKey(location_id, product_id)
            prior_unit = series_units.setdefault(series_key, unit)
            if prior_unit != unit:
                raise DemandDataError(
                    f"product {product_id} has inconsistent units: {prior_unit} and {unit}"
                )
            key = (business_date, location_id, product_id, unit)
            totals[key] += quantity
            orders[key].add(order_id)
            names[key].add(name)

    return [
        DailyDemand(
            business_date=key[0],
            location_id=key[1],
            product_id=key[2],
            product_name=max(names[key]),
            unit=key[3],
            quantity=quantity,
            completed_order_count=len(orders[key]),
        )
        for key, quantity in sorted(totals.items())
    ]


def _undated_completed_order_can_overlap(
    row: Mapping[str, Any],
    *,
    period_start: datetime | None,
    period_end: datetime | None,
) -> bool:
    """Conservatively place an undated completed record against a window.

    Completion must have occurred no earlier than order creation and no later
    than the durable snapshot update. If that possible interval intersects the
    requested half-open history window, the record is relevant and extraction
    must fail closed. Missing interval evidence is also treated as relevant.
    """
    if period_start is None or period_end is None:
        return True
    try:
        created_at = parse_timestamp(row.get("created_at"), "created_at")
        snapshot_updated_at = parse_timestamp(
            row.get("snapshot_updated_at"), "snapshot_updated_at"
        )
    except DemandDataError:
        return True
    if snapshot_updated_at < created_at:
        return True
    return created_at < period_end and snapshot_updated_at >= period_start


def parse_rpc_daily_demand(rows: Iterable[Mapping[str, Any]]) -> list[DailyDemand]:
    """Validate rows returned by forecast_daily_demand_v1."""
    parsed: list[DailyDemand] = []
    seen: set[tuple[date, str, str]] = set()
    series_units: dict[DemandSeriesKey, str] = {}
    for row in rows:
        business_date = parse_date(row.get("business_date"), "business_date")
        location_id = required_identifier(row.get("location_id"), "location_id")
        product_id = required_identifier(row.get("product_id"), "product_id")
        key = (business_date, location_id, product_id)
        if key in seen:
            raise DemandDataError("daily demand response contains duplicate series dates")
        seen.add(key)
        quantity = positive_decimal(row.get("quantity"), "quantity")
        order_count = int(row.get("completed_order_count", 0))
        if order_count <= 0:
            raise DemandDataError("completed_order_count must be greater than zero")
        unit = str(row.get("unit") or "pcs").strip() or "pcs"
        series_key = DemandSeriesKey(location_id, product_id)
        prior_unit = series_units.setdefault(series_key, unit)
        if prior_unit != unit:
            raise DemandDataError(
                f"product {product_id} has inconsistent units: {prior_unit} and {unit}"
            )
        parsed.append(
            DailyDemand(
                business_date=business_date,
                location_id=location_id,
                product_id=product_id,
                sku=str(row["sku"]).strip() if row.get("sku") else None,
                product_name=str(row.get("product_name") or "Unknown product"),
                unit=unit,
                quantity=quantity,
                completed_order_count=order_count,
            )
        )
    return sorted(parsed, key=lambda value: (value.series_key, value.business_date))


def fill_missing_days(
    values: Iterable[DailyDemand], *, start: date, end: date
) -> dict[DemandSeriesKey, list[DailyDemand]]:
    """Return inclusive, zero-filled daily series for every observed product."""
    if end < start:
        raise DemandDataError("end must not be before start")
    grouped: dict[DemandSeriesKey, dict[date, DailyDemand]] = defaultdict(dict)
    for value in values:
        if value.business_date < start or value.business_date > end:
            raise DemandDataError("daily demand falls outside the requested period")
        grouped[value.series_key][value.business_date] = value

    result: dict[DemandSeriesKey, list[DailyDemand]] = {}
    for key, by_date in grouped.items():
        exemplar = next(iter(by_date.values()))
        series: list[DailyDemand] = []
        current = start
        while current <= end:
            series.append(
                by_date.get(
                    current,
                    DailyDemand(
                        business_date=current,
                        location_id=key.location_id,
                        product_id=key.product_id,
                        sku=exemplar.sku,
                        product_name=exemplar.product_name,
                        unit=exemplar.unit,
                        quantity=Decimal("0"),
                        completed_order_count=0,
                    ),
                )
            )
            current += timedelta(days=1)
        result[key] = series
    return result

