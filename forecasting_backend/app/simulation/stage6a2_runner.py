from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import replace
from datetime import date
from decimal import Decimal
from pathlib import Path

from .generator import SyntheticHardwareStoreGenerator
from .models import SimulationConfig
from .policy_comparison import ExtendedInventoryPolicySimulator
from .robustness import RobustForecastEvaluator
from .stage6a2_models import SeedResult, Stage6A2Report, StressResult


FULL_SEEDS = (2606, 4107, 9917)


def run_stage6a2(*, profile: str, source_revision: str) -> Stage6A2Report:
    if profile not in {"small", "full"}:
        raise ValueError("profile must be small or full")
    generator = SyntheticHardwareStoreGenerator()
    seeds = FULL_SEEDS
    seed_results: list[SeedResult] = []
    first_evaluator: RobustForecastEvaluator | None = None
    for seed in seeds:
        config = _seed_config(profile, seed)
        scenario = generator.generate(config)
        evaluator = RobustForecastEvaluator(config)
        first_evaluator = first_evaluator or evaluator
        result = evaluator.evaluate(scenario)
        seed_results.append(
            SeedResult(
                seed=seed,
                configuration=config,
                forecasts=result.reports,
                warnings=_forecast_warnings(result.reports),
            )
        )

    cold_config = _cold_start_config(profile)
    cold_scenario = generator.generate(cold_config)
    cold_result = RobustForecastEvaluator(
        cold_config, include_launch_origins=True
    ).evaluate(cold_scenario)

    policy_config = _policy_config(profile)
    policy_scenario = generator.generate(policy_config)
    policy_results = ExtendedInventoryPolicySimulator(policy_config).compare(
        policy_scenario
    )

    stress_results: list[StressResult] = []
    for name, stress_config in _stress_configs(profile):
        scenario = generator.generate(stress_config)
        forecasts = RobustForecastEvaluator(stress_config).evaluate(scenario)
        policies = ExtendedInventoryPolicySimulator(stress_config).compare(scenario)
        stress_results.append(
            StressResult(
                name=name,
                configuration=stress_config,
                forecasts=forecasts.reports,
                policies=policies,
                warnings=_forecast_warnings(forecasts.reports)
                + _policy_warnings(policies),
            )
        )

    assert first_evaluator is not None
    return Stage6A2Report(
        report_version="stage6a2-v1",
        created_on=date.today(),
        source_revision=source_revision,
        seeds=seeds,
        model_configuration={
            **first_evaluator.model_configuration,
            "random_seed": "configured separately for each seed result",
            "profile": profile,
        },
        seed_results=tuple(seed_results),
        cold_start_configuration=cold_config,
        cold_start_result=cold_result,
        policy_configuration=policy_config,
        policy_results=policy_results,
        stress_results=tuple(stress_results),
        assumptions=(
            "Every candidate within a seed receives identical latent demand and supplier conditions.",
            "Forecast metrics target future underlying net demand before stock censoring.",
            "MAE is measured in product inventory units; WAPE and signed bias are ratios.",
            "Total assumed inventory cost is holding cost plus fixed ordering cost only.",
            "No stockout penalty is introduced because no justified client value is available.",
            "Manual cold-start estimates are configured synthetic assumptions requiring human review.",
        ),
        safeguards=(
            "Retain Mean28 fallback whenever LightGBM or blend validation is unavailable.",
            "Use a provisional manual estimate for no-history and insufficient-history origins.",
            "Treat the intermittent guardrail as an experimental candidate, not a silent LightGBM change.",
            "Require chronological validation before selecting an ML candidate for a product/location.",
            "Prefer category-aware model selection because aggregate WAPE hides intermittent-demand bias.",
        ),
        warnings=(
            "Stage 6A seed-2606 reference files were not overwritten by this runner.",
            "Synthetic results do not establish real hardware-store accuracy or stockout reduction.",
            "Stress configurations are research assumptions, not client supplier policies.",
        ),
        limitations=(
            "No canonical production supplier, safety-stock, or availability history is available.",
            "The synthetic generator cannot reproduce every real substitution, lost-sale, or supplier behavior.",
            "Stage 5A live Supabase behavioral verification remains pending in an isolated database.",
            "No production database, Flutter screen, POS workflow, or purchase order is modified.",
        ),
    )


def _seed_config(profile: str, seed: int) -> SimulationConfig:
    if profile == "full":
        return SimulationConfig(seed=seed)
    return SimulationConfig(
        start_date=date(2024, 1, 1),
        days=210,
        product_count=6,
        location_count=1,
        seed=seed,
        evaluation_days=56,
        evaluation_origins=1,
    )


def _cold_start_config(profile: str) -> SimulationConfig:
    return SimulationConfig(
        start_date=date(2024, 1, 1),
        days=731 if profile == "full" else 260,
        product_count=30 if profile == "full" else 4,
        location_count=2 if profile == "full" else 1,
        seed=6152,
        evaluation_days=180 if profile == "full" else 120,
        evaluation_origins=3 if profile == "full" else 1,
        new_product_probability=Decimal("0.40"),
        new_product_launch_offset_range=(
            (560, 690) if profile == "full" else (150, 215)
        ),
    )


def _policy_config(profile: str) -> SimulationConfig:
    return SimulationConfig(
        start_date=date(2024, 1, 1),
        days=500 if profile == "full" else 210,
        product_count=12 if profile == "full" else 3,
        location_count=2 if profile == "full" else 1,
        seed=6205,
        evaluation_days=70 if profile == "full" else 28,
        evaluation_origins=1,
        new_product_probability=Decimal("0.20"),
        new_product_launch_offset_range=(
            (380, 460) if profile == "full" else (150, 190)
        ),
    )


def _stress_configs(profile: str) -> tuple[tuple[str, SimulationConfig], ...]:
    common = SimulationConfig(
        start_date=date(2025, 1, 1),
        days=300 if profile == "full" else 180,
        product_count=6 if profile == "full" else 3,
        location_count=1,
        seed=6301,
        evaluation_days=35 if profile == "full" else 21,
        evaluation_origins=1,
        new_product_probability=Decimal("0"),
    )
    configurations = (
        (
            "short_lead_stable_demand",
            replace(
                common,
                review_period_days=3,
                supplier_lead_time_range=(2, 3),
                demand_variability_range=(Decimal("0.10"), Decimal("0.20")),
                spike_probability=Decimal("0.005"),
                delivery_delay_probability=Decimal("0.05"),
                maximum_delivery_delay_days=1,
                minimum_safety_stock_days=3,
                opening_stock_coverage_days=20,
                pack_size_options=(1, 2),
                moq_pack_multiple_options=(1,),
            ),
        ),
        (
            "long_variable_lead_low_safety",
            replace(
                common,
                review_period_days=14,
                supplier_lead_time_range=(10, 20),
                demand_variability_range=(Decimal("0.40"), Decimal("0.80")),
                spike_probability=Decimal("0.04"),
                delivery_delay_probability=Decimal("0.50"),
                maximum_delivery_delay_days=8,
                minimum_safety_stock_days=2,
                opening_stock_coverage_days=8,
            ),
        ),
        (
            "high_safety_stock",
            replace(
                common,
                supplier_lead_time_range=(5, 10),
                minimum_safety_stock_days=10,
                opening_stock_coverage_days=20,
            ),
        ),
        (
            "large_moq_and_pack",
            replace(
                common,
                pack_size_options=(12, 24),
                moq_pack_multiple_options=(3, 5),
                capacity_coverage_days=30,
                opening_stock_coverage_days=8,
            ),
        ),
        (
            "spike_and_variability_stress",
            replace(
                common,
                demand_variability_range=(Decimal("0.70"), Decimal("1.00")),
                spike_probability=Decimal("0.10"),
                opening_stock_coverage_days=5,
            ),
        ),
        (
            "extended_supplier_delay_stockouts",
            replace(
                common,
                review_period_days=14,
                supplier_lead_time_range=(20, 30),
                delivery_delay_probability=Decimal("1"),
                maximum_delivery_delay_days=14,
                opening_stock_coverage_days=2,
                minimum_safety_stock_days=2,
            ),
        ),
    )
    return configurations if profile == "full" else configurations[:2]


def _forecast_warnings(reports) -> tuple[str, ...]:
    warnings: list[str] = []
    for report in reports:
        slow = report.by_category.get("slow")
        if slow and slow.signed_bias is not None and slow.signed_bias <= Decimal("-0.30"):
            warnings.append(
                f"{report.requested_model}: slow-demand signed bias "
                f"{slow.signed_bias:.3f} is materially negative"
            )
        fallback_count = sum(
            count
            for model, count in report.actual_models.items()
            if "fallback" in model
        )
        if fallback_count:
            warnings.append(
                f"{report.requested_model}: {fallback_count} origins used fallback behavior"
            )
    return tuple(warnings)


def _policy_warnings(policies) -> tuple[str, ...]:
    warnings: list[str] = []
    for policy in policies:
        if policy.overall.maximum_consecutive_stockout_days >= 7:
            warnings.append(
                f"{policy.strategy}: maximum stockout run was "
                f"{policy.overall.maximum_consecutive_stockout_days} days"
            )
    return tuple(warnings)


def _source_revision() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description="Inventory Plus Stage 6A.2")
    parser.add_argument("--profile", choices=("small", "full"), default="small")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = run_stage6a2(
        profile=args.profile,
        source_revision=_source_revision(),
    )
    rendered = json.dumps(report.to_jsonable(), indent=2, sort_keys=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
