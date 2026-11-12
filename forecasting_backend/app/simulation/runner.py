from __future__ import annotations

import argparse
import json
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

from .evaluation import ForecastEvaluator
from .generator import SyntheticHardwareStoreGenerator
from .inventory import InventoryPolicySimulator
from .lifecycle import evaluate_cold_start_lifecycle
from .models import SimulationConfig, SimulationReport


def run_simulation(config: SimulationConfig) -> SimulationReport:
    scenario = SyntheticHardwareStoreGenerator().generate(config)
    forecast_reports = ForecastEvaluator(config).evaluate(scenario)
    inventory_outcomes = InventoryPolicySimulator(config).compare(scenario)
    cold_start = evaluate_cold_start_lifecycle(scenario)
    return SimulationReport(
        configuration=config,
        provenance=scenario.provenance,
        product_location_series=len(scenario.policies),
        period_start=config.start_date,
        period_end=config.start_date + timedelta(days=config.days - 1),
        forecast_reports=forecast_reports,
        inventory_outcomes=inventory_outcomes,
        cold_start=cold_start,
        error_analysis=_error_analysis(forecast_reports, inventory_outcomes),
        assumptions=(
            "Underlying target is net customer demand after cancellations and before stock censoring.",
            "Supplier, safety-stock, cost, approval, MOQ, pack, capacity, and delay values are synthetic assumptions.",
            "Stage 5C provisional quantities are approved by simulated staff when a numeric quantity is available.",
            "The baseline is a 28-day fulfilled-sales mean with the same review cadence and supplier constraints.",
            "WAPE and signed bias are ratios; MAE is expressed in inventory units.",
        ),
        limitations=(
            "Synthetic results do not establish hardware-store accuracy or real stockout reduction.",
            "Historical fulfilled sales come from a synthetic reference replenishment path.",
            "Returns are capped by each simulated strategy's fulfilled units.",
            "No production API credentials, Supabase records, or purchase orders are used.",
        ),
    )


def _error_analysis(forecast_reports, inventory_outcomes) -> tuple[str, ...]:
    notes: list[str] = []
    for report in forecast_reports:
        scored_categories = [
            (name, metrics)
            for name, metrics in report.by_category.items()
            if metrics.wape is not None
        ]
        if scored_categories:
            category, metrics = max(
                scored_categories, key=lambda value: value[1].wape
            )
            notes.append(
                f"{report.requested_model}: worst category was {category} "
                f"(daily WAPE {metrics.wape:.3f}, signed bias "
                f"{metrics.signed_bias:.3f})."
            )
        fallback_count = sum(
            count
            for model, count in report.actual_models.items()
            if "fallback" in model
        )
        if fallback_count:
            notes.append(
                f"{report.requested_model}: {fallback_count} holdout origins used "
                "a validated fallback instead of the requested candidate."
            )
    if forecast_reports:
        daily_best = min(
            forecast_reports,
            key=lambda value: value.daily.wape
            if value.daily.wape is not None
            else Decimal("Infinity"),
        )
        total_best = min(
            forecast_reports,
            key=lambda value: value.horizon_totals.wape
            if value.horizon_totals.wape is not None
            else Decimal("Infinity"),
        )
        notes.append(
            f"Lowest daily WAPE was {daily_best.requested_model}; lowest 28-day-total "
            f"WAPE was {total_best.requested_model}. Candidate ranking depends on the "
            "chosen error target."
        )
    for outcome in inventory_outcomes:
        notes.append(
            f"{outcome.strategy}: {outcome.unmet_demand_units} immediately unmet "
            f"units across {outcome.stockout_days} stockout days remained under "
            "synthetic delays and constraints."
        )
    return tuple(notes)


def main() -> None:
    parser = argparse.ArgumentParser(description="Inventory Plus Stage 6A simulation")
    parser.add_argument("--products", type=int, default=100)
    parser.add_argument("--locations", type=int, default=2)
    parser.add_argument("--days", type=int, default=731)
    parser.add_argument("--seed", type=int, default=2606)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="write the requested report without echoing the JSON payload",
    )
    args = parser.parse_args()
    config = SimulationConfig(
        start_date=date(2024, 1, 1),
        product_count=args.products,
        location_count=args.locations,
        days=args.days,
        seed=args.seed,
    )
    report = run_simulation(config)
    rendered = json.dumps(report.to_jsonable(), indent=2, sort_keys=True)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    if not args.quiet:
        print(rendered)


if __name__ == "__main__":
    main()
