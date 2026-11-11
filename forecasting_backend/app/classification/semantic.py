from __future__ import annotations

import json
import os
import re
import threading
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Protocol, Sequence

import numpy as np


@dataclass(frozen=True)
class HardwareTaxon:
    product_type: str
    display_name: str
    aliases: tuple[str, ...]
    category_hints: tuple[str, ...]
    intended_use: str
    prototypes: tuple[str, ...]
    required_context_any: tuple[str, ...]
    required_name_or_description_any: tuple[str, ...]


@dataclass(frozen=True)
class TaxonomyMatch:
    taxon: HardwareTaxon | None
    confidence: str
    method: str
    score: float
    margin: float
    reason: str


class TextEncoder(Protocol):
    @property
    def model_name(self) -> str: ...

    def encode(self, texts: Sequence[str]) -> np.ndarray: ...


class FastEmbedTextEncoder:
    def __init__(self, model_name: str) -> None:
        from fastembed import TextEmbedding

        cache_dir = os.getenv("HARDWARE_CLASSIFIER_MODEL_CACHE", "").strip()
        kwargs: dict[str, object] = {"model_name": model_name}
        if cache_dir:
            kwargs["cache_dir"] = cache_dir
        self._model_name = model_name
        self._model = TextEmbedding(**kwargs)

    @property
    def model_name(self) -> str:
        return self._model_name

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        values = np.asarray(list(self._model.embed(list(texts))), dtype=np.float32)
        return _normalize_vectors(values)


class HardwareTaxonomyMatcher:
    """Closed-set semantic matcher with lexical typo support and abstention."""

    def __init__(
        self,
        *,
        payload: dict[str, object],
        semantic_mode: str = "auto",
        encoder: TextEncoder | None = None,
    ) -> None:
        if semantic_mode not in {"auto", "required", "disabled"}:
            raise ValueError("semantic_mode must be auto, required, or disabled")
        self.version = str(payload["version"])
        self.model_name = str(payload["embedding_model"])
        raw_types = payload["types"]
        if not isinstance(raw_types, list):
            raise ValueError("hardware taxonomy types must be a list")
        self.taxa = tuple(
            HardwareTaxon(
                product_type=str(value["product_type"]),
                display_name=str(value["display_name"]),
                aliases=tuple(str(item) for item in value.get("aliases", [])),
                category_hints=tuple(
                    str(item) for item in value.get("category_hints", [])
                ),
                intended_use=str(value["intended_use"]),
                prototypes=tuple(str(item) for item in value["prototypes"]),
                required_context_any=tuple(
                    str(item) for item in value.get("required_context_any", [])
                ),
                required_name_or_description_any=tuple(
                    str(item)
                    for item in value.get("required_name_or_description_any", [])
                ),
            )
            for value in raw_types
        )
        product_types = [taxon.product_type for taxon in self.taxa]
        if len(product_types) != len(set(product_types)):
            raise ValueError("hardware taxonomy product types must be unique")
        self._semantic_mode = semantic_mode
        self._encoder = encoder
        self._prototype_embeddings: np.ndarray | None = None
        self._prototype_taxon_indexes: tuple[int, ...] = ()
        self._lock = threading.Lock()
        self._semantic_failure: str | None = None

    @classmethod
    def load_default(
        cls,
        *,
        semantic_mode: str = "auto",
        encoder: TextEncoder | None = None,
    ) -> HardwareTaxonomyMatcher:
        path = Path(__file__).with_name("hardware_taxonomy.json")
        payload = json.loads(path.read_text(encoding="utf-8"))
        return cls(payload=payload, semantic_mode=semantic_mode, encoder=encoder)

    @property
    def semantic_available(self) -> bool:
        return self._encoder is not None and self._prototype_embeddings is not None

    @property
    def semantic_failure(self) -> str | None:
        return self._semantic_failure

    def match(
        self,
        *,
        product_name: str,
        category: str,
        description: str,
    ) -> TaxonomyMatch:
        name = _normalize(product_name)
        category_text = _normalize(category)
        description_text = _normalize(description)
        query = (
            f"hardware product {name}. category {category_text or 'unspecified'}. "
            f"description {description_text or 'not provided'}."
        )
        semantic_scores = self._semantic_scores(query)
        candidates: list[tuple[float, float, int, HardwareTaxon]] = []
        for index, taxon in enumerate(self.taxa):
            lexical = _lexical_score(
                name=name,
                category=category_text,
                description=description_text,
                taxon=taxon,
            )
            semantic = semantic_scores[index] if semantic_scores is not None else 0.0
            score = (
                (0.72 * semantic) + (0.28 * lexical)
                if semantic_scores is not None
                else lexical
            )
            candidates.append((score, lexical, index, taxon))
        candidates.sort(key=lambda value: (value[0], value[1], -value[2]), reverse=True)
        best_score, best_lexical, _, best = candidates[0]
        second_score = candidates[1][0] if len(candidates) > 1 else 0.0
        margin = best_score - second_score
        method = "semantic_taxonomy" if semantic_scores is not None else "lexical_taxonomy"

        if best.required_context_any and not _has_required_context(
            name=name,
            category=category_text,
            description=description_text,
            required=best.required_context_any,
        ):
            return TaxonomyMatch(
                taxon=None,
                confidence="unknown",
                method=method,
                score=best_score,
                margin=margin,
                reason=(
                    f"The closest controlled type was {best.display_name}, but the "
                    "required product-use context was missing."
                ),
            )
        if best.required_name_or_description_any and not _has_required_context(
            name=name,
            category="",
            description=description_text,
            required=best.required_name_or_description_any,
        ):
            return TaxonomyMatch(
                taxon=None,
                confidence="unknown",
                method=method,
                score=best_score,
                margin=margin,
                reason=(
                    f"The closest controlled type was {best.display_name}, but "
                    "the product name or description did not establish its use."
                ),
            )

        exact_taxonomy_name = any(
            name == _normalize(candidate)
            for candidate in (best.display_name, *best.aliases)
        )
        if (
            semantic_scores is None
            and len(name.split()) == 1
            and not exact_taxonomy_name
            and not best.required_context_any
        ):
            return TaxonomyMatch(
                taxon=None,
                confidence="unknown",
                method=method,
                score=best_score,
                margin=margin,
                reason=(
                    "A short approximate name without supporting category or use "
                    "context is not sufficient for product identification."
                ),
            )

        minimum_score = 0.47 if semantic_scores is not None else 0.66
        minimum_margin = 0.025 if best_lexical >= 0.72 else 0.045
        if best_score < minimum_score:
            return TaxonomyMatch(
                taxon=None,
                confidence="unknown",
                method=method,
                score=best_score,
                margin=margin,
                reason="No controlled hardware type was similar enough to identify reliably.",
            )
        if margin < minimum_margin:
            return TaxonomyMatch(
                taxon=None,
                confidence="unknown",
                method=method,
                score=best_score,
                margin=margin,
                reason=(
                    "The supplied information matched multiple controlled hardware "
                    "types too closely; add material, form, or intended-use details."
                ),
            )
        confidence = "medium" if best_score >= 0.56 or best_lexical >= 0.76 else "low"
        return TaxonomyMatch(
            taxon=best,
            confidence=confidence,
            method=method,
            score=best_score,
            margin=margin,
            reason=(
                f"Matched {best.display_name} within the controlled hardware taxonomy "
                f"using {'pretrained semantic and typo-tolerant lexical' if semantic_scores is not None else 'typo-tolerant lexical'} similarity."
            ),
        )

    def _semantic_scores(self, query: str) -> list[float] | None:
        if self._semantic_mode == "disabled":
            return None
        try:
            self._ensure_semantic_index()
            assert self._encoder is not None
            assert self._prototype_embeddings is not None
            query_vector = self._encoder.encode([query])[0]
            prototype_scores = self._prototype_embeddings @ query_vector
            taxon_scores = [-1.0] * len(self.taxa)
            for score, taxon_index in zip(
                prototype_scores.tolist(), self._prototype_taxon_indexes
            ):
                taxon_scores[taxon_index] = max(taxon_scores[taxon_index], float(score))
            return taxon_scores
        except Exception as error:
            self._semantic_failure = f"{type(error).__name__}: {error}"
            if self._semantic_mode == "required":
                raise RuntimeError(
                    "Pretrained hardware semantic matcher is unavailable"
                ) from error
            return None

    def _ensure_semantic_index(self) -> None:
        if self._prototype_embeddings is not None:
            return
        with self._lock:
            if self._prototype_embeddings is not None:
                return
            if self._encoder is None:
                self._encoder = FastEmbedTextEncoder(self.model_name)
            texts: list[str] = []
            indexes: list[int] = []
            for index, taxon in enumerate(self.taxa):
                base = (
                    f"hardware type {taxon.display_name}. use: {taxon.intended_use}. "
                    f"categories: {' '.join(taxon.category_hints)}."
                )
                texts.append(base)
                indexes.append(index)
                for prototype in taxon.prototypes:
                    texts.append(f"hardware product: {prototype}. type: {taxon.display_name}.")
                    indexes.append(index)
            self._prototype_embeddings = self._encoder.encode(texts)
            self._prototype_taxon_indexes = tuple(indexes)


def _normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def _normalize_vectors(values: np.ndarray) -> np.ndarray:
    if values.ndim != 2:
        raise ValueError("embedding encoder must return a two-dimensional array")
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return values / norms


def _character_ngrams(value: str, size: int = 3) -> set[str]:
    compact = f"  {_normalize(value)}  "
    if len(compact) <= size:
        return {compact}
    return {compact[index : index + size] for index in range(len(compact) - size + 1)}


def _text_similarity(left: str, right: str) -> float:
    left_normalized = _normalize(left)
    right_normalized = _normalize(right)
    if not left_normalized or not right_normalized:
        return 0.0
    sequence = SequenceMatcher(None, left_normalized, right_normalized).ratio()
    left_ngrams = _character_ngrams(left_normalized)
    right_ngrams = _character_ngrams(right_normalized)
    union = left_ngrams | right_ngrams
    jaccard = len(left_ngrams & right_ngrams) / len(union) if union else 0.0
    left_tokens = set(left_normalized.split())
    right_tokens = set(right_normalized.split())
    token_overlap = len(left_tokens & right_tokens) / max(
        1, min(len(left_tokens), len(right_tokens))
    )
    return max(sequence, (0.55 * sequence) + (0.30 * jaccard) + (0.15 * token_overlap))


def _lexical_score(
    *, name: str, category: str, description: str, taxon: HardwareTaxon
) -> float:
    names = (taxon.display_name, *taxon.aliases)
    name_score = max((_text_similarity(name, candidate) for candidate in names), default=0.0)
    category_score = max(
        (_text_similarity(category, hint) for hint in taxon.category_hints), default=0.0
    )
    description_score = max(
        (_text_similarity(description, prototype) for prototype in taxon.prototypes),
        default=0.0,
    )
    return min(1.0, (0.76 * name_score) + (0.16 * category_score) + (0.08 * description_score))


def _has_required_context(
    *, name: str, category: str, description: str, required: Sequence[str]
) -> bool:
    combined = f"{name} {category} {description}"
    return any(
        _normalize(value) in combined or _text_similarity(combined, value) >= 0.74
        for value in required
    )
