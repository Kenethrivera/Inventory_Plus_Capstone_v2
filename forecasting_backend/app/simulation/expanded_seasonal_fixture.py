from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.data import DailyDemand
from app.forecasting import (
    ForecastProduct,
    HistoricalDemandDataset,
    SharedProductContext,
    SharedProductContextRegistry,
)


ASSUMPTIONS_PATH = Path(__file__).with_name(
    "expanded_seasonal_assumptions.json"
)


@dataclass(frozen=True)
class ExpandedSeasonalProduct:
    index: int
    product_id: str
    sku: str
    product_name: str
    category: str
    description: str
    unit: str
    product_type: str
    intended_use_group: str
    seasonal_group: str
    baseline_daily: Decimal
    primary_amplitude: Decimal
    secondary_amplitude: Decimal
    trend_per_year: Decimal
    weekend_effect: Decimal
    intermittency_probability: Decimal
    quantity_step: Decimal
    price: Decimal
    opening_stock: Decimal
    evidence_level: str
    source_ids: tuple[str, ...]
    rationale: str

    @property
    def forecast_product(self) -> ForecastProduct:
        return ForecastProduct(
            location_id=LOCATION_ID,
            product_id=self.product_id,
            sku=self.sku,
            product_name=self.product_name,
            unit=self.unit,
        )

    @property
    def demand_pattern(self) -> str:
        if self.baseline_daily == 0:
            return "no_sales"
        if self.intermittency_probability < Decimal("0.5"):
            return "intermittent_low"
        if self.intermittency_probability < Decimal("0.8"):
            return "intermittent"
        return self.seasonal_group.casefold()


def _load_manifest() -> dict[str, Any]:
    manifest = json.loads(ASSUMPTIONS_PATH.read_text(encoding="utf-8"))
    if manifest["version"] != "expanded-ph-seasonal-simulation-v1":
        raise ValueError("unexpected expanded simulation manifest version")
    return manifest


MANIFEST = _load_manifest()
MANIFEST_VERSION = str(MANIFEST["version"])
SIMULATION_SEED = int(MANIFEST["seed"])
LOCATION_ID = str(MANIFEST["location_id"])
HISTORY_START = date.fromisoformat(MANIFEST["history_start"])
HISTORY_END = date.fromisoformat(MANIFEST["history_end"])
TRAINING_END = date.fromisoformat(MANIFEST["training_end"])
VALIDATION_START = date.fromisoformat(MANIFEST["validation_start"])
VALIDATION_END = date.fromisoformat(MANIFEST["validation_end"])
TEST_START = date.fromisoformat(MANIFEST["test_start"])
TEST_END = date.fromisoformat(MANIFEST["test_end"])
SUMMER_PEAK_DAY = int(MANIFEST["generator"]["summer_peak_day_of_year"])
RAINY_PEAK_DAY = int(MANIFEST["generator"]["rainy_peak_day_of_year"])


def _product(row: dict[str, Any]) -> ExpandedSeasonalProduct:
    return ExpandedSeasonalProduct(
        index=int(row["index"]),
        product_id=str(row["product_id"]),
        sku=str(row["sku"]),
        product_name=str(row["name"]),
        category=str(row["category"]),
        description=str(row["description"]),
        unit=str(row["unit"]),
        product_type=str(row["product_type"]),
        intended_use_group=str(row["intended_use_group"]),
        seasonal_group=str(row["seasonal_group"]),
        baseline_daily=Decimal(str(row["baseline_daily"])),
        primary_amplitude=Decimal(str(row["primary_amplitude"])),
        secondary_amplitude=Decimal(str(row["secondary_amplitude"])),
        trend_per_year=Decimal(str(row["trend_per_year"])),
        weekend_effect=Decimal(str(row["weekend_effect"])),
        intermittency_probability=Decimal(
            str(row["intermittency_probability"])
        ),
        quantity_step=Decimal(str(row["quantity_step"])),
        price=Decimal(str(row["price"])),
        opening_stock=Decimal(str(row["opening_stock"])),
        evidence_level=str(row["evidence_level"]),
        source_ids=tuple(str(value) for value in row["source_ids"]),
        rationale=str(row["rationale"]),
    )


PRODUCTS = tuple(_product(value) for value in MANIFEST["products"])


def _validate_manifest() -> None:
    if (HISTORY_END - HISTORY_START).days + 1 != 1461:
        raise ValueError("expanded simulation must contain exactly four years")
    if TRAINING_END + timedelta(days=1) != VALIDATION_START:
        raise ValueError("training and validation boundaries are not contiguous")
    if VALIDATION_END + timedelta(days=1) != TEST_START:
        raise ValueError("validation and test boundaries are not contiguous")
    if TEST_END != HISTORY_END:
        raise ValueError("test period must end with the fixture")
    if len(PRODUCTS) != 24:
        raise ValueError("expanded simulation must contain 24 products")
    if len({value.product_id for value in PRODUCTS}) != len(PRODUCTS):
        raise ValueError("expanded simulation contains duplicate product IDs")
    if len({value.sku for value in PRODUCTS}) != len(PRODUCTS):
        raise ValueError("expanded simulation contains duplicate SKUs")
    group_counts: dict[str, int] = {}
    for product in PRODUCTS:
        group_counts[product.seasonal_group] = (
            group_counts.get(product.seasonal_group, 0) + 1
        )
        if product.quantity_step <= 0 or product.opening_stock < 0:
            raise ValueError(f"invalid quantity policy for {product.sku}")
        if not Decimal("0") <= product.intermittency_probability <= Decimal("1"):
            raise ValueError(f"invalid intermittency policy for {product.sku}")
    if group_counts != {"SUMMER": 8, "RAINY": 8, "NEUTRAL": 8}:
        raise ValueError("expanded simulation groups must each contain 8 products")


_validate_manifest()


def assumptions_sha256() -> str:
    return hashlib.sha256(ASSUMPTIONS_PATH.read_bytes()).hexdigest()


def deterministic_uniform(
    product: ExpandedSeasonalProduct,
    business_date: date,
    stream: str,
) -> float:
    digest = hashlib.md5(
        (
            f"{SIMULATION_SEED}|{product.sku}|"
            f"{business_date.isoformat()}|{stream}"
        ).encode("utf-8"),
        usedforsecurity=False,
    ).hexdigest()
    return int(digest[:13], 16) / float(16**13)


def season_curve(business_date: date, peak_day: int) -> float:
    day_of_year = business_date.timetuple().tm_yday
    return (
        1.0
        + math.cos(2.0 * math.pi * (day_of_year - peak_day) / 365.25)
    ) / 2.0


def simulated_quantity(
    product: ExpandedSeasonalProduct,
    business_date: date,
) -> Decimal:
    """Frozen deterministic generator; hidden amplitudes never reach models."""

    if not HISTORY_START <= business_date <= HISTORY_END:
        raise ValueError("business_date is outside the expanded fixture")
    if product.baseline_daily == 0:
        return Decimal("0")
    if deterministic_uniform(product, business_date, "gate") > float(
        product.intermittency_probability
    ):
        return Decimal("0")

    summer = season_curve(business_date, SUMMER_PEAK_DAY)
    rainy = season_curve(business_date, RAINY_PEAK_DAY)
    if product.seasonal_group == "SUMMER":
        primary, secondary = summer, rainy
    elif product.seasonal_group == "RAINY":
        primary, secondary = rainy, summer
    else:
        primary, secondary = summer, rainy

    year_index = (business_date - HISTORY_START).days / 365.25
    trend_factor = max(
        0.60,
        1.0 + float(product.trend_per_year) * year_index,
    )
    annual_strength = 0.88 + 0.24 * deterministic_uniform(
        product, date(business_date.year, 1, 1), "annual_strength"
    )
    seasonal_factor = max(
        0.20,
        1.0
        + annual_strength
        * float(product.primary_amplitude)
        * (2.0 * primary - 1.0)
        + float(product.secondary_amplitude) * (2.0 * secondary - 1.0),
    )
    weekday_factor = (
        1.0 + float(product.weekend_effect)
        if business_date.weekday() >= 5
        else 1.0
    )
    week_start = business_date - timedelta(days=business_date.weekday())
    weekly_noise = (
        deterministic_uniform(product, week_start, "weekly") - 0.5
    ) * 0.30
    mean = (
        float(product.baseline_daily)
        * trend_factor
        * seasonal_factor
        * weekday_factor
        * (1.0 + weekly_noise)
    )
    daily_centered = sum(
        deterministic_uniform(product, business_date, f"daily_{index}")
        for index in range(3)
    ) - 1.5
    noisy = mean + daily_centered * 1.15 * math.sqrt(max(mean, 0.1))
    if deterministic_uniform(product, business_date, "shock") < 0.018:
        noisy += mean * (
            0.25
            + 0.75
            * deterministic_uniform(product, business_date, "shock_size")
        )
    step = float(product.quantity_step)
    rounded = max(0.0, math.floor(max(noisy, 0.0) / step + 0.5) * step)
    return Decimal(format(rounded, ".12g"))


def expanded_datasets() -> tuple[HistoricalDemandDataset, ...]:
    datasets: list[HistoricalDemandDataset] = []
    for product in PRODUCTS:
        observations: list[DailyDemand] = []
        current = HISTORY_START
        while current <= HISTORY_END:
            quantity = simulated_quantity(product, current)
            if quantity > 0:
                observations.append(
                    DailyDemand(
                        business_date=current,
                        location_id=LOCATION_ID,
                        product_id=product.product_id,
                        sku=product.sku,
                        product_name=product.product_name,
                        unit=product.unit,
                        quantity=quantity,
                        completed_order_count=1,
                    )
                )
            current += timedelta(days=1)
        datasets.append(
            HistoricalDemandDataset.from_synthetic_observations(
                product=product.forecast_product,
                history_start=HISTORY_START,
                history_end=HISTORY_END,
                observations=observations,
            )
        )
    return tuple(datasets)


def bounded_dataset(
    dataset: HistoricalDemandDataset,
    origin: date,
    *,
    max_history_days: int | None,
) -> HistoricalDemandDataset:
    if dataset.history_start is None or not dataset.history_start <= origin:
        raise ValueError("origin precedes expanded history")
    history_start = dataset.history_start
    if max_history_days is not None:
        if max_history_days <= 0:
            raise ValueError("max_history_days must be positive")
        history_start = max(
            history_start,
            origin - timedelta(days=max_history_days - 1),
        )
    return HistoricalDemandDataset.from_synthetic_observations(
        product=dataset.product,
        history_start=history_start,
        history_end=origin,
        observations=(
            value
            for value in dataset.observations
            if history_start <= value.business_date <= origin
        ),
    )


def shared_context_registry() -> SharedProductContextRegistry:
    contexts = tuple(
        SharedProductContext(
            product_id=product.product_id,
            sku=product.sku,
            product_name=product.product_name,
            category=product.category.casefold(),
            unit=product.unit.casefold(),
            product_type=product.product_type,
            intended_use_group=product.intended_use_group,
            industry_activity_group=(
                "outdoor_weather_exposed_construction"
                if product.seasonal_group == "SUMMER"
                else "weather_response_and_water_management"
                if product.seasonal_group == "RAINY"
                else "mixed_indoor_outdoor_maintenance"
            ),
            seasonal_relevance=product.seasonal_group.casefold(),
            seasonal_match_type="frozen_simulation_hypothesis",
            evidence_level=product.evidence_level,
            classification_confidence="manifest_reviewed",
        )
        for product in PRODUCTS
    )
    return SharedProductContextRegistry(
        contexts=contexts,
        version=f"{MANIFEST_VERSION}:{assumptions_sha256()[:12]}",
    )
