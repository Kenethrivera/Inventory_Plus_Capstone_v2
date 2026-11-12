from __future__ import annotations

import inspect
import math
import unittest
from datetime import date, timedelta

from app.simulation.sales_seasonality_discovery import (
    LearnedSeasonality,
    SalesSeasonalityDiscoverer,
)


START = date(2022, 1, 1)


def daily_dates(days: int) -> list[date]:
    return [START + timedelta(days=index) for index in range(days)]


def smooth_annual(
    dates: list[date], *, peak_day: int, amplitude: float = 5.0
) -> list[float]:
    return [
        10.0
        + amplitude
        * math.cos(
            2.0
            * math.pi
            * (business_date.timetuple().tm_yday - peak_day)
            / 365.25
        )
        + (index % 7) * 0.03
        for index, business_date in enumerate(dates)
    ]


class SalesSeasonalityDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.learner = SalesSeasonalityDiscoverer()

    def test_discovery_api_has_no_label_or_product_metadata_input(self) -> None:
        parameters = inspect.signature(self.learner.discover).parameters
        self.assertEqual(set(parameters), {"dates", "quantities", "cutoff"})

    def test_no_sales_product_is_unknown(self) -> None:
        dates = daily_dates(1095)
        result = self.learner.discover(
            dates, [0.0] * len(dates), cutoff=dates[-1]
        )
        self.assertEqual(result.classification, LearnedSeasonality.UNKNOWN)
        self.assertEqual(result.reason, "no_sales_history")

    def test_one_year_is_insufficient_even_with_strong_pattern(self) -> None:
        dates = daily_dates(365)
        result = self.learner.discover(
            dates,
            smooth_annual(dates, peak_day=100),
            cutoff=dates[-1],
        )
        self.assertEqual(result.classification, LearnedSeasonality.UNKNOWN)
        self.assertIn("fewer_than_two", result.reason)

    def test_stable_nonseasonal_trend_is_neutral(self) -> None:
        dates = daily_dates(1095)
        quantities = [
            5.0 + index * 0.003 + (index % 7) * 0.04
            for index in range(len(dates))
        ]
        result = self.learner.discover(
            dates, quantities, cutoff=dates[-1]
        )
        self.assertEqual(result.classification, LearnedSeasonality.NEUTRAL)
        self.assertEqual(result.evidence_strength, "adequate_nonseasonal")

    def test_repeated_summer_and_rainy_patterns_are_distinguished(self) -> None:
        dates = daily_dates(1095)
        summer = self.learner.discover(
            dates,
            smooth_annual(dates, peak_day=100),
            cutoff=dates[-1],
        )
        rainy = self.learner.discover(
            dates,
            smooth_annual(dates, peak_day=230),
            cutoff=dates[-1],
        )
        self.assertEqual(summer.classification, LearnedSeasonality.SUMMER)
        self.assertEqual(rainy.classification, LearnedSeasonality.RAINY)

    def test_seasonal_reversal_abstains(self) -> None:
        dates = daily_dates(1095)
        quantities: list[float] = []
        for index, business_date in enumerate(dates):
            cycle = index // 365
            peak = 100 if cycle != 1 else 230
            quantities.append(
                10.0
                + 6.0
                * math.cos(
                    2.0
                    * math.pi
                    * (business_date.timetuple().tm_yday - peak)
                    / 365.25
                )
            )
        result = self.learner.discover(
            dates, quantities, cutoff=dates[-1]
        )
        self.assertEqual(result.classification, LearnedSeasonality.UNKNOWN)
        self.assertEqual(result.reason, "seasonal_reversal_across_annual_blocks")

    def test_sparse_series_abstains_instead_of_forcing_direction(self) -> None:
        dates = daily_dates(1095)
        quantities = [
            1.0 if index % 31 == 0 else 0.0 for index in range(len(dates))
        ]
        result = self.learner.discover(
            dates, quantities, cutoff=dates[-1]
        )
        self.assertEqual(result.classification, LearnedSeasonality.UNKNOWN)
        self.assertIn("sparse_sales", result.reason)

    def test_future_values_cannot_change_past_classification(self) -> None:
        dates = daily_dates(1461)
        cutoff = dates[1094]
        prefix = smooth_annual(dates[:1095], peak_day=100)
        first = prefix + [0.0] * (len(dates) - len(prefix))
        second = prefix + [1000.0] * (len(dates) - len(prefix))
        first_result = self.learner.discover(dates, first, cutoff=cutoff)
        second_result = self.learner.discover(dates, second, cutoff=cutoff)
        self.assertEqual(first_result.as_dict(), second_result.as_dict())
        self.assertFalse(first_result.label_used_during_discovery)


if __name__ == "__main__":
    unittest.main()
