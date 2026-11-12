from __future__ import annotations

import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Protocol
from uuid import UUID


class SeasonalCatalogProduct(Protocol):
    product_id: str
    sku: str | None
    product_name: str


class EvidenceLevel(str, Enum):
    CORROBORATED_GENERAL_MECHANISM = "corroborated_general_mechanism"
    PROVISIONAL_DOMAIN_HYPOTHESIS = "provisional_domain_hypothesis"
    UNKNOWN = "unknown"


class SeasonalRelevance(str, Enum):
    CONSTRUCTION_ACTIVITY = "construction_activity"
    PLUMBING_INSTALLATION_AND_REPAIR = "plumbing_installation_and_repair"
    MIXED_PROJECT_ACTIVITY = "mixed_project_activity"
    UNCLASSIFIED_TEST_ITEM = "unclassified_test_item"


@dataclass(frozen=True)
class EvidenceSource:
    source_id: str
    title: str
    url: str
    supports: str
    limitation: str


@dataclass(frozen=True)
class ProductSeasonalProfile:
    product_id: str
    sku: str
    product_name: str
    seasonal_relevance: SeasonalRelevance
    evidence_level: EvidenceLevel
    rationale: str
    seasonal_guidance: str
    source_ids: tuple[str, ...]
    numerical_adjustment_allowed: bool

    def feature_vector(self, context_features: tuple[float, ...]) -> tuple[float, ...]:
        """Return classification/context interactions, never fixed demand effects."""

        construction = float(
            self.seasonal_relevance is SeasonalRelevance.CONSTRUCTION_ACTIVITY
        )
        plumbing = float(
            self.seasonal_relevance
            is SeasonalRelevance.PLUMBING_INSTALLATION_AND_REPAIR
        )
        mixed = float(
            self.seasonal_relevance is SeasonalRelevance.MIXED_PROJECT_ACTIVITY
        )
        known = float(
            self.seasonal_relevance is not SeasonalRelevance.UNCLASSIFIED_TEST_ITEM
        )
        dry, rainy, to_rainy, to_dry, type_i = context_features
        return (
            dry,
            rainy,
            to_rainy,
            to_dry,
            type_i,
            construction,
            plumbing,
            mixed,
            known,
            construction * rainy,
            construction * to_rainy,
            construction * to_dry,
            plumbing * rainy,
            plumbing * to_rainy,
            plumbing * to_dry,
            mixed * rainy,
            mixed * to_rainy,
            mixed * to_dry,
        )


class ProductSeasonalProfileRegistry:
    """Auditable, non-numeric seasonal classifications for the current catalog."""

    REGISTRY_VERSION = "inventory-plus-binan-catalog-v1"

    def __init__(
        self,
        *,
        profiles: tuple[ProductSeasonalProfile, ...],
        sources: tuple[EvidenceSource, ...],
    ) -> None:
        self._profiles_by_id = {value.product_id: value for value in profiles}
        self._profiles_by_sku = {value.sku: value for value in profiles}
        self._sources = {value.source_id: value for value in sources}
        if len(self._profiles_by_id) != len(profiles):
            raise ValueError("seasonal profiles contain a duplicate product_id")
        if len(self._profiles_by_sku) != len(profiles):
            raise ValueError("seasonal profiles contain a duplicate SKU")
        for profile in profiles:
            UUID(profile.product_id)
            if profile.numerical_adjustment_allowed:
                raise ValueError(
                    "provisional registry must not authorize numerical adjustments"
                )
            missing = set(profile.source_ids) - self._sources.keys()
            if missing:
                raise ValueError(
                    f"profile {profile.sku} references unknown sources: {sorted(missing)}"
                )

    @classmethod
    def load_default(cls) -> ProductSeasonalProfileRegistry:
        path = Path(__file__).with_name("product_profiles.json")
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("registry_version") != cls.REGISTRY_VERSION:
            raise ValueError("seasonal profile registry version is unsupported")
        sources = tuple(
            EvidenceSource(
                source_id=value["source_id"],
                title=value["title"],
                url=value["url"],
                supports=value["supports"],
                limitation=value["limitation"],
            )
            for value in payload["sources"]
        )
        profiles = tuple(cls._parse_profile(value) for value in payload["profiles"])
        return cls(profiles=profiles, sources=sources)

    @staticmethod
    def _parse_profile(value: dict[str, Any]) -> ProductSeasonalProfile:
        prohibited = {"multiplier", "uplift", "downlift", "seasonal_factor"}
        if prohibited.intersection(value):
            raise ValueError("seasonal profiles must not contain numerical effects")
        return ProductSeasonalProfile(
            product_id=value["product_id"],
            sku=value["sku"],
            product_name=value["product_name"],
            seasonal_relevance=SeasonalRelevance(value["seasonal_relevance"]),
            evidence_level=EvidenceLevel(value["evidence_level"]),
            rationale=value["rationale"],
            seasonal_guidance=value["seasonal_guidance"],
            source_ids=tuple(value["source_ids"]),
            numerical_adjustment_allowed=bool(
                value["numerical_adjustment_allowed"]
            ),
        )

    @property
    def profiles(self) -> tuple[ProductSeasonalProfile, ...]:
        return tuple(
            sorted(self._profiles_by_id.values(), key=lambda value: value.sku)
        )

    @property
    def sources(self) -> tuple[EvidenceSource, ...]:
        return tuple(sorted(self._sources.values(), key=lambda value: value.source_id))

    def require(self, product: SeasonalCatalogProduct) -> ProductSeasonalProfile:
        profile = self._profiles_by_id.get(product.product_id)
        if profile is None:
            raise ValueError(
                f"no seasonal evidence profile exists for product {product.product_id}"
            )
        if product.sku and profile.sku != product.sku:
            raise ValueError(
                f"seasonal profile/catalog SKU mismatch for {product.product_id}"
            )
        if profile.product_name.casefold() != product.product_name.casefold():
            raise ValueError(
                f"seasonal profile/catalog name mismatch for {product.product_id}"
            )
        return profile

    def validate_catalog(self, products: tuple[SeasonalCatalogProduct, ...]) -> None:
        if len(products) != len(self._profiles_by_id):
            raise ValueError("seasonal registry does not cover the complete active catalog")
        seen = {self.require(product).product_id for product in products}
        if seen != self._profiles_by_id.keys():
            raise ValueError("seasonal registry and active catalog product IDs differ")
