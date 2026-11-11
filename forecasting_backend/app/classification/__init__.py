"""Deterministic hardware product identification and seasonal relevance."""

from .engine import (
    ClassificationConfidence,
    ClassificationResult,
    HardwareProductClassifier,
    SeasonalEvidenceLevel,
    SeasonalMatchType,
    SeasonalRelevance,
)
from .semantic import HardwareTaxonomyMatcher, TextEncoder
from .gemini import (
    GeminiConfigurationError,
    GeminiHardwareClassifier,
    GeminiIdentificationProposal,
    GeminiRateLimitError,
    GeminiServiceError,
    GeminiTimeoutError,
)

__all__ = [
    "ClassificationConfidence",
    "ClassificationResult",
    "HardwareProductClassifier",
    "SeasonalEvidenceLevel",
    "SeasonalMatchType",
    "SeasonalRelevance",
    "HardwareTaxonomyMatcher",
    "TextEncoder",
    "GeminiConfigurationError",
    "GeminiHardwareClassifier",
    "GeminiIdentificationProposal",
    "GeminiRateLimitError",
    "GeminiServiceError",
    "GeminiTimeoutError",
]
