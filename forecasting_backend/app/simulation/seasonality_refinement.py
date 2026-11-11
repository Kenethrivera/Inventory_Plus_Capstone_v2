from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .sales_seasonality_discovery import (
    DiscoveryResult,
    LearnedSeasonality,
    SalesSeasonalityDiscoverer,
)


class RefinementPolicy(str, Enum):
    DROP_CYCLE_SIGNIFICANCE = "drop_cycle_significance"
    DROP_BOOTSTRAP_SIGNIFICANCE = "drop_bootstrap_significance"
    NONREDUNDANT_COMBINED = "nonredundant_combined"


@dataclass(frozen=True)
class GateAudit:
    eligible_history: bool
    bic_direction_pass: bool
    bic_direction_margin: float | None
    effect_ci_excludes_zero: bool
    effect_ci_zero_margin: float | None
    positive_oos_point_gain: bool
    oos_point_gain_margin: float | None
    positive_oos_bootstrap_interval: bool
    oos_bootstrap_margin: float | None
    significant_cycle_count: int
    required_significant_cycles: int
    cycle_count_margin: int
    cycle_directions_consistent: bool
    seasonal_reversal: bool
    strong_trend_only_bic: bool
    neutral_effect_ci_spans_zero: bool
    neutral_oos_gain_not_significant: bool
    no_significant_cycles: bool
    failed_original_direction_gates: tuple[str, ...]
    failed_original_neutral_gates: tuple[str, ...]


@dataclass(frozen=True)
class RefinedResult:
    classification: LearnedSeasonality
    evidence_strength: str
    reason: str
    policy: RefinementPolicy
    audit: GateAudit


def audit_evidence(result: DiscoveryResult) -> GateAudit:
    eligible = (
        result.history_days >= SalesSeasonalityDiscoverer.MIN_HISTORY_DAYS
        and result.coverage_ratio
        >= SalesSeasonalityDiscoverer.MIN_COVERAGE_RATIO
        and result.positive_sales_days
        >= SalesSeasonalityDiscoverer.MIN_POSITIVE_DAYS
        and result.total_sales > 0
        and result.delta_bic_seasonal_vs_trend is not None
    )
    delta_bic = result.delta_bic_seasonal_vs_trend
    ci_low = result.effect_ci_low
    ci_high = result.effect_ci_high
    point_gain = result.oos_mae_gain
    bootstrap_low = result.oos_gain_ci_low
    significant = tuple(
        value
        for value in result.cycle_directions
        if value != "INCONCLUSIVE"
    )
    reversal = "SUMMER" in significant and "RAINY" in significant
    consistent = len(significant) >= 2 and len(set(significant)) == 1
    effect_pass = (
        ci_low is not None
        and ci_high is not None
        and (ci_low > 0 or ci_high < 0)
    )
    effect_margin = None
    if ci_low is not None and ci_high is not None:
        if ci_low > 0:
            effect_margin = ci_low
        elif ci_high < 0:
            effect_margin = -ci_high
        else:
            effect_margin = -min(abs(ci_low), abs(ci_high))

    original_direction = {
        "eligible_history": eligible,
        "delta_bic_at_least_6": (
            delta_bic is not None
            and delta_bic >= SalesSeasonalityDiscoverer.STRONG_BIC_DELTA
        ),
        "effect_ci_excludes_zero": effect_pass,
        "at_least_two_consistent_significant_cycles": consistent,
        "oos_bootstrap_ci_above_zero": (
            bootstrap_low is not None and bootstrap_low > 0
        ),
        "no_seasonal_reversal": not reversal,
    }
    original_neutral = {
        "eligible_history": eligible,
        "trend_only_bic_preferred": delta_bic is not None and delta_bic <= 0,
        "effect_ci_spans_zero": (
            ci_low is not None
            and ci_high is not None
            and ci_low <= 0 <= ci_high
        ),
        "oos_point_gain_not_positive": (
            point_gain is not None and point_gain <= 0
        ),
        "no_significant_cycles": not significant,
        "no_seasonal_reversal": not reversal,
    }
    return GateAudit(
        eligible_history=eligible,
        bic_direction_pass=original_direction["delta_bic_at_least_6"],
        bic_direction_margin=(
            None
            if delta_bic is None
            else delta_bic - SalesSeasonalityDiscoverer.STRONG_BIC_DELTA
        ),
        effect_ci_excludes_zero=effect_pass,
        effect_ci_zero_margin=effect_margin,
        positive_oos_point_gain=point_gain is not None and point_gain > 0,
        oos_point_gain_margin=point_gain,
        positive_oos_bootstrap_interval=(
            bootstrap_low is not None and bootstrap_low > 0
        ),
        oos_bootstrap_margin=bootstrap_low,
        significant_cycle_count=len(significant),
        required_significant_cycles=2,
        cycle_count_margin=len(significant) - 2,
        cycle_directions_consistent=consistent,
        seasonal_reversal=reversal,
        strong_trend_only_bic=(
            delta_bic is not None
            and delta_bic <= -SalesSeasonalityDiscoverer.STRONG_BIC_DELTA
        ),
        neutral_effect_ci_spans_zero=original_neutral[
            "effect_ci_spans_zero"
        ],
        neutral_oos_gain_not_significant=(
            result.oos_gain_ci_low is not None
            and result.oos_gain_ci_low <= 0
        ),
        no_significant_cycles=not significant,
        failed_original_direction_gates=tuple(
            name for name, passed in original_direction.items() if not passed
        ),
        failed_original_neutral_gates=tuple(
            name for name, passed in original_neutral.items() if not passed
        ),
    )


def apply_refinement(
    result: DiscoveryResult,
    policy: RefinementPolicy,
) -> RefinedResult:
    audit = audit_evidence(result)
    # Stage 2.7B is a refinement of abstentions, not a replacement classifier.
    # Evidence-backed assignments from the original conservative method remain
    # unchanged; only UNKNOWN results are eligible for reconsideration.
    if result.classification is not LearnedSeasonality.UNKNOWN:
        return RefinedResult(
            result.classification,
            result.evidence_strength,
            "preserved_original_evidence_gated_assignment",
            policy,
            audit,
        )
    if not audit.eligible_history:
        return RefinedResult(
            LearnedSeasonality.UNKNOWN,
            "insufficient",
            result.reason,
            policy,
            audit,
        )
    if audit.seasonal_reversal:
        return RefinedResult(
            LearnedSeasonality.UNKNOWN,
            "conflicting",
            "seasonal_reversal_across_annual_blocks",
            policy,
            audit,
        )

    require_cycles = policy is RefinementPolicy.DROP_BOOTSTRAP_SIGNIFICANCE
    require_bootstrap = policy is RefinementPolicy.DROP_CYCLE_SIGNIFICANCE
    direction_supported = (
        audit.bic_direction_pass
        and audit.effect_ci_excludes_zero
        and audit.positive_oos_point_gain
        and (not require_cycles or audit.cycle_directions_consistent)
        and (
            not require_bootstrap
            or audit.positive_oos_bootstrap_interval
        )
    )
    if direction_supported:
        classification = (
            LearnedSeasonality.SUMMER
            if result.dry_minus_rainy_daily_effect is not None
            and result.dry_minus_rainy_daily_effect > 0
            else LearnedSeasonality.RAINY
        )
        return RefinedResult(
            classification,
            "moderate_repeated_oos",
            f"direction_supported_by_{policy.value}",
            policy,
            audit,
        )

    # NEUTRAL confidence is separate from direction confidence. Strong BIC
    # evidence for the trend-only model replaces sensitivity to a tiny positive
    # point estimate whose bootstrap interval still includes zero.
    neutral_supported = (
        audit.strong_trend_only_bic
        and audit.neutral_effect_ci_spans_zero
        and audit.neutral_oos_gain_not_significant
        and audit.no_significant_cycles
    )
    if neutral_supported:
        return RefinedResult(
            LearnedSeasonality.NEUTRAL,
            "strong_nonseasonal",
            "strong_trend_only_bic_with_no_repeated_or_oos_seasonal_gain",
            policy,
            audit,
        )
    return RefinedResult(
        LearnedSeasonality.UNKNOWN,
        "inconclusive",
        "refined_evidence_gates_not_jointly_satisfied",
        policy,
        audit,
    )
