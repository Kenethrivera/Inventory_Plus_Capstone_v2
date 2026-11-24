"""Read-only, store-scoped ranking from saved LightGBM and live stock."""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor
from datetime import datetime
from decimal import Decimal
from threading import Lock
from time import monotonic
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from .contracts import (DataUnavailableError, ProductNotFoundError,
                        ReplenishmentConfigurationUnavailableError, SessionProfile)
from .snapshot_guidance import current_stock_analysis


def _number(value: object) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = Decimal(str(value))
    except (ValueError, ArithmeticError):
        return None
    return result if result.is_finite() else None


def _unavailable_reason(stage: str, error: Exception) -> tuple[str, str]:
    """Return a safe explanation for the actual failed read/calculation stage."""
    if isinstance(error, ReplenishmentConfigurationUnavailableError):
        return "replenishment_configuration_unavailable", "Replenishment configuration could not be read."
    if isinstance(error, DataUnavailableError) and any(
        phrase in str(error).casefold() for phrase in
        ("no history", "insufficient history", "no recorded sales")
    ):
        return "sales_history_insufficient", "Sales history is insufficient to establish reliable demand."
    if isinstance(error, DataUnavailableError) and stage == "current_inputs":
        detail = str(error).casefold()
        if "supplier" in detail:
            return "supplier_inputs_unavailable", "Current supplier inputs could not be read."
        if "inventory" in detail:
            return "inventory_inputs_unavailable", "Current inventory inputs could not be read."
    if isinstance(error, ProductNotFoundError):
        return "product_not_found", "The product is unavailable in the authorized store."
    if isinstance(error, httpx.HTTPError):
        return "data_service_unavailable", "Current recommendation inputs could not be retrieved."
    if stage == "saved_forecast":
        return "saved_forecast_unavailable", "The saved LightGBM forecast details could not be read."
    if stage == "current_inputs":
        return "current_inputs_unavailable", "Current inventory or replenishment inputs could not be read."
    return "recommendation_inputs_invalid", "The saved forecast or current inputs could not be used for a recommendation."


class StoreRestockPriorityReader:
    """Cache one complete ranked scope; pagination never changes the ranking."""

    _PAGE_SIZE = 50
    _MAX_PRODUCTS = 2500
    _TTL_SECONDS = 30

    def __init__(self, *, snapshots: Any, adapter: Any, service: Any) -> None:
        self._snapshots = snapshots
        self._adapter = adapter
        self._service = service
        self._lock = Lock()
        self._pool = ThreadPoolExecutor(max_workers=8)
        self._cache: dict[tuple[str, ...], tuple[float, list[dict[str, Any]]]] = {}
        self._pending: dict[tuple[str, ...], Future[list[dict[str, Any]]]] = {}

    def page(
        self, *, profile: SessionProfile, session_token: str, now: datetime,
        page: int, page_size: int, unit: str | None, category: str | None,
        product_id: str | None, search: str | None, refresh: bool = False,
        view: str = "actionable", scope_search: str | None = None,
    ) -> dict[str, Any]:
        if view not in {"actionable", "unavailable"}:
            raise ValueError("Unsupported restock priority view")
        key = (profile.location_id, now.astimezone(ZoneInfo("Asia/Manila")).date().isoformat(), unit or "",
               category or "", product_id or "", scope_search or "", search or "")
        with self._lock:
            cached = self._cache.get(key)
            if not refresh and cached is not None and cached[0] > monotonic():
                rows = cached[1]
                pending = None
                owner = False
            else:
                pending = self._pending.get(key)
                owner = pending is None
                if owner:
                    pending = Future()
                    self._pending[key] = pending
                rows = []
        if pending is not None:
            if owner:
                try:
                    rows = self._build(profile=profile, session_token=session_token,
                                       now=now, unit=unit, category=category,
                                       product_id=product_id, search=search,
                                       scope_search=scope_search)
                    with self._lock:
                        if len(self._cache) >= 32:
                            self._cache.clear()
                        self._cache[key] = (monotonic() + self._TTL_SECONDS, rows)
                    pending.set_result(rows)
                except Exception as error:
                    pending.set_exception(error)
                    raise
                finally:
                    with self._lock:
                        self._pending.pop(key, None)
            else:
                rows = pending.result()
        actionable = [row for row in rows if row["status"] in {"recommend_order", "needs_review"}]
        unavailable = [row for row in rows if row["status"] == "unavailable"]
        selected = actionable if view == "actionable" else unavailable
        start = (page - 1) * page_size
        return {
            "source_model": "lightgbm", "scope": "authorized_store",
            "view": view,
            "page": page, "page_size": page_size,
            "total_products": len(rows), "total_count": len(actionable),
            "current_count": sum(row["forecast_status"] == "completed" for row in rows),
            "page_count": (len(selected) + page_size - 1) // page_size,
            "missing_count": sum(row["status"] == "missing" for row in rows),
            "stale_count": sum(row["status"] == "stale" for row in rows),
            "unavailable_count": sum(row["status"] == "unavailable" for row in rows),
            "unavailable_items": [{field: row[field] for field in
                                   ("product_id", "product_name", "sku", "reason_code", "reason")}
                                  for row in selected[start:start + page_size]]
                                  if view == "unavailable" else [],
            "active_count": sum(row["forecast_job_status"] in {"queued", "running"} for row in rows),
            "items": selected[start:start + page_size] if view == "actionable" else [],
        }

    def coverage(self, *, profile: SessionProfile, unit: str | None,
                 category: str | None, product_id: str | None,
                 search: str | None) -> dict[str, int]:
        """Poll authoritative LightGBM state without loading stock or bundles."""
        rows = self._snapshot_rows(profile=profile, unit=unit,
                                   category=category, product_id=product_id,
                                   search=search)
        return {
            "total_products": len(rows),
            "active_count": sum((item.get("job") or {}).get("status") in
                                {"queued", "running"} for item in rows),
            "current_count": sum(item["status"] == "completed" for item in rows),
            "stale_count": sum(item["status"] == "stale" for item in rows),
        }

    def _snapshot_rows(self, *, profile: SessionProfile, unit: str | None,
                       category: str | None, product_id: str | None,
                       search: str | None) -> list[dict[str, Any]]:
        products: list[dict[str, Any]] = []
        page = 1
        expected_total: int | None = None
        while True:
            result = self._snapshots.overview(
                location_id=profile.location_id, model_key="lightgbm", page=page,
                page_size=self._PAGE_SIZE, unit=unit, category=category,
                product_id=product_id, search=search,
            )
            if result["total_count"] > self._MAX_PRODUCTS:
                raise DataUnavailableError("Restock priority scope exceeds the supported limit")
            if expected_total is None:
                expected_total = result["total_count"]
            elif result["total_count"] != expected_total:
                raise DataUnavailableError("Restock priority scope changed during the read")
            if any(item["product"]["location_id"] != profile.location_id
                   for item in result["items"]):
                raise DataUnavailableError("Restock priority response is outside the authorized store")
            products.extend(result["items"])
            if page >= result["page_count"]:
                break
            page += 1
        if len(products) != expected_total or len({item["product"]["product_id"] for item in products}) != len(products):
            raise DataUnavailableError("Restock priority coverage is incomplete")
        return products

    def _build(self, *, profile: SessionProfile, session_token: str,
               now: datetime, unit: str | None, category: str | None,
               product_id: str | None, search: str | None,
               scope_search: str | None = None) -> list[dict[str, Any]]:
        products = self._snapshot_rows(profile=profile, unit=unit,
                                       category=category, product_id=product_id,
                                       search=scope_search or search)
        if scope_search and search:
            needle = search.casefold()
            products = [item for item in products if needle in
                        (item["product"].get("name") or "").casefold() or needle in
                        (item["product"].get("sku") or "").casefold()]

        def evaluate(item: dict[str, Any]) -> dict[str, Any]:
            product = item["product"]
            product_id_value = product["product_id"]
            row: dict[str, Any] = {
                "product_id": product_id_value,
                "product_name": product["name"],
                "sku": product.get("sku") or "",
                "category": product.get("category") or "Uncategorized",
                "inventory_unit": product["unit"],
                "status": "missing", "suggested_quantity": None,
                "at_reorder_point": None,
                "reorder_gap_ratio": None, "target_gap_ratio": None,
                "forecast_job_status": (item.get("job") or {}).get("status"),
                "forecast_status": item["status"],
            }
            status = item["status"]
            if status == "stale":
                row["status"] = "stale"
            elif status == "completed" and item.get("snapshot") is not None:
                stage = "saved_forecast"
                try:
                    detail = self._snapshots.product(
                        location_id=profile.location_id,
                        product_id=product_id_value, model_key="lightgbm",
                    )["items"][0]
                    detail_product = detail["product"]
                    if (detail_product["location_id"] != profile.location_id
                            or detail_product["product_id"] != product_id_value):
                        raise DataUnavailableError("Restock forecast scope changed")
                    if detail["status"] != "completed" or not isinstance(detail.get("snapshot"), dict):
                        row["status"] = "stale"
                        return row
                    stage = "current_inputs"
                    context = self._adapter.load_operational_context(
                        profile=profile, session_token=session_token,
                        product_id=product_id_value, now=now,
                    )
                    stage = "recommendation"
                    analysis = current_stock_analysis(
                        service=self._service, profile=profile, context=context,
                        snapshot={**detail["snapshot"], "product_id": product_id_value,
                                  "location_id": profile.location_id}, now=now,
                    )
                    recommendation = analysis["recommendation"]
                    if recommendation["forecast_basis"]["model"] != "lightgbm":
                        raise ValueError("Recommendation source is not LightGBM")
                    row["status"] = recommendation["status"]
                    row["suggested_quantity"] = recommendation["suggested_quantity"]["inventory_units"]
                    row["at_reorder_point"] = recommendation["reorder_alert"]["at_or_below_reorder_point"]
                    position = _number(recommendation["inventory_position"])
                    reorder = _number(recommendation["reorder_point"])
                    target = _number(recommendation["target_inventory"])
                    if position is not None and reorder is not None and reorder > 0:
                        row["reorder_gap_ratio"] = str(max(Decimal(0), reorder - position) / reorder)
                    if position is not None and target is not None and target > 0:
                        row["target_gap_ratio"] = str(max(Decimal(0), target - position) / target)
                except (DataUnavailableError, ProductNotFoundError, httpx.HTTPError,
                        KeyError, IndexError, TypeError, ValueError) as error:
                    row["status"] = "unavailable"
                    row["reason_code"], row["reason"] = _unavailable_reason(stage, error)
            return row

        # Bound upstream traffic while keeping ranking independent of the
        # chart page and selected visualization model.
        rows = list(self._pool.map(evaluate, products))

        order = {"recommend_order": 0, "needs_review": 1,
                 "sufficient_inventory": 2, "stale": 3,
                 "missing": 4, "unavailable": 5}
        rows.sort(key=lambda row: (
            order.get(row["status"], 5),
            0 if row["at_reorder_point"] is True else 1,
            # Ratios are dimensionless, so different inventory units are never
            # compared by their raw quantities.
            -(_number(row["reorder_gap_ratio"]) or Decimal(0)),
            -(_number(row["target_gap_ratio"]) or Decimal(0)),
            row["product_id"],
        ))
        return rows
