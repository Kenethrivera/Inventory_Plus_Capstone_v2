from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

import httpx
from dotenv import dotenv_values
from google import genai
from google.genai import errors, types
from pydantic import BaseModel, Field

from .engine import ClassificationConfidence, ClassificationResult, HardwareProductClassifier


DEFAULT_GEMINI_MODEL = "gemini-3.5-flash-lite"
GEMINI_METHOD = "gemini_ai_taxonomy_validated"


class GeminiConfigurationError(RuntimeError):
    pass


class GeminiRateLimitError(RuntimeError):
    pass


class GeminiTimeoutError(RuntimeError):
    pass


class GeminiServiceError(RuntimeError):
    pass


class GeminiIdentificationProposal(BaseModel):
    """Identification-only response. Seasonal claims are deliberately absent."""

    proposed_product_type: str = Field(max_length=100)
    intended_use: str = Field(max_length=500)
    suggested_taxonomy_category: str = Field(max_length=160)
    identification_confidence: Literal["high", "medium", "low", "unknown"]
    explanation: str = Field(max_length=800)
    clarification_needed: bool


@dataclass(frozen=True)
class GeminiClassificationSettings:
    api_key: str
    model: str = DEFAULT_GEMINI_MODEL
    timeout_milliseconds: int = 20_000

    @classmethod
    def from_environment(cls) -> GeminiClassificationSettings:
        key = os.getenv("GEMINI_CLASSIFICATION_KEY", "").strip()
        if not key:
            for path in _dotenv_candidates():
                if not path.is_file():
                    continue
                candidate = str(
                    dotenv_values(path).get("GEMINI_CLASSIFICATION_KEY") or ""
                ).strip()
                if candidate:
                    key = candidate
                    break
        if not key:
            raise GeminiConfigurationError(
                "GEMINI_CLASSIFICATION_KEY is not configured for the Python backend"
            )
        model = os.getenv("GEMINI_CLASSIFICATION_MODEL", DEFAULT_GEMINI_MODEL).strip()
        return cls(api_key=key, model=model or DEFAULT_GEMINI_MODEL)


def _dotenv_candidates() -> tuple[Path, ...]:
    repository_root = Path(__file__).resolve().parents[3]
    candidates = (
        Path.cwd() / ".env",
        Path.cwd() / "lib" / ".env",
        repository_root / "forecasting_backend" / ".env",
        repository_root / "lib" / ".env",
    )
    return tuple(dict.fromkeys(path.resolve() for path in candidates))


class GeminiIdentificationGateway(Protocol):
    @property
    def model_name(self) -> str: ...

    def identify(
        self,
        *,
        product_name: str,
        category: str,
        description: str,
        taxonomy: tuple[dict[str, object], ...],
    ) -> GeminiIdentificationProposal: ...


class GoogleGenAIGateway:
    """Small official-SDK boundary that never logs or returns its API key."""

    def __init__(self, settings: GeminiClassificationSettings) -> None:
        self._model_name = settings.model
        self._client = genai.Client(
            api_key=settings.api_key,
            http_options=types.HttpOptions(
                api_version="v1beta",
                timeout=settings.timeout_milliseconds,
                retry_options=types.HttpRetryOptions(
                    attempts=3,
                    initial_delay=0.8,
                    max_delay=4.0,
                    exp_base=2.0,
                    jitter=0.25,
                    http_status_codes=[408, 429, 500, 502, 503, 504],
                ),
            ),
        )

    @property
    def model_name(self) -> str:
        return self._model_name

    def identify(
        self,
        *,
        product_name: str,
        category: str,
        description: str,
        taxonomy: tuple[dict[str, object], ...],
    ) -> GeminiIdentificationProposal:
        taxonomy_prompt = [
            {
                "product_type": value["product_type"],
                "display_name": value["display_name"],
                "aliases": value["aliases"],
                "intended_use": value["intended_use"],
            }
            for value in taxonomy
        ]
        system_instruction = (
            "You identify retail hardware products. Choose exactly one "
            "proposed_product_type identifier from the supplied controlled taxonomy, "
            "or use 'unknown'. Never create a type. Use product name as primary "
            "evidence and category/description as context. A misleading category must "
            "not override a clear product name. For ambiguity, brand-only text, or "
            "insufficient product form/use, choose unknown and request clarification. "
            "Do not discuss seasons, sales demand, forecasts, percentages, evidence "
            "sources, or seasonal relevance. Keep the explanation concise."
        )
        contents = json.dumps(
            {
                "controlled_taxonomy": taxonomy_prompt,
                "product": {
                    "name": product_name,
                    "category": category or None,
                    "description": description or None,
                },
            },
            ensure_ascii=False,
        )
        try:
            response = self._client.models.generate_content(
                model=self._model_name,
                contents=contents,
                config=types.GenerateContentConfig(
                    system_instruction=system_instruction,
                    temperature=0,
                    seed=713,
                    max_output_tokens=500,
                    response_mime_type="application/json",
                    response_schema=GeminiIdentificationProposal,
                ),
            )
            if isinstance(response.parsed, GeminiIdentificationProposal):
                return response.parsed
            if response.parsed is not None:
                return GeminiIdentificationProposal.model_validate(response.parsed)
            if not response.text:
                raise GeminiServiceError(
                    "Gemini returned no structured classification result"
                )
            return GeminiIdentificationProposal.model_validate_json(response.text)
        except GeminiServiceError:
            raise
        except (httpx.TimeoutException, TimeoutError) as error:
            raise GeminiTimeoutError("Gemini classification timed out") from error
        except errors.APIError as error:
            if error.code == 429:
                raise GeminiRateLimitError(
                    "Gemini classification rate limit was reached; try again shortly"
                ) from error
            if error.code in {408, 504}:
                raise GeminiTimeoutError("Gemini classification timed out") from error
            raise GeminiServiceError(
                "Gemini classification is temporarily unavailable"
            ) from error
        except Exception as error:
            raise GeminiServiceError(
                "Gemini returned an invalid structured classification result"
            ) from error


class GeminiHardwareClassifier:
    """Gemini identification followed by strict local taxonomy/evidence validation."""

    def __init__(
        self,
        *,
        knowledge_classifier: HardwareProductClassifier,
        gateway: GeminiIdentificationGateway,
    ) -> None:
        self._knowledge_classifier = knowledge_classifier
        self._gateway = gateway
        self._taxonomy = knowledge_classifier.controlled_taxonomy
        self._taxa_by_id = {
            str(value["product_type"]): value for value in self._taxonomy
        }
        self.version = (
            f"gemini-validated-v1+{gateway.model_name}+"
            f"{knowledge_classifier.version}"
        )

    @classmethod
    def from_environment(
        cls, *, knowledge_classifier: HardwareProductClassifier
    ) -> GeminiHardwareClassifier:
        return cls(
            knowledge_classifier=knowledge_classifier,
            gateway=GoogleGenAIGateway(GeminiClassificationSettings.from_environment()),
        )

    def classify(
        self,
        *,
        product_name: str,
        category: str | None = None,
        description: str | None = None,
    ) -> ClassificationResult:
        name = product_name.strip()
        category_text = (category or "").strip()
        description_text = (description or "").strip()
        if not name:
            raise ValueError("product_name is required")
        if len(name) > 200 or len(category_text) > 120 or len(description_text) > 1000:
            raise ValueError("product classification input is too long")

        proposal = self._gateway.identify(
            product_name=name,
            category=category_text,
            description=description_text,
            taxonomy=self._taxonomy,
        )
        proposed_type = proposal.proposed_product_type.strip().casefold()
        if (
            proposal.clarification_needed
            or proposal.identification_confidence == "unknown"
            or proposed_type == "unknown"
        ):
            return self._knowledge_classifier.unknown_result(
                product_name=name,
                reason=_safe_identification_explanation(proposal.explanation),
                method=GEMINI_METHOD,
            )

        taxon = self._taxa_by_id.get(proposed_type)
        if taxon is None:
            return self._knowledge_classifier.unknown_result(
                product_name=name,
                reason=(
                    "Gemini proposed a label outside the controlled hardware "
                    "taxonomy, so the proposal was rejected."
                ),
                method=GEMINI_METHOD,
            )
        if not _local_context_is_sufficient(
            name=name,
            category=category_text,
            description=description_text,
            taxon=taxon,
        ):
            return self._knowledge_classifier.unknown_result(
                product_name=name,
                reason=(
                    "The proposed controlled type requires more material, form, or "
                    "intended-use context, so the Gemini proposal was rejected."
                ),
                method=GEMINI_METHOD,
            )

        confidence = ClassificationConfidence(proposal.identification_confidence)
        if confidence is ClassificationConfidence.HIGH and not _direct_name_support(
            name=name, taxon=taxon
        ):
            confidence = ClassificationConfidence.MEDIUM

        explanation = _safe_identification_explanation(proposal.explanation)
        return self._knowledge_classifier.result_from_validated_taxonomy_identity(
            product_name=name,
            product_type=proposed_type,
            confidence=confidence,
            identification_explanation=(
                f"Gemini identification: {explanation} The proposed identity was "
                "accepted only after controlled-taxonomy validation."
            ),
            method=GEMINI_METHOD,
        )


def _normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def _direct_name_support(*, name: str, taxon: dict[str, object]) -> bool:
    normalized_name = _normalize(name)
    candidates = (
        str(taxon["display_name"]),
        *(str(value) for value in taxon["aliases"]),
    )
    return any(
        normalized_name == _normalize(candidate)
        or (
            len(_normalize(candidate)) >= 5
            and re.search(
                rf"(?:^| ){re.escape(_normalize(candidate))}(?: |$)",
                normalized_name,
            )
            is not None
        )
        for candidate in candidates
    )


def _local_context_is_sufficient(
    *,
    name: str,
    category: str,
    description: str,
    taxon: dict[str, object],
) -> bool:
    required_context = tuple(
        str(value) for value in taxon.get("required_context_any", ())
    )
    required_name_or_description = tuple(
        str(value)
        for value in taxon.get("required_name_or_description_any", ())
    )
    combined = _normalize(f"{name} {category} {description}")
    name_or_description = _normalize(f"{name} {description}")
    if required_context and not any(
        _contains_normalized_phrase(combined, value) for value in required_context
    ):
        return False
    if required_name_or_description and not any(
        _contains_normalized_phrase(name_or_description, value)
        for value in required_name_or_description
    ):
        return False
    return True


def _contains_normalized_phrase(text: str, phrase: str) -> bool:
    normalized = _normalize(phrase)
    if not text or not normalized:
        return False
    if re.search(rf"(?:^| ){re.escape(normalized)}(?: |$)", text) is not None:
        return True
    if " " not in normalized:
        return any(token.rstrip("s") == normalized.rstrip("s") for token in text.split())
    return False


def _safe_identification_explanation(value: str) -> str:
    explanation = " ".join(value.strip().split())
    if not explanation:
        return "The supplied text did not provide a usable identification rationale."
    if re.search(r"\b(season|seasonal|demand|forecast|sales?)\b|%", explanation, re.I):
        return "The generated rationale contained out-of-scope claims and was discarded."
    return explanation[:600]
