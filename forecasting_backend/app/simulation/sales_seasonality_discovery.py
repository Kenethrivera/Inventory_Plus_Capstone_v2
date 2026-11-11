from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from enum import Enum
from typing import Iterable, Sequence

import numpy as np
from scipy.stats import norm, ttest_ind

from app.seasonality import PhilippineSeason, PhilippineSeasonResolver


class LearnedSeasonality(str, Enum):
    SUMMER = "SUMMER"
    RAINY = "RAINY"
    NEUTRAL = "NEUTRAL"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class RegressionFit:
    coefficients: np.ndarray
    covariance: np.ndarray
    predictions: np.ndarray
    residuals: np.ndarray
    rss: float
    bic: float
    center_ordinal: float


@dataclass(frozen=True)
class DiscoveryResult:
    classification: LearnedSeasonality
    evidence_strength: str
    reason: str
    cutoff: date
    history_start: date | None
    history_days: int
    observed_days: int
    coverage_ratio: float
    positive_sales_days: int
    total_sales: float
    weekly_observations: int
    dry_minus_rainy_daily_effect: float | None
    effect_ci_low: float | None
    effect_ci_high: float | None
    effect_p_value: float | None
    delta_bic_seasonal_vs_trend: float | None
    oos_mae_trend: float | None
    oos_mae_seasonal: float | None
    oos_mae_gain: float | None
    oos_gain_ci_low: float | None
    oos_gain_ci_high: float | None
    cycle_directions: tuple[str, ...]
    stock_availability_known: bool
    label_used_during_discovery: bool = False

    def as_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["classification"] = self.classification.value
        value["cutoff"] = self.cutoff.isoformat()
        value["history_start"] = (
            self.history_start.isoformat() if self.history_start else None
        )
        value["cycle_directions"] = list(self.cycle_directions)
        return value


@dataclass(frozen=True)
class BaselineResult:
    classification: LearnedSeasonality
    reason: str
    p_value: float | None
    dry_minus_rainy_daily_effect: float | None


@dataclass(frozen=True)
class HoldoutConfirmation:
    classification: LearnedSeasonality
    dry_minus_rainy_daily_effect: float | None
    p_value: float | None
    direction_confirmed: bool | None
    reason: str


class SalesSeasonalityDiscoverer:
    """Discover annual sales patterns without product labels or taxonomy.

    The learner receives dates and quantities only. Its seasonal model adds one
    annual sine/cosine pair to a linear-trend regression. Evidence gates use
    conventional strong BIC evidence (delta >= 6), a 95% effect confidence
    interval, consistent significant directions across complete annual blocks,
    and a positive 95% moving-block-bootstrap interval for chronological
    out-of-sample MAE gain.
    """

    MIN_HISTORY_DAYS = 730
    MIN_COVERAGE_RATIO = 0.95
    MIN_POSITIVE_DAYS = 52
    STRONG_BIC_DELTA = 6.0
    CONFIDENCE_LEVEL = 0.95
    OOS_DAYS = 365
    BLOCK_BOOTSTRAP_SAMPLES = 1000
    BLOCK_BOOTSTRAP_WEEKS = 4

    def __init__(
        self,
        *,
        resolver: PhilippineSeasonResolver | None = None,
        location_id: str = "11111111-1111-1111-1111-111111111111",
    ) -> None:
        self._resolver = resolver or PhilippineSeasonResolver()
        self._location_id = location_id

    def discover(
        self,
        dates: Sequence[date],
        quantities: Sequence[float],
        *,
        cutoff: date,
    ) -> DiscoveryResult:
        clean_dates, clean_quantities = self._bounded_inputs(
            dates, quantities, cutoff=cutoff
        )
        if not clean_dates:
            return self._unknown(cutoff, reason="no_history")

        history_start = clean_dates[0]
        history_days = (cutoff - history_start).days + 1
        coverage = len(clean_dates) / history_days
        positive_days = int(np.count_nonzero(clean_quantities > 0))
        total_sales = float(clean_quantities.sum())
        common = {
            "cutoff": cutoff,
            "history_start": history_start,
            "history_days": history_days,
            "observed_days": len(clean_dates),
            "coverage_ratio": coverage,
            "positive_sales_days": positive_days,
            "total_sales": total_sales,
        }
        if history_days < self.MIN_HISTORY_DAYS:
            return self._unknown(
                reason="insufficient_history_fewer_than_two_annual_cycles",
                **common,
            )
        if coverage < self.MIN_COVERAGE_RATIO:
            return self._unknown(
                reason="incomplete_calendar_coverage",
                **common,
            )
        if total_sales <= 0:
            return self._unknown(reason="no_sales_history", **common)
        if positive_days < self.MIN_POSITIVE_DAYS:
            return self._unknown(
                reason="sparse_sales_insufficient_for_annual_inference",
                **common,
            )

        weekly_dates, weekly_values = self._weekly_means(
            clean_dates, clean_quantities
        )
        base_fit = self._fit(weekly_dates, weekly_values, seasonal=False)
        seasonal_fit = self._fit(
            weekly_dates, weekly_values, seasonal=True
        )
        delta_bic = base_fit.bic - seasonal_fit.bic
        effect, ci_low, ci_high, p_value = self._seasonal_contrast(
            seasonal_fit, weekly_dates
        )
        cycle_directions = self._cycle_directions(
            weekly_dates,
            base_fit.residuals,
            history_start=history_start,
            cutoff=cutoff,
        )
        oos = self._chronological_oos(weekly_dates, weekly_values, cutoff)

        significant_cycle_directions = tuple(
            value for value in cycle_directions if value != "INCONCLUSIVE"
        )
        reversal = (
            "SUMMER" in significant_cycle_directions
            and "RAINY" in significant_cycle_directions
        )
        consistent_cycles = (
            len(significant_cycle_directions) >= 2
            and len(set(significant_cycle_directions)) == 1
        )
        effect_significant = ci_low > 0 or ci_high < 0
        oos_supported = oos["gain_ci_low"] > 0
        seasonal_supported = (
            delta_bic >= self.STRONG_BIC_DELTA
            and effect_significant
            and consistent_cycles
            and oos_supported
            and not reversal
        )

        if seasonal_supported:
            classification = (
                LearnedSeasonality.SUMMER
                if effect > 0
                else LearnedSeasonality.RAINY
            )
            evidence_strength = "strong_repeated_oos"
            reason = "annual_effect_repeats_and_improves_chronological_holdout"
        else:
            no_significant_cycles = not significant_cycle_directions
            neutral_supported = (
                delta_bic <= 0
                and ci_low <= 0 <= ci_high
                and oos["gain"] <= 0
                and no_significant_cycles
            )
            if neutral_supported:
                classification = LearnedSeasonality.NEUTRAL
                evidence_strength = "adequate_nonseasonal"
                reason = "trend_only_model_preferred_with_no_repeated_annual_effect"
            else:
                classification = LearnedSeasonality.UNKNOWN
                evidence_strength = (
                    "conflicting" if reversal else "inconclusive"
                )
                reason = (
                    "seasonal_reversal_across_annual_blocks"
                    if reversal
                    else "evidence_gates_not_jointly_satisfied"
                )

        return DiscoveryResult(
            classification=classification,
            evidence_strength=evidence_strength,
            reason=reason,
            weekly_observations=len(weekly_dates),
            dry_minus_rainy_daily_effect=effect,
            effect_ci_low=ci_low,
            effect_ci_high=ci_high,
            effect_p_value=p_value,
            delta_bic_seasonal_vs_trend=delta_bic,
            oos_mae_trend=oos["base_mae"],
            oos_mae_seasonal=oos["seasonal_mae"],
            oos_mae_gain=oos["gain"],
            oos_gain_ci_low=oos["gain_ci_low"],
            oos_gain_ci_high=oos["gain_ci_high"],
            cycle_directions=cycle_directions,
            stock_availability_known=False,
            **common,
        )

    def simple_baseline(
        self,
        dates: Sequence[date],
        quantities: Sequence[float],
        *,
        cutoff: date,
    ) -> BaselineResult:
        clean_dates, clean_quantities = self._bounded_inputs(
            dates, quantities, cutoff=cutoff
        )
        if not clean_dates:
            return BaselineResult(
                LearnedSeasonality.UNKNOWN, "no_history", None, None
            )
        history_days = (cutoff - clean_dates[0]).days + 1
        if history_days < self.MIN_HISTORY_DAYS:
            return BaselineResult(
                LearnedSeasonality.UNKNOWN,
                "insufficient_history",
                None,
                None,
            )
        if float(clean_quantities.sum()) <= 0:
            return BaselineResult(
                LearnedSeasonality.UNKNOWN, "no_sales_history", None, None
            )
        weekly_dates, weekly_values = self._weekly_means(
            clean_dates, clean_quantities
        )
        dry, rainy = self._season_samples(weekly_dates, weekly_values)
        if len(dry) < 10 or len(rainy) < 10:
            return BaselineResult(
                LearnedSeasonality.UNKNOWN,
                "insufficient_core_season_weeks",
                None,
                None,
            )
        test = ttest_ind(dry, rainy, equal_var=False)
        effect = float(np.mean(dry) - np.mean(rainy))
        p_value = float(test.pvalue)
        if math.isfinite(p_value) and p_value < 0.05:
            classification = (
                LearnedSeasonality.SUMMER
                if effect > 0
                else LearnedSeasonality.RAINY
            )
            reason = "raw_core_season_means_differ_at_p_lt_0_05"
        else:
            classification = LearnedSeasonality.NEUTRAL
            reason = "raw_core_season_means_not_significantly_different"
        return BaselineResult(classification, reason, p_value, effect)

    def confirm_on_future_holdout(
        self,
        dates: Sequence[date],
        quantities: Sequence[float],
        *,
        training_cutoff: date,
        holdout_end: date,
        classification: LearnedSeasonality,
    ) -> HoldoutConfirmation:
        all_dates, all_quantities = self._bounded_inputs(
            dates, quantities, cutoff=holdout_end
        )
        train_pairs = [
            (value, quantity)
            for value, quantity in zip(all_dates, all_quantities)
            if value <= training_cutoff
        ]
        holdout_pairs = [
            (value, quantity)
            for value, quantity in zip(all_dates, all_quantities)
            if training_cutoff < value <= holdout_end
        ]
        if not train_pairs or not holdout_pairs:
            return HoldoutConfirmation(
                classification, None, None, None, "holdout_unavailable"
            )
        train_dates, train_values = self._weekly_means(
            [value for value, _ in train_pairs],
            np.asarray([quantity for _, quantity in train_pairs], dtype=float),
        )
        holdout_dates, holdout_values = self._weekly_means(
            [value for value, _ in holdout_pairs],
            np.asarray([quantity for _, quantity in holdout_pairs], dtype=float),
        )
        base_fit = self._fit(train_dates, train_values, seasonal=False)
        holdout_design = self._design(
            holdout_dates,
            seasonal=False,
            center_ordinal=base_fit.center_ordinal,
        )
        residuals = holdout_values - holdout_design @ base_fit.coefficients
        dry, rainy = self._season_samples(holdout_dates, residuals)
        if len(dry) < 10 or len(rainy) < 10:
            return HoldoutConfirmation(
                classification,
                None,
                None,
                None,
                "insufficient_core_season_holdout_weeks",
            )
        effect = float(np.mean(dry) - np.mean(rainy))
        test = ttest_ind(dry, rainy, equal_var=False)
        p_value = float(test.pvalue)
        if classification is LearnedSeasonality.SUMMER:
            confirmed = effect > 0 and p_value < 0.05
        elif classification is LearnedSeasonality.RAINY:
            confirmed = effect < 0 and p_value < 0.05
        else:
            confirmed = None
        return HoldoutConfirmation(
            classification,
            effect,
            p_value,
            confirmed,
            "future_year_direction_test",
        )

    def _unknown(
        self,
        cutoff: date,
        *,
        reason: str,
        history_start: date | None = None,
        history_days: int = 0,
        observed_days: int = 0,
        coverage_ratio: float = 0.0,
        positive_sales_days: int = 0,
        total_sales: float = 0.0,
    ) -> DiscoveryResult:
        return DiscoveryResult(
            classification=LearnedSeasonality.UNKNOWN,
            evidence_strength="insufficient",
            reason=reason,
            cutoff=cutoff,
            history_start=history_start,
            history_days=history_days,
            observed_days=observed_days,
            coverage_ratio=coverage_ratio,
            positive_sales_days=positive_sales_days,
            total_sales=total_sales,
            weekly_observations=0,
            dry_minus_rainy_daily_effect=None,
            effect_ci_low=None,
            effect_ci_high=None,
            effect_p_value=None,
            delta_bic_seasonal_vs_trend=None,
            oos_mae_trend=None,
            oos_mae_seasonal=None,
            oos_mae_gain=None,
            oos_gain_ci_low=None,
            oos_gain_ci_high=None,
            cycle_directions=(),
            stock_availability_known=False,
        )

    @staticmethod
    def _bounded_inputs(
        dates: Sequence[date],
        quantities: Sequence[float],
        *,
        cutoff: date,
    ) -> tuple[list[date], np.ndarray]:
        if len(dates) != len(quantities):
            raise ValueError("dates and quantities must have identical lengths")
        bounded: dict[date, float] = {}
        for business_date, raw_quantity in zip(dates, quantities):
            if business_date > cutoff:
                continue
            quantity = float(raw_quantity)
            if not math.isfinite(quantity) or quantity < 0:
                raise ValueError("sales quantities must be finite and nonnegative")
            if business_date in bounded:
                raise ValueError("sales history contains a duplicate date")
            bounded[business_date] = quantity
        ordered = sorted(bounded)
        return ordered, np.asarray([bounded[value] for value in ordered])

    @staticmethod
    def _weekly_means(
        dates: Sequence[date], quantities: np.ndarray
    ) -> tuple[list[date], np.ndarray]:
        if not dates:
            return [], np.asarray([], dtype=float)
        result_dates: list[date] = []
        result_values: list[float] = []
        start = dates[0]
        buckets: dict[int, list[float]] = {}
        bucket_dates: dict[int, list[date]] = {}
        for business_date, quantity in zip(dates, quantities):
            index = (business_date - start).days // 7
            buckets.setdefault(index, []).append(float(quantity))
            bucket_dates.setdefault(index, []).append(business_date)
        for index in sorted(buckets):
            values = buckets[index]
            days = bucket_dates[index]
            if len(values) < 7:
                continue
            result_dates.append(days[len(days) // 2])
            result_values.append(float(np.mean(values)))
        return result_dates, np.asarray(result_values, dtype=float)

    @staticmethod
    def _design(
        dates: Sequence[date],
        *,
        seasonal: bool,
        center_ordinal: float | None = None,
    ) -> np.ndarray:
        if not dates:
            return np.empty((0, 0))
        ordinal = np.asarray([value.toordinal() for value in dates], dtype=float)
        center = (
            float(np.mean(ordinal))
            if center_ordinal is None
            else center_ordinal
        )
        trend = (ordinal - center) / 365.25
        columns = [np.ones(len(dates)), trend]
        if seasonal:
            phase = 2.0 * math.pi * ordinal / 365.25
            columns.extend((np.sin(phase), np.cos(phase)))
        return np.column_stack(columns)

    def _fit(
        self,
        dates: Sequence[date],
        values: np.ndarray,
        *,
        seasonal: bool,
    ) -> RegressionFit:
        design = self._design(dates, seasonal=seasonal)
        coefficients, _, _, _ = np.linalg.lstsq(design, values, rcond=None)
        predictions = design @ coefficients
        residuals = values - predictions
        rss = max(float(np.dot(residuals, residuals)), 1e-12)
        n, parameters = design.shape
        bic = n * math.log(rss / n) + parameters * math.log(n)
        inverse = np.linalg.pinv(design.T @ design)
        hat = np.sum((design @ inverse) * design, axis=1)
        adjusted = residuals / np.maximum(1.0 - hat, 1e-6)
        meat = design.T @ ((adjusted**2)[:, None] * design)
        covariance = inverse @ meat @ inverse
        return RegressionFit(
            coefficients=coefficients,
            covariance=covariance,
            predictions=predictions,
            residuals=residuals,
            rss=rss,
            bic=bic,
            center_ordinal=float(
                np.mean([value.toordinal() for value in dates])
            ),
        )

    def _seasonal_contrast(
        self,
        fit: RegressionFit,
        dates: Sequence[date],
    ) -> tuple[float, float, float, float]:
        dry_dates = [
            value
            for value in dates
            if self._resolver.resolve(self._location_id, value).season
            is PhilippineSeason.DRY
        ]
        rainy_dates = [
            value
            for value in dates
            if self._resolver.resolve(self._location_id, value).season
            is PhilippineSeason.RAINY
        ]
        dry = self._design(dry_dates, seasonal=True)[:, 2:].mean(axis=0)
        rainy = self._design(rainy_dates, seasonal=True)[:, 2:].mean(axis=0)
        contrast = np.asarray([0.0, 0.0, *(dry - rainy)])
        effect = float(contrast @ fit.coefficients)
        variance = max(float(contrast @ fit.covariance @ contrast), 0.0)
        standard_error = math.sqrt(variance)
        critical = float(norm.ppf(0.5 + self.CONFIDENCE_LEVEL / 2.0))
        ci_low = effect - critical * standard_error
        ci_high = effect + critical * standard_error
        if standard_error <= 0:
            p_value = 0.0 if effect != 0 else 1.0
        else:
            p_value = float(2.0 * norm.sf(abs(effect / standard_error)))
        return effect, ci_low, ci_high, p_value

    def _cycle_directions(
        self,
        dates: Sequence[date],
        residuals: np.ndarray,
        *,
        history_start: date,
        cutoff: date,
    ) -> tuple[str, ...]:
        directions: list[str] = []
        cycle_start = history_start
        while cycle_start + timedelta(days=364) <= cutoff:
            cycle_end = cycle_start + timedelta(days=364)
            indices = [
                index
                for index, value in enumerate(dates)
                if cycle_start <= value <= cycle_end
            ]
            cycle_dates = [dates[index] for index in indices]
            cycle_values = residuals[indices]
            dry, rainy = self._season_samples(cycle_dates, cycle_values)
            if len(dry) < 10 or len(rainy) < 10:
                directions.append("INCONCLUSIVE")
            else:
                test = ttest_ind(dry, rainy, equal_var=False)
                difference = float(np.mean(dry) - np.mean(rainy))
                if math.isfinite(float(test.pvalue)) and test.pvalue < 0.05:
                    directions.append("SUMMER" if difference > 0 else "RAINY")
                else:
                    directions.append("INCONCLUSIVE")
            cycle_start = cycle_start + timedelta(days=365)
        return tuple(directions)

    def _chronological_oos(
        self,
        dates: Sequence[date],
        values: np.ndarray,
        cutoff: date,
    ) -> dict[str, float]:
        split = cutoff - timedelta(days=self.OOS_DAYS)
        train_indices = [index for index, value in enumerate(dates) if value <= split]
        test_indices = [index for index, value in enumerate(dates) if value > split]
        train_dates = [dates[index] for index in train_indices]
        test_dates = [dates[index] for index in test_indices]
        train_values = values[train_indices]
        test_values = values[test_indices]
        base = self._fit(train_dates, train_values, seasonal=False)
        seasonal = self._fit(train_dates, train_values, seasonal=True)
        base_predictions = self._design(
            test_dates,
            seasonal=False,
            center_ordinal=base.center_ordinal,
        ) @ base.coefficients
        seasonal_predictions = (
            self._design(
                test_dates,
                seasonal=True,
                center_ordinal=seasonal.center_ordinal,
            )
            @ seasonal.coefficients
        )
        base_losses = np.abs(test_values - base_predictions)
        seasonal_losses = np.abs(test_values - seasonal_predictions)
        gain_values = base_losses - seasonal_losses
        gain = float(np.mean(gain_values))
        low, high = self._moving_block_interval(gain_values)
        return {
            "base_mae": float(np.mean(base_losses)),
            "seasonal_mae": float(np.mean(seasonal_losses)),
            "gain": gain,
            "gain_ci_low": low,
            "gain_ci_high": high,
        }

    def _moving_block_interval(self, values: np.ndarray) -> tuple[float, float]:
        if len(values) == 0:
            return 0.0, 0.0
        rng = np.random.default_rng(2701)
        block = min(self.BLOCK_BOOTSTRAP_WEEKS, len(values))
        blocks_needed = math.ceil(len(values) / block)
        means = np.empty(self.BLOCK_BOOTSTRAP_SAMPLES)
        for sample in range(self.BLOCK_BOOTSTRAP_SAMPLES):
            selected: list[float] = []
            for _ in range(blocks_needed):
                start = int(rng.integers(0, len(values)))
                selected.extend(
                    float(values[(start + offset) % len(values)])
                    for offset in range(block)
                )
            means[sample] = float(np.mean(selected[: len(values)]))
        alpha = (1.0 - self.CONFIDENCE_LEVEL) / 2.0
        return (
            float(np.quantile(means, alpha)),
            float(np.quantile(means, 1.0 - alpha)),
        )

    def _season_samples(
        self,
        dates: Sequence[date],
        values: Iterable[float],
    ) -> tuple[np.ndarray, np.ndarray]:
        dry: list[float] = []
        rainy: list[float] = []
        for business_date, value in zip(dates, values):
            season = self._resolver.resolve(
                self._location_id, business_date
            ).season
            if season is PhilippineSeason.DRY:
                dry.append(float(value))
            elif season is PhilippineSeason.RAINY:
                rainy.append(float(value))
        return np.asarray(dry), np.asarray(rainy)


def confusion_matrix(
    actual: Sequence[str], predicted: Sequence[str]
) -> dict[str, dict[str, int]]:
    labels = tuple(value.value for value in LearnedSeasonality)
    matrix = {truth: {guess: 0 for guess in labels} for truth in labels[:-1]}
    for truth, guess in zip(actual, predicted):
        matrix[truth][guess] += 1
    return matrix


def classification_metrics(
    actual: Sequence[str], predicted: Sequence[str]
) -> dict[str, object]:
    matrix = confusion_matrix(actual, predicted)
    count = len(actual)
    correct = sum(truth == guess for truth, guess in zip(actual, predicted))
    assigned = sum(value != LearnedSeasonality.UNKNOWN.value for value in predicted)
    assigned_correct = sum(
        truth == guess
        for truth, guess in zip(actual, predicted)
        if guess != LearnedSeasonality.UNKNOWN.value
    )
    seasonal_predictions = sum(value in {"SUMMER", "RAINY"} for value in predicted)
    seasonal_correct = sum(
        truth == guess
        for truth, guess in zip(actual, predicted)
        if guess in {"SUMMER", "RAINY"}
    )
    per_group = {
        label: {
            "products": sum(value == label for value in actual),
            "correct": sum(
                truth == label and guess == label
                for truth, guess in zip(actual, predicted)
            ),
        }
        for label in ("SUMMER", "RAINY", "NEUTRAL")
    }
    return {
        "products": count,
        "correct": correct,
        "accuracy": correct / count if count else 0.0,
        "assigned_products": assigned,
        "coverage": assigned / count if count else 0.0,
        "covered_accuracy": assigned_correct / assigned if assigned else None,
        "unknown_products": count - assigned,
        "unknown_rate": (count - assigned) / count if count else 0.0,
        "seasonal_predictions": seasonal_predictions,
        "seasonal_precision": (
            seasonal_correct / seasonal_predictions
            if seasonal_predictions
            else None
        ),
        "false_seasonal_assignments": sum(
            truth == "NEUTRAL" and guess in {"SUMMER", "RAINY"}
            for truth, guess in zip(actual, predicted)
        ),
        "per_group": per_group,
        "confusion_matrix": matrix,
    }
