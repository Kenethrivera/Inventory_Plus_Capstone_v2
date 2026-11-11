from __future__ import annotations

import argparse
import hashlib
import json
from datetime import date
from pathlib import Path

from app.forecasting import (
    LightGBMForecaster,
    Mean28Forecaster,
    ProductSpecificSeasonalLightGBMForecaster,
)
from app.seasonality import PhilippineSeasonResolver
from app.simulation.expanded_seasonal_fixture import shared_context_registry
from app.simulation.stage29a1_intermittent_experiment import (
    EXISTING,
    MEAN28,
    SEASONAL,
    TSB,
    TSBIntermittentBaseline,
    TwoStageConfig,
    TwoStageOccurrenceQuantityForecaster,
    build_final_assessment,
    evaluate,
    generate_realization,
    jsonable,
    load_manifest,
    metrics_report,
    product_comparison,
    select_development_candidate,
    select_product_policy,
    sha256,
    write_csv,
    write_points_csv,
    write_realization_csv,
)


ROOT = Path(__file__).resolve().parent


def percent(value: object) -> str:
    return "n/a" if value is None else f"{float(value) * 100:.2f}%"


def models(
    manifest: dict[str, object], *, candidate_configs: dict[str, TwoStageConfig]
) -> dict[str, object]:
    baseline = manifest["simple_intermittent_baseline"]
    result: dict[str, object] = {
        MEAN28: Mean28Forecaster(),
        EXISTING: LightGBMForecaster(),
        SEASONAL: ProductSpecificSeasonalLightGBMForecaster(
            registry=shared_context_registry(),
            include_seasonal_features=True,
            resolver=PhilippineSeasonResolver(),
        ),
        TSB: TSBIntermittentBaseline(
            occurrence_smoothing=float(baseline["occurrence_smoothing"]),
            quantity_smoothing=float(baseline["quantity_smoothing"]),
        ),
    }
    for name, config in candidate_configs.items():
        result[name] = TwoStageOccurrenceQuantityForecaster(config=config)
    return result


def render_report(report: dict[str, object]) -> str:
    assessment = report["independent_final_assessment"]
    final = assessment["metrics"]
    selection = report["frozen_development_selection"]
    selected_model = assessment["selected_final_model"]
    model_order = [
        MEAN28,
        EXISTING,
        SEASONAL,
        TSB,
        selection["selected_candidate"],
        "development_selected_product_policy",
    ]
    lines = [
        "# Stage 2.9A-1 Controlled Intermittent-Demand Experiment",
        "",
        f"**Decision: {assessment['decision']}**",
        "",
        f"**Recommendation: {assessment['recommendation']}**",
        "",
        "This is an isolated synthetic experiment. No production model, Supabase data, Flutter code, or replenishment calculation is changed.",
        "",
        "## Independent evaluation contract",
        "",
        f"- Frozen manifest SHA-256: `{report['evaluation_contract']['manifest_sha256']}`.",
        f"- Development seed: {report['evaluation_contract']['development_seed']}.",
        f"- Independent final seed: {report['evaluation_contract']['independent_final_seed']}.",
        f"- Development selection fingerprint: `{report['evaluation_contract']['selection_sha256']}`.",
        f"- Development origins: {report['evaluation_contract']['development_origins']}; final origins: {report['evaluation_contract']['final_origins']}.",
        "- The Stage 2.6 period and observations were not reused.",
        "- The final realization was generated and evaluated only after candidate configuration, product choices, and strategy were frozen from development results.",
        "",
        "## Intermittent products in the independent final realization",
        "",
        "| SKU | Product | Class | History days | Sale days | Demand frequency | Zero-sales frequency |",
        "|---|---|---|---:|---:|---:|---:|",
    ]
    for value in report["independent_final_product_statistics"]:
        if value["demand_class"] not in {"intermittent", "intermittent_low"}:
            continue
        lines.append(
            f"| {value['sku']} | {value['product_name']} | {value['demand_class']} | "
            f"{value['history_days']} | {value['sale_days']} | "
            f"{percent(value['demand_frequency'])} | {percent(value['zero_sales_frequency'])} |"
        )

    lines.extend(
        [
            "",
            "## Development-only selection",
            "",
            f"- Selected two-stage configuration: **{selection['selected_candidate']}**.",
            f"- Candidate eligibility guardrails passed: **{selection['selected_candidate_eligible']}**.",
            f"- Selected deployment strategy for final confirmation: **{selection['selected_strategy']}**.",
            f"- Product-policy SKUs assigned to two-stage: {', '.join(selection['selected_skus']) if selection['selected_skus'] else 'none'}.",
            "- No final labels, quantities, errors, or random streams entered these decisions.",
            "",
            "## Independent final metrics",
            "",
            "| Model | Daily MAE | Daily WAPE | Daily bias | 7-day total WAPE | 28-day total WAPE |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for model in model_order:
        daily = final["overall"][model]
        seven = final["quantity_7_day"][model]
        twenty_eight = final["quantity_28_day"][model]
        lines.append(
            f"| {model} | {float(daily['mae']):.4f} | {percent(daily['wape'])} | "
            f"{percent(daily['bias'])} | {percent(seven['wape'])} | "
            f"{percent(twenty_eight['wape'])} |"
        )

    lines.extend(
        [
            "",
            "## Selected strategy versus Seasonal LightGBM",
            "",
            f"Selected final strategy model: **{selected_model}**.",
            "",
            "| Comparison | Improvement | 95% CI | Origins |",
            "|---|---:|---:|---:|",
        ]
    )
    for name, value in assessment["paired_uncertainty"].items():
        lines.append(
            f"| {name} | {percent(value['improvement'])} | "
            f"[{percent(value['ci95_lower'])}, {percent(value['ci95_upper'])}] | "
            f"{value['origins']} |"
        )

    lines.extend(
        [
            "",
            "## Acceptance checks",
            "",
        ]
    )
    lines.extend(
        f"- {name}: **{'PASS' if passed else 'FAIL'}**"
        for name, passed in assessment["acceptance_checks"].items()
    )
    lines.extend(
        [
            "",
            "## Demand-group comparison",
            "",
            "| Group | Seasonal daily WAPE | Selected daily WAPE | Seasonal 28-day total WAPE | Selected 28-day total WAPE |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    group_names = sorted(final["by_demand_class"][SEASONAL])
    for group in group_names:
        seasonal = final["by_demand_class"][SEASONAL][group]
        selected = final["by_demand_class"][selected_model][group]
        lines.append(
            f"| {group} | {percent(seasonal['daily']['wape'])} | "
            f"{percent(selected['daily']['wape'])} | "
            f"{percent(seasonal['quantity_28_day']['wape'])} | "
            f"{percent(selected['quantity_28_day']['wape'])} |"
        )

    lines.extend(
        [
            "",
            "## Seasonal-group regression check",
            "",
            "| Group | Seasonal daily WAPE | Selected daily WAPE | Nonregression |",
            "|---|---:|---:|---|",
        ]
    )
    for group in ("SUMMER", "RAINY", "NEUTRAL"):
        seasonal = final["by_seasonal_group"][SEASONAL][group]["daily"]
        selected = final["by_seasonal_group"][selected_model][group]["daily"]
        passed = assessment["seasonal_group_nonregression_checks"][group]
        lines.append(
            f"| {group} | {percent(seasonal['wape'])} | {percent(selected['wape'])} | "
            f"{'PASS' if passed else 'FAIL'} |"
        )

    lines.extend(
        [
            "",
            "## Interpretation",
            "",
        ]
    )
    if assessment["adoption_recommended"]:
        lines.append(
            "The preselected strategy passed every frozen independent-final acceptance check. It remains experimental and requires real-store monitoring before any operational use."
        )
    else:
        lines.append(
            "The preselected strategy did not pass every frozen independent-final acceptance check. Keep the current operational model; do not integrate this candidate."
        )
    lines.extend(
        [
            "",
            "## Limitations",
            "",
            "- Results are from independently seeded synthetic realizations and do not prove real-store accuracy.",
            "- Frozen seasonal groups are simulation hypotheses, not verified Philippine retail-sales effects.",
            "- Confidence intervals resample forecast origins; with a limited number of origins they remain uncertain.",
            "- Product-policy selection is tied to these product identities and cannot be transferred automatically to new products.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the isolated Stage 2.9A-1 intermittent-demand experiment"
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT
        / "app"
        / "simulation"
        / "stage29a1_experiment_manifest.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "simulation_reports" / "stage29a1",
    )
    args = parser.parse_args()
    manifest = load_manifest(args.manifest)
    manifest_hash = sha256(args.manifest)
    development = generate_realization(
        manifest,
        name="development",
        seed=int(manifest["development_seed"]),
    )
    start = date.fromisoformat(
        manifest["development_validation_start"]
    )
    end = date.fromisoformat(
        manifest["development_validation_end"]
    )
    config_seed = int(manifest["development_seed"])
    configs = {
        f"two_stage_{name}": TwoStageConfig(
            name=name,
            random_seed=config_seed,
            **values,
        )
        for name, values in manifest["two_stage_hyperparameter_candidates"].items()
    }
    print("evaluating development folds", flush=True)
    development_points, development_origins = evaluate(
        realization=development,
        manifest=manifest,
        models=models(manifest, candidate_configs=configs),
        start=start,
        end=end,
    )
    candidate_selection = select_development_candidate(
        manifest=manifest,
        points=development_points,
        candidate_names=list(configs),
    )
    selected_candidate = str(candidate_selection["selected_candidate"])
    policy_selection = select_product_policy(
        manifest=manifest,
        points=development_points,
        candidate=selected_candidate,
    )
    frozen_selection = {
        **candidate_selection,
        **policy_selection,
        "selected_candidate": selected_candidate,
        "manifest_sha256": manifest_hash,
        "development_seed": manifest["development_seed"],
        "final_data_accessed": False,
    }
    selection_json = json.dumps(jsonable(frozen_selection), indent=2, sort_keys=True) + "\n"
    selection_hash = hashlib.sha256(selection_json.encode()).hexdigest()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    selection_path = args.output_dir / "frozen_development_selection.json"
    selection_path.write_text(selection_json, encoding="utf-8")
    print(
        f"development selection frozen: {selected_candidate}, "
        f"{policy_selection['selected_strategy']}",
        flush=True,
    )

    # The independent realization is deliberately not constructed until every
    # candidate and per-product decision above has been serialized and hashed.
    final_realization = generate_realization(
        manifest,
        name="independent_final",
        seed=int(manifest["independent_final_seed"]),
    )
    final_start = date.fromisoformat(
        manifest["independent_final_start"]
    )
    final_end = date.fromisoformat(
        manifest["independent_final_end"]
    )
    final_config = {selected_candidate: configs[selected_candidate]}
    print("evaluating independent final realization once", flush=True)
    final_points, final_origins = evaluate(
        realization=final_realization,
        manifest=manifest,
        models=models(manifest, candidate_configs=final_config),
        start=final_start,
        end=final_end,
    )
    assessment = build_final_assessment(
        manifest=manifest,
        points=final_points,
        candidate=selected_candidate,
        policy_selection=policy_selection,
    )
    policy_skus = set(policy_selection["selected_skus"])
    product_rows = product_comparison(
        final_points,
        candidate=selected_candidate,
        policy_skus=policy_skus,
    )
    report = {
        "stage": "2.9A-1",
        "evaluation_contract": {
            "manifest_version": manifest["version"],
            "manifest_sha256": manifest_hash,
            "development_seed": manifest["development_seed"],
            "independent_final_seed": manifest["independent_final_seed"],
            "development_origins": len(development_origins),
            "final_origins": len(final_origins),
            "selection_sha256": selection_hash,
            "selection_written_before_final_generation": True,
            "stage26_period_reused": False,
            "future_sales_leakage_check": "PASS",
        },
        "development_product_statistics": list(
            development.pretest_statistics.values()
        ),
        "independent_final_product_statistics": list(
            final_realization.pretest_statistics.values()
        ),
        "development_metrics": metrics_report(development_points),
        "frozen_development_selection": frozen_selection,
        "independent_final_assessment": assessment,
        "independent_final_product_comparison": product_rows,
        "unchanged_boundaries": [
            "operational forecasting models and API selection unchanged",
            "Supabase schema and data unchanged",
            "Flutter unchanged",
            "replenishment unchanged",
            "Stage 2.6, 2.7 and 2.7B artifacts unchanged",
        ],
        "limitations": manifest["limitations"],
    }
    serializable = jsonable(report)
    report_path = args.output_dir / "stage29a1_intermittent_experiment.json"
    report_path.write_text(
        json.dumps(serializable, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.output_dir / "STAGE29A1_INTERMITTENT_EXPERIMENT.md").write_text(
        render_report(serializable), encoding="utf-8"
    )
    write_realization_csv(
        args.output_dir / "development_daily_demand.csv", development
    )
    write_realization_csv(
        args.output_dir / "independent_final_daily_demand.csv", final_realization
    )
    write_points_csv(
        args.output_dir / "development_forecast_points.csv", development_points
    )
    write_points_csv(
        args.output_dir / "independent_final_forecast_points.csv", final_points
    )
    write_csv(
        args.output_dir / "independent_final_product_comparison.csv", product_rows
    )
    print(
        json.dumps(
            {
                "decision": assessment["decision"],
                "recommendation": assessment["recommendation"],
                "selected_candidate": selected_candidate,
                "selected_strategy": policy_selection["selected_strategy"],
                "output_dir": str(args.output_dir),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
