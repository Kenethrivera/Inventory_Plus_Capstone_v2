from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Any, Iterable

from app.data.models import DailyDemand
from app.forecasting import ForecastProduct, HistoricalDemandDataset, Mean28Forecaster
from app.recommendations import (
    DemandForecastSnapshot,
    InventoryBalanceBasis,
    InventorySnapshot,
    RecommendationEngine,
    RecommendationPolicy,
    RecommendationResult,
    SafetyStockInput,
    SafetyStockSource,
    SupplierAvailability,
    SupplierPolicySnapshot,
    UnitConversion,
)


LOCATION_ID = "11111111-1111-4111-8111-111111111111"
PRODUCT_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
NOW = datetime(2026, 11, 11, 12, tzinfo=timezone.utc)
HISTORY_END = date(2026, 11, 10)


def _product() -> ForecastProduct:
    return ForecastProduct(
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        sku="SIM-SUM-001",
        product_name="Concrete Hollow Blocks",
        unit="pcs",
    )


def forecast_snapshot(
    daily_quantity: Decimal,
    *,
    history_days: int = 28,
    no_history: bool = False,
) -> DemandForecastSnapshot:
    history_start = None if no_history else HISTORY_END - timedelta(days=history_days - 1)
    observations: list[DailyDemand] = []
    if history_start is not None and daily_quantity > 0:
        observations = [
            DailyDemand(
                business_date=history_start + timedelta(days=index),
                location_id=LOCATION_ID,
                product_id=PRODUCT_ID,
                sku="SIM-SUM-001",
                product_name="Concrete Hollow Blocks",
                unit="pcs",
                quantity=daily_quantity,
                completed_order_count=1,
            )
            for index in range(history_days)
        ]
    history = HistoricalDemandDataset.from_synthetic_observations(
        product=_product(),
        history_start=history_start,
        history_end=HISTORY_END,
        observations=observations,
    )
    forecasts = Mean28Forecaster().forecast(history, horizon_days=28)
    return DemandForecastSnapshot(
        forecasts=tuple(forecasts),
        generated_at=NOW,
        source_data_as_of=NOW,
    )


def inventory(
    *,
    on_hand: Decimal | None = Decimal("100"),
    incoming: Decimal | None = Decimal("0"),
    reservations: Decimal | None = Decimal("0"),
    backorders: Decimal | None = Decimal("0"),
    capacity: Decimal | None = Decimal("500"),
) -> InventorySnapshot:
    return InventorySnapshot(
        location_id=LOCATION_ID,
        product_id=PRODUCT_ID,
        unit="pcs",
        saleable_on_hand=on_hand,
        confirmed_on_order=incoming,
        unfulfilled_reservations=reservations,
        backorders=backorders,
        max_capacity=capacity,
        balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,
        captured_at=NOW,
    )


def supplier(
    *,
    lead_time: int | None = 5,
    moq: Decimal | None = Decimal("0"),
    pack_size: Decimal | None = Decimal("1"),
    order_unit: str = "pcs",
    availability: SupplierAvailability = SupplierAvailability.AVAILABLE,
    captured_at: datetime = NOW,
) -> SupplierPolicySnapshot:
    return SupplierPolicySnapshot(
        supplier_id="isolated-supplier-fixture",
        order_unit=order_unit,
        lead_time_days=lead_time,
        minimum_order_quantity=moq,
        pack_size=pack_size,
        availability=availability,
        captured_at=captured_at,
    )


def safety(quantity: Decimal = Decimal("20")) -> SafetyStockInput:
    return SafetyStockInput(
        quantity=quantity,
        unit="pcs",
        source=SafetyStockSource.CONFIGURED,
        captured_at=NOW,
    )


def policy(*, review_period: int | None = 7) -> RecommendationPolicy:
    return RecommendationPolicy(
        version="stage29b-isolated-v1",
        review_period_days=review_period,
        max_forecast_age=timedelta(days=2),
        max_inventory_age=timedelta(days=1),
        max_supplier_age=timedelta(days=30),
        max_safety_stock_age=timedelta(days=30),
    )


def _snapshot(result: RecommendationResult) -> dict[str, Any]:
    calculation = result.calculation
    return {
        "status": result.status.value,
        "inventory_position": calculation.inventory_position,
        "lead_time_demand": calculation.expected_lead_time_demand,
        "safety_stock": calculation.safety_stock,
        "reorder_point": calculation.reorder_point,
        "protection_period_days": calculation.protection_period_days,
        "protection_period_demand": calculation.forecasted_protection_period_demand,
        "order_up_to_target": calculation.target_inventory,
        "preliminary_inventory_units": calculation.preliminary_quantity_inventory_units,
        "rounded_order_units": result.recommended_quantity_order_units,
        "suggested_inventory_units": result.recommended_quantity_inventory_units,
        "capacity_room_inventory_units": calculation.capacity_room_inventory_units,
        "warnings": list(result.warnings),
        "explanations": list(result.explanations),
        "human_approval_required": result.requires_human_approval,
        "purchase_order_created": result.purchase_order_created,
    }


def _json_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {key: _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return value


def _scenario(
    name: str,
    result: RecommendationResult,
    *,
    expected: dict[str, Any],
    required_warnings: Iterable[str] = (),
) -> dict[str, Any]:
    actual = _snapshot(result)
    mismatches: list[str] = []
    for field, expected_value in expected.items():
        if actual.get(field) != expected_value:
            mismatches.append(
                f"{field}: expected {expected_value!r}, got {actual.get(field)!r}"
            )
    for warning in required_warnings:
        if warning not in actual["warnings"]:
            mismatches.append(f"missing warning: {warning}")
    suggested = result.recommended_quantity_inventory_units
    if (
        suggested is not None
        and suggested > 0
        and not result.requires_human_approval
    ):
        mismatches.append("positive suggestions must require human approval")
    if actual["purchase_order_created"]:
        mismatches.append("purchase_order_created must remain false")
    return {
        "scenario": name,
        "passed": not mismatches,
        "expected": _json_value(expected),
        "actual": _json_value(actual),
        "mismatches": mismatches,
    }


def run_validation() -> dict[str, Any]:
    engine = RecommendationEngine()

    def recommend(
        *,
        forecast: DemandForecastSnapshot | None = None,
        inventory_snapshot: InventorySnapshot | None = None,
        supplier_snapshot: SupplierPolicySnapshot | None = None,
        safety_input: SafetyStockInput | None = None,
        recommendation_policy: RecommendationPolicy | None = None,
        conversions: tuple[UnitConversion, ...] = (),
    ) -> RecommendationResult:
        return engine.recommend(
            forecast=forecast or forecast_snapshot(Decimal("10")),
            inventory=inventory_snapshot or inventory(),
            supplier=supplier_snapshot or supplier(),
            safety_stock=safety() if safety_input is None else safety_input,
            policy=recommendation_policy or policy(),
            recommendation_at=NOW,
            conversions=conversions,
        )

    scenarios: list[dict[str, Any]] = []

    missing = recommend(
        inventory_snapshot=inventory(incoming=None, backorders=None),
        supplier_snapshot=supplier(lead_time=None),
        recommendation_policy=policy(review_period=None),
    )
    scenarios.append(
        _scenario(
            "concrete_blocks_missing_verified_inputs",
            missing,
            expected={
                "status": "needs_review",
                "inventory_position": None,
                "protection_period_days": None,
                "suggested_inventory_units": None,
                "human_approval_required": True,
                "purchase_order_created": False,
            },
            required_warnings=(
                "confirmed_on_order_missing",
                "backorders_missing",
                "supplier_lead_time_missing",
                "review_period_missing",
            ),
        )
    )

    complete = recommend(
        inventory_snapshot=inventory(
            on_hand=Decimal("100"),
            incoming=Decimal("20"),
            backorders=Decimal("5"),
            capacity=Decimal("160"),
        ),
        supplier_snapshot=supplier(
            lead_time=5,
            moq=Decimal("2"),
            pack_size=Decimal("1"),
            order_unit="pallet",
        ),
        conversions=(
            UnitConversion(
                from_unit="pallet",
                to_unit="pcs",
                factor=Decimal("10"),
            ),
        ),
    )
    scenarios.append(
        _scenario(
            "concrete_blocks_complete_verified_inputs",
            complete,
            expected={
                "status": "recommend_order",
                "inventory_position": Decimal("115"),
                "lead_time_demand": Decimal("50"),
                "safety_stock": Decimal("20"),
                "reorder_point": Decimal("70"),
                "protection_period_days": 12,
                "protection_period_demand": Decimal("120"),
                "order_up_to_target": Decimal("140"),
                "preliminary_inventory_units": Decimal("25"),
                "rounded_order_units": Decimal("3"),
                "suggested_inventory_units": Decimal("30"),
                "capacity_room_inventory_units": Decimal("40"),
                "human_approval_required": True,
                "purchase_order_created": False,
            },
        )
    )

    confirmed_zero = recommend(
        inventory_snapshot=inventory(
            on_hand=Decimal("100"),
            incoming=Decimal("0"),
            backorders=Decimal("0"),
        )
    )
    scenarios.append(
        _scenario(
            "confirmed_zero_incoming_and_backorders",
            confirmed_zero,
            expected={
                "inventory_position": Decimal("100"),
                "suggested_inventory_units": Decimal("40"),
            },
        )
    )

    stale_supplier = recommend(
        supplier_snapshot=supplier(captured_at=NOW - timedelta(days=31))
    )
    scenarios.append(
        _scenario(
            "stale_supplier_information",
            stale_supplier,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": Decimal("40"),
                "human_approval_required": True,
            },
            required_warnings=("supplier_snapshot_stale",),
        )
    )

    high_inventory = recommend(
        inventory_snapshot=inventory(on_hand=Decimal("150"))
    )
    scenarios.append(
        _scenario(
            "high_inventory",
            high_inventory,
            expected={
                "status": "sufficient_inventory",
                "suggested_inventory_units": Decimal("0"),
                "purchase_order_created": False,
            },
        )
    )

    low_inventory = recommend(
        inventory_snapshot=inventory(on_hand=Decimal("0"))
    )
    scenarios.append(
        _scenario(
            "low_inventory",
            low_inventory,
            expected={
                "status": "recommend_order",
                "order_up_to_target": Decimal("140"),
                "suggested_inventory_units": Decimal("140"),
            },
        )
    )

    overprediction = recommend(
        forecast=forecast_snapshot(Decimal("20")),
        inventory_snapshot=inventory(on_hand=Decimal("100")),
    )
    scenarios.append(
        _scenario(
            "large_forecast_overprediction_fixture",
            overprediction,
            expected={
                "reorder_point": Decimal("120"),
                "order_up_to_target": Decimal("260"),
                "suggested_inventory_units": Decimal("160"),
            },
        )
    )

    underprediction = recommend(
        forecast=forecast_snapshot(Decimal("2")),
        inventory_snapshot=inventory(on_hand=Decimal("100")),
    )
    scenarios.append(
        _scenario(
            "large_forecast_underprediction_fixture",
            underprediction,
            expected={
                "reorder_point": Decimal("30"),
                "order_up_to_target": Decimal("44"),
                "suggested_inventory_units": Decimal("0"),
            },
        )
    )

    known_zero_sales = recommend(
        forecast=forecast_snapshot(Decimal("0")),
        inventory_snapshot=inventory(on_hand=Decimal("0")),
    )
    scenarios.append(
        _scenario(
            "known_zero_sales_history",
            known_zero_sales,
            expected={
                "lead_time_demand": Decimal("0"),
                "order_up_to_target": Decimal("20"),
                "suggested_inventory_units": Decimal("20"),
            },
        )
    )

    no_history = recommend(
        forecast=forecast_snapshot(Decimal("0"), no_history=True)
    )
    scenarios.append(
        _scenario(
            "no_sales_history_cold_start",
            no_history,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": None,
            },
            required_warnings=("no_history_demand_unknown",),
        )
    )

    insufficient = recommend(
        forecast=forecast_snapshot(Decimal("10"), history_days=7)
    )
    scenarios.append(
        _scenario(
            "insufficient_sales_history",
            insufficient,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": Decimal("40"),
                "human_approval_required": True,
            },
            required_warnings=("cold_start_forecast_requires_review",),
        )
    )

    invalid = recommend(
        inventory_snapshot=inventory(on_hand=Decimal("-1"))
    )
    scenarios.append(
        _scenario(
            "invalid_negative_inventory",
            invalid,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": None,
            },
            required_warnings=("saleable_on_hand_invalid",),
        )
    )

    capacity_conflict = recommend(
        inventory_snapshot=inventory(
            on_hand=Decimal("100"), capacity=Decimal("140")
        ),
        supplier_snapshot=supplier(
            moq=Decimal("50"), pack_size=Decimal("10")
        ),
    )
    scenarios.append(
        _scenario(
            "capacity_supplier_constraint_conflict",
            capacity_conflict,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": None,
                "capacity_room_inventory_units": Decimal("40"),
            },
            required_warnings=("capacity_conflicts_with_supplier_constraints",),
        )
    )

    unavailable = recommend(
        supplier_snapshot=supplier(availability=SupplierAvailability.UNAVAILABLE)
    )
    scenarios.append(
        _scenario(
            "supplier_unavailable",
            unavailable,
            expected={
                "status": "needs_review",
                "suggested_inventory_units": Decimal("40"),
                "human_approval_required": True,
            },
            required_warnings=("supplier_unavailable_or_unknown",),
        )
    )

    passed = all(item["passed"] for item in scenarios)
    return {
        "stage": "2.9B",
        "decision": "PASS" if passed else "FAIL",
        "scope": {
            "data_source": "isolated deterministic fixtures",
            "supabase_writes": False,
            "purchase_orders_created": False,
            "forecast_models_changed": False,
            "replenishment_policy_changed": False,
        },
        "scenario_count": len(scenarios),
        "passed_count": sum(1 for item in scenarios if item["passed"]),
        "failed_count": sum(1 for item in scenarios if not item["passed"]),
        "scenarios": scenarios,
        "api_contracts": {
            "seasonal_experimental_is_display_only": (
                "Covered by test_api.test_experimental_model_is_explicit_and_"
                "replenishment_is_isolated; recommendation quantities are compared "
                "field-for-field with existing LightGBM."
            ),
            "read_only_capabilities": (
                "API response declares inventory_mutation=false and "
                "purchase_order_creation=false."
            ),
        },
        "limitations": [
            "Fixtures validate policy math and contracts, not live supplier records.",
            "Forecast error scenarios validate sensitivity; they do not repair forecast error.",
            "No live Supabase row was modified or used as a configured-input fixture.",
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Stage 2.9B Replenishment Validation",
        "",
        f"**Decision: {report['decision']}**",
        "",
        "All calculations use isolated deterministic fixtures. No Supabase data, "
        "forecast model, inventory quantity, or purchase-order state was changed.",
        "",
        "## Scenario results",
        "",
        "| Scenario | Result | Status | Inventory position | Reorder point | Target | Suggested |",
        "|---|---|---|---:|---:|---:|---:|",
    ]
    for scenario in report["scenarios"]:
        actual = scenario["actual"]
        lines.append(
            "| {name} | {result} | {status} | {position} | {reorder} | {target} | {suggested} |".format(
                name=scenario["scenario"],
                result="PASS" if scenario["passed"] else "FAIL",
                status=actual["status"],
                position=actual["inventory_position"],
                reorder=actual["reorder_point"],
                target=actual["order_up_to_target"],
                suggested=actual["suggested_inventory_units"],
            )
        )
    complete = next(
        item
        for item in report["scenarios"]
        if item["scenario"] == "concrete_blocks_complete_verified_inputs"
    )["actual"]
    missing = next(
        item
        for item in report["scenarios"]
        if item["scenario"] == "concrete_blocks_missing_verified_inputs"
    )["actual"]
    lines.extend(
        [
            "",
            "## Concrete Hollow Blocks calculation",
            "",
            "The complete fixture uses 10 pcs/day forecast demand, 100 pcs on hand, "
            "20 pcs confirmed incoming, 5 pcs backorders, five lead-time days, seven "
            "review days, 20 pcs safety stock, and 10 pcs per pallet.",
            "",
            f"- Inventory position: `{complete['inventory_position']} pcs`.",
            f"- Lead-time demand: `{complete['lead_time_demand']} pcs`.",
            f"- Reorder point: `{complete['reorder_point']} pcs`.",
            f"- Protection period: `{complete['protection_period_days']} days`.",
            f"- Order-up-to target: `{complete['order_up_to_target']} pcs`.",
            f"- Preliminary quantity: `{complete['preliminary_inventory_units']} pcs`.",
            f"- Rounded suggestion: `{complete['rounded_order_units']} pallets` / "
            f"`{complete['suggested_inventory_units']} pcs`.",
            "",
            "The missing-input fixture returns `NEEDS_REVIEW` with no quantity. Its "
            "blocking warnings are:",
            "",
        ]
    )
    lines.extend(f"- `{warning}`" for warning in missing["warnings"])
    lines.extend(
        [
            "",
            "## Safety boundaries",
            "",
            "- Confirmed numeric zero remains distinct from unknown/null.",
            "- Seasonal Experimental remains display-only for replenishment; the API "
            "test compares its recommendation with existing LightGBM field-for-field.",
            "- Every positive suggestion requires human approval.",
            "- Every scenario reports `purchase_order_created=false`.",
            "- API capabilities remain read-only with no inventory mutation or purchase-order creation.",
            "",
            "## Limitations",
            "",
        ]
    )
    lines.extend(f"- {item}" for item in report["limitations"])
    return "\n".join(lines) + "\n"

