from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Any

from .semantic import HardwareTaxonomyMatcher, TextEncoder


class ClassificationConfidence(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    UNKNOWN = "unknown"


class SeasonalRelevance(str, Enum):
    DRY = "dry"
    RAINY = "rainy"
    NEUTRAL = "neutral"
    UNKNOWN = "unknown"


class SeasonalEvidenceLevel(str, Enum):
    PROVISIONAL_GENERAL_MECHANISM = "provisional_general_mechanism"
    PROVISIONAL_DOMAIN_ASSUMPTION = "provisional_domain_assumption"
    PROVISIONAL_CONFLICTING_MECHANISMS = "provisional_conflicting_mechanisms"
    INHERITED_INDUSTRY_EVIDENCE = "inherited_industry_evidence"
    INSUFFICIENT = "insufficient"


class SeasonalMatchType(str, Enum):
    PRODUCT_SPECIFIC = "product_specific"
    INHERITED_INDUSTRY_ACTIVITY = "inherited_industry_activity"
    INSUFFICIENT = "insufficient"


@dataclass(frozen=True)
class EvidenceReference:
    title: str
    url: str
    scope: str


@dataclass(frozen=True)
class ClassificationResult:
    product_name: str
    identified_product_type: str
    suggested_taxonomy_category: str
    intended_use: str
    seasonal_relevance: SeasonalRelevance
    identification_confidence: ClassificationConfidence
    seasonal_evidence_level: SeasonalEvidenceLevel
    seasonal_match_type: SeasonalMatchType
    seasonal_hierarchy: tuple[str, ...]
    explanation: str
    evidence: tuple[EvidenceReference, ...]
    is_unknown: bool
    identification_method: str
    clarification_needed: bool

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["seasonal_relevance"] = self.seasonal_relevance.value
        value["identification_confidence"] = self.identification_confidence.value
        value["seasonal_evidence_level"] = self.seasonal_evidence_level.value
        value["seasonal_match_type"] = self.seasonal_match_type.value
        return value


@dataclass(frozen=True)
class _Rule:
    product_type: str
    label: str
    aliases: tuple[str, ...]
    category_hints: tuple[str, ...]
    intended_use: str
    seasonal_relevance: SeasonalRelevance
    evidence_level: SeasonalEvidenceLevel
    seasonal_explanation: str
    source_ids: tuple[str, ...]


@dataclass(frozen=True)
class _IndustryActivityGroup:
    activity_id: str
    label: str
    seasonal_relevance: SeasonalRelevance
    evidence_level: SeasonalEvidenceLevel
    seasonal_explanation: str
    source_ids: tuple[str, ...]


@dataclass(frozen=True)
class _IntendedUseGroup:
    use_id: str
    label: str
    activity_id: str
    explanation: str


@dataclass(frozen=True)
class _SeasonalResolution:
    relevance: SeasonalRelevance
    evidence_level: SeasonalEvidenceLevel
    match_type: SeasonalMatchType
    hierarchy: tuple[str, ...]
    explanation: str
    evidence: tuple[EvidenceReference, ...]


class HardwareProductClassifier:
    """Exact rules followed by closed-taxonomy semantic generalization."""

    def __init__(
        self,
        *,
        payload: dict[str, Any],
        taxonomy_matcher: HardwareTaxonomyMatcher,
    ) -> None:
        self.version = f'{payload["version"]}+{taxonomy_matcher.version}'
        self._taxonomy_matcher = taxonomy_matcher
        self._sources = {
            key: EvidenceReference(
                title=value["title"], url=value["url"], scope=value["scope"]
            )
            for key, value in payload["sources"].items()
        }
        self._rules = tuple(
            _Rule(
                product_type=value["product_type"],
                label=value["label"],
                aliases=tuple(value["aliases"]),
                category_hints=tuple(value["category_hints"]),
                intended_use=value["intended_use"],
                seasonal_relevance=SeasonalRelevance(value["seasonal_relevance"]),
                evidence_level=SeasonalEvidenceLevel(value["evidence_level"]),
                seasonal_explanation=value["seasonal_explanation"],
                source_ids=tuple(value["source_ids"]),
            )
            for value in payload["rules"]
        )
        self._rules_by_product_type = {
            rule.product_type: rule for rule in self._rules
        }
        self._taxa_by_product_type = {
            taxon.product_type: taxon for taxon in taxonomy_matcher.taxa
        }
        self._industry_activity_groups = {
            activity_id: _IndustryActivityGroup(
                activity_id=activity_id,
                label=value["label"],
                seasonal_relevance=SeasonalRelevance(
                    value["seasonal_relevance"]
                ),
                evidence_level=SeasonalEvidenceLevel(value["evidence_level"]),
                seasonal_explanation=value["seasonal_explanation"],
                source_ids=tuple(value["source_ids"]),
            )
            for activity_id, value in payload.get(
                "industry_activity_groups", {}
            ).items()
        }
        self._intended_use_groups = {
            use_id: _IntendedUseGroup(
                use_id=use_id,
                label=value["label"],
                activity_id=value["industry_activity_id"],
                explanation=value["explanation"],
            )
            for use_id, value in payload.get("intended_use_groups", {}).items()
        }
        self._product_group_links = dict(payload.get("product_group_links", {}))
        self._validate_hierarchy()
        self._unsupported_terms = tuple(payload["unsupported_terms"])

    @classmethod
    def load_default(
        cls,
        *,
        semantic_mode: str = "auto",
        encoder: TextEncoder | None = None,
    ) -> HardwareProductClassifier:
        path = Path(__file__).with_name("hardware_knowledge_base.json")
        return cls(
            payload=json.loads(path.read_text(encoding="utf-8")),
            taxonomy_matcher=HardwareTaxonomyMatcher.load_default(
                semantic_mode=semantic_mode,
                encoder=encoder,
            ),
        )

    def _validate_hierarchy(self) -> None:
        for use in self._intended_use_groups.values():
            if use.activity_id not in self._industry_activity_groups:
                raise ValueError(
                    f"intended-use group {use.use_id} references an unknown activity"
                )
        for product_type, use_id in self._product_group_links.items():
            if product_type not in self._taxa_by_product_type:
                raise ValueError(
                    f"seasonal hierarchy references unknown product type {product_type}"
                )
            if use_id not in self._intended_use_groups:
                raise ValueError(
                    f"product {product_type} references unknown intended-use group"
                )
        for activity in self._industry_activity_groups.values():
            for source_id in activity.source_ids:
                if source_id not in self._sources:
                    raise ValueError(
                        f"industry activity {activity.activity_id} references "
                        f"unknown source {source_id}"
                    )
            if (
                activity.seasonal_relevance is not SeasonalRelevance.UNKNOWN
                and not activity.source_ids
            ):
                raise ValueError(
                    f"directional industry activity {activity.activity_id} "
                    "requires documented sources"
                )

    def classify(
        self,
        *,
        product_name: str,
        category: str | None = None,
        description: str | None = None,
    ) -> ClassificationResult:
        name = _normalize(product_name)
        category_text = _normalize(category or "")
        description_text = _normalize(description or "")
        if not name:
            raise ValueError("product_name is required")
        if len(name) > 200 or len(category_text) > 120 or len(description_text) > 1000:
            raise ValueError("product classification input is too long")

        combined = " ".join(value for value in (name, category_text, description_text) if value)
        if any(_contains_phrase(combined, term) for term in self._unsupported_terms):
            return self._unknown(
                product_name,
                "The description indicates a non-hardware or unsupported product.",
            )

        scored: list[tuple[int, int, _Rule]] = []
        for index, rule in enumerate(self._rules):
            name_score = max((self._match_score(name, alias, 8, 6) for alias in rule.aliases), default=0)
            description_score = max((3 if _contains_phrase(description_text, alias) else 0 for alias in rule.aliases), default=0)
            category_score = max((2 if _contains_phrase(category_text, hint) else 0 for hint in rule.category_hints), default=0)
            # Product-name evidence dominates supporting description/category
            # evidence so a generic parent term cannot outrank a specific name.
            score = (name_score * 10) + description_score + category_score
            if score:
                scored.append((score, -index, rule))

        if not scored:
            return self._generalized(
                product_name=product_name,
                category=category or "",
                description=description or "",
            )
        scored.sort(reverse=True, key=lambda value: (value[0], value[1]))
        best_score, _, best = scored[0]
        if best_score < 60:
            return self._generalized(
                product_name=product_name,
                category=category or "",
                description=description or "",
            )
        if len(scored) > 1 and scored[1][0] == best_score and scored[1][2].product_type != best.product_type:
            return self._generalized(
                product_name=product_name,
                category=category or "",
                description=description or "",
            )

        category_conflict = bool(category_text) and not any(
            _contains_phrase(category_text, hint) for hint in best.category_hints
        ) and any(
            _contains_phrase(category_text, hint)
            for rule in self._rules
            if rule.product_type != best.product_type
            for hint in rule.category_hints
        )
        confidence = ClassificationConfidence.HIGH
        if category_conflict or (
            len(scored) > 1 and scored[1][0] >= best_score - 2
        ):
            confidence = ClassificationConfidence.MEDIUM

        seasonal = self._resolve_seasonality(
            product_type=best.product_type,
            product_label=best.label,
        )
        identification_note = f"Matched {best.label} from the product name"
        if description_text:
            identification_note += " and description"
        if category_conflict:
            identification_note += "; the supplied category conflicts with the stronger name/description match"
        explanation = (
            f"{identification_note}. {seasonal.explanation} "
            "Identification confidence describes the product match; it does not prove seasonal sales demand."
        )
        return ClassificationResult(
            product_name=product_name.strip(),
            identified_product_type=best.product_type,
            suggested_taxonomy_category=best.label,
            intended_use=best.intended_use,
            seasonal_relevance=seasonal.relevance,
            identification_confidence=confidence,
            seasonal_evidence_level=seasonal.evidence_level,
            seasonal_match_type=seasonal.match_type,
            seasonal_hierarchy=seasonal.hierarchy,
            explanation=explanation,
            evidence=seasonal.evidence,
            is_unknown=False,
            identification_method="deterministic_rule",
            clarification_needed=False,
        )

    def _generalized(
        self,
        *,
        product_name: str,
        category: str,
        description: str,
    ) -> ClassificationResult:
        match = self._taxonomy_matcher.match(
            product_name=product_name,
            category=category,
            description=description,
        )
        if match.taxon is None:
            return self._unknown(
                product_name,
                match.reason,
                method=match.method,
            )
        confidence = ClassificationConfidence(match.confidence)
        seasonal = self._resolve_seasonality(
            product_type=match.taxon.product_type,
            product_label=match.taxon.display_name,
        )
        return ClassificationResult(
            product_name=product_name.strip(),
            identified_product_type=match.taxon.product_type,
            suggested_taxonomy_category=match.taxon.display_name,
            intended_use=match.taxon.intended_use,
            seasonal_relevance=seasonal.relevance,
            identification_confidence=confidence,
            seasonal_evidence_level=seasonal.evidence_level,
            seasonal_match_type=seasonal.match_type,
            seasonal_hierarchy=seasonal.hierarchy,
            explanation=(
                f"{match.reason} This generalized product identification is "
                "limited to the supported taxonomy. "
                f"{seasonal.explanation}"
            ),
            evidence=seasonal.evidence,
            is_unknown=False,
            identification_method=match.method,
            clarification_needed=False,
        )

    @property
    def controlled_taxonomy(self) -> tuple[dict[str, object], ...]:
        """Return prompt-safe taxonomy metadata without seasonal assertions."""
        return tuple(
            {
                "product_type": taxon.product_type,
                "display_name": taxon.display_name,
                "aliases": taxon.aliases,
                "intended_use": taxon.intended_use,
                "required_context_any": taxon.required_context_any,
                "required_name_or_description_any": (
                    taxon.required_name_or_description_any
                ),
            }
            for taxon in self._taxonomy_matcher.taxa
        )

    def result_from_validated_taxonomy_identity(
        self,
        *,
        product_name: str,
        product_type: str,
        confidence: ClassificationConfidence,
        identification_explanation: str,
        method: str,
    ) -> ClassificationResult:
        """Attach only locally controlled taxonomy and seasonal knowledge."""
        taxon = self._taxa_by_product_type.get(product_type)
        if taxon is None:
            return self.unknown_result(
                product_name=product_name,
                reason="The proposed type is outside the controlled hardware taxonomy.",
                method=method,
            )

        seasonal = self._resolve_seasonality(
            product_type=product_type,
            product_label=taxon.display_name,
        )

        return ClassificationResult(
            product_name=product_name.strip(),
            identified_product_type=taxon.product_type,
            suggested_taxonomy_category=taxon.display_name,
            intended_use=taxon.intended_use,
            seasonal_relevance=seasonal.relevance,
            identification_confidence=confidence,
            seasonal_evidence_level=seasonal.evidence_level,
            seasonal_match_type=seasonal.match_type,
            seasonal_hierarchy=seasonal.hierarchy,
            explanation=(
                f"{identification_explanation.strip()} {seasonal.explanation} "
                "Product identification and seasonal-demand evidence are independent; "
                "no generated seasonal percentage or source is accepted."
            ),
            evidence=seasonal.evidence,
            is_unknown=False,
            identification_method=method,
            clarification_needed=False,
        )

    def _resolve_seasonality(
        self,
        *,
        product_type: str,
        product_label: str,
    ) -> _SeasonalResolution:
        """Resolve fresh knowledge on every request; no result is persisted."""
        rule = self._rules_by_product_type.get(product_type)
        if rule is not None and rule.evidence_level is not SeasonalEvidenceLevel.INSUFFICIENT:
            return _SeasonalResolution(
                relevance=rule.seasonal_relevance,
                evidence_level=rule.evidence_level,
                match_type=SeasonalMatchType.PRODUCT_SPECIFIC,
                hierarchy=(
                    product_label,
                    "Product-specific seasonal relationship",
                    _relevance_label(rule.seasonal_relevance),
                ),
                explanation=(
                    f"Product-specific seasonal relationship: "
                    f"{rule.seasonal_explanation}"
                ),
                evidence=tuple(
                    self._sources[source_id] for source_id in rule.source_ids
                ),
            )

        use_id = self._product_group_links.get(product_type)
        use = self._intended_use_groups.get(use_id) if use_id else None
        activity = (
            self._industry_activity_groups.get(use.activity_id)
            if use is not None
            else None
        )
        if (
            use is not None
            and activity is not None
            and activity.seasonal_relevance is not SeasonalRelevance.UNKNOWN
            and activity.source_ids
        ):
            return _SeasonalResolution(
                relevance=activity.seasonal_relevance,
                evidence_level=activity.evidence_level,
                match_type=SeasonalMatchType.INHERITED_INDUSTRY_ACTIVITY,
                hierarchy=(
                    product_label,
                    use.label,
                    activity.label,
                    _relevance_label(activity.seasonal_relevance),
                ),
                explanation=(
                    f"Inherited industry relationship: {use.explanation} "
                    f"{activity.seasonal_explanation}"
                ),
                evidence=tuple(
                    self._sources[source_id]
                    for source_id in activity.source_ids
                ),
            )

        if rule is not None:
            return _SeasonalResolution(
                relevance=rule.seasonal_relevance,
                evidence_level=rule.evidence_level,
                match_type=SeasonalMatchType.INSUFFICIENT,
                hierarchy=(
                    product_label,
                    "No supported product-specific seasonal direction",
                    _relevance_label(rule.seasonal_relevance),
                ),
                explanation=rule.seasonal_explanation,
                evidence=tuple(
                    self._sources[source_id] for source_id in rule.source_ids
                ),
            )

        if use is not None and activity is not None:
            return _SeasonalResolution(
                relevance=SeasonalRelevance.UNKNOWN,
                evidence_level=SeasonalEvidenceLevel.INSUFFICIENT,
                match_type=SeasonalMatchType.INSUFFICIENT,
                hierarchy=(
                    product_label,
                    use.label,
                    activity.label,
                    "Seasonal relevance UNKNOWN",
                ),
                explanation=(
                    f"{use.explanation} {activity.seasonal_explanation}"
                ),
                evidence=(),
            )

        return _SeasonalResolution(
            relevance=SeasonalRelevance.UNKNOWN,
            evidence_level=SeasonalEvidenceLevel.INSUFFICIENT,
            match_type=SeasonalMatchType.INSUFFICIENT,
            hierarchy=(
                product_label,
                "No documented intended-use/activity relationship",
                "Seasonal relevance UNKNOWN",
            ),
            explanation=(
                "The seasonal knowledge base has no documented product-specific "
                "or inherited industry relationship for this controlled type, so "
                "seasonal relevance remains UNKNOWN."
            ),
            evidence=(),
        )

    def unknown_result(
        self,
        *,
        product_name: str,
        reason: str,
        method: str,
    ) -> ClassificationResult:
        return self._unknown(product_name, reason, method=method)

    @staticmethod
    def _match_score(text: str, alias: str, exact: int, contained: int) -> int:
        normalized_alias = _normalize(alias)
        if text == normalized_alias:
            return exact
        return contained if _contains_phrase(text, normalized_alias) else 0

    @staticmethod
    def _unknown(
        product_name: str,
        reason: str,
        *,
        method: str = "unknown",
    ) -> ClassificationResult:
        return ClassificationResult(
            product_name=product_name.strip(),
            identified_product_type="unknown",
            suggested_taxonomy_category="unknown",
            intended_use="Unknown — insufficient product information.",
            seasonal_relevance=SeasonalRelevance.UNKNOWN,
            identification_confidence=ClassificationConfidence.UNKNOWN,
            seasonal_evidence_level=SeasonalEvidenceLevel.INSUFFICIENT,
            seasonal_match_type=SeasonalMatchType.INSUFFICIENT,
            seasonal_hierarchy=(
                "Unknown product type",
                "Seasonal relevance UNKNOWN",
            ),
            explanation=(
                f"{reason} No seasonal direction is assigned when product identification or evidence is insufficient."
            ),
            evidence=(),
            is_unknown=True,
            identification_method=method,
            clarification_needed=True,
        )


def _normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def _contains_phrase(text: str, phrase: str) -> bool:
    normalized = _normalize(phrase)
    if not text or not normalized:
        return False
    return re.search(rf"(?:^| )({re.escape(normalized)})(?: |$)", text) is not None


def _relevance_label(relevance: SeasonalRelevance) -> str:
    if relevance is SeasonalRelevance.DRY:
        return "Potential dry-season relevance"
    if relevance is SeasonalRelevance.RAINY:
        return "Potential rainy-season relevance"
    if relevance is SeasonalRelevance.NEUTRAL:
        return "Neutral/no established seasonality"
    return "Seasonal relevance UNKNOWN"
