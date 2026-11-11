from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app.classification import (
    GeminiHardwareClassifier,
    GeminiIdentificationProposal,
    HardwareProductClassifier,
)
from app.classification.gemini import GeminiClassificationSettings


class FakeGeminiGateway:
    model_name = "fake-gemini-flash"

    def __init__(self, proposal: GeminiIdentificationProposal) -> None:
        self.proposal = proposal
        self.calls = 0

    def identify(self, **kwargs) -> GeminiIdentificationProposal:
        self.calls += 1
        self.last_request = kwargs
        return self.proposal


def proposal(
    product_type: str,
    *,
    confidence: str = "high",
    explanation: str = "The name and stated use identify this hardware product.",
    clarification_needed: bool = False,
) -> GeminiIdentificationProposal:
    return GeminiIdentificationProposal(
        proposed_product_type=product_type,
        intended_use="Generated intended use is not trusted as canonical.",
        suggested_taxonomy_category="Generated category",
        identification_confidence=confidence,
        explanation=explanation,
        clarification_needed=clarification_needed,
    )


class GeminiHardwareClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.knowledge = HardwareProductClassifier.load_default(
            semantic_mode="disabled"
        )

    def classifier(self, value: GeminiIdentificationProposal):
        gateway = FakeGeminiGateway(value)
        return (
            GeminiHardwareClassifier(
                knowledge_classifier=self.knowledge,
                gateway=gateway,
            ),
            gateway,
        )

    def test_accepts_only_controlled_taxonomy_and_canonical_intended_use(self) -> None:
        classifier, gateway = self.classifier(proposal("chainsaw"))
        result = classifier.classify(product_name="Chainsaw", category="Power Tools")

        self.assertEqual(result.identified_product_type, "chainsaw")
        self.assertEqual(result.suggested_taxonomy_category, "Chainsaw")
        self.assertIn("powered chain", result.intended_use)
        self.assertNotIn("Generated intended use", result.intended_use)
        self.assertEqual(result.identification_confidence.value, "high")
        self.assertEqual(result.seasonal_relevance.value, "unknown")
        self.assertEqual(result.seasonal_evidence_level.value, "insufficient")
        self.assertEqual(result.identification_method, "gemini_ai_taxonomy_validated")
        self.assertEqual(gateway.calls, 1)

    def test_supports_poultry_netting_without_inventing_seasonality(self) -> None:
        classifier, _ = self.classifier(proposal("poultry_netting"))
        result = classifier.classify(
            product_name="Chicken wire", description="Hex mesh roll for a coop"
        )
        self.assertEqual(result.identified_product_type, "poultry_netting")
        self.assertEqual(result.seasonal_relevance.value, "unknown")
        self.assertEqual(result.evidence, ())

    def test_locally_attaches_existing_seasonal_evidence(self) -> None:
        classifier, _ = self.classifier(proposal("roofing_sheet"))
        result = classifier.classify(product_name="Metal roofing sheet")
        self.assertEqual(result.identified_product_type, "roofing_sheet")
        self.assertEqual(result.seasonal_relevance.value, "dry")
        self.assertEqual(
            result.seasonal_evidence_level.value,
            "provisional_general_mechanism",
        )
        self.assertGreater(len(result.evidence), 0)

    def test_rejects_invented_type_and_ambiguous_proposal(self) -> None:
        invented, _ = self.classifier(proposal("laser_unicorn_hammer"))
        self.assertTrue(
            invented.classify(product_name="Mystery device").is_unknown
        )

        ambiguous, _ = self.classifier(
            proposal(
                "paint_thinner",
                confidence="unknown",
                clarification_needed=True,
            )
        )
        self.assertTrue(ambiguous.classify(product_name="TINER").is_unknown)

    def test_local_context_guard_rejects_thinner_without_paint_context(self) -> None:
        classifier, _ = self.classifier(
            proposal("paint_thinner", confidence="medium")
        )
        without_context = classifier.classify(
            product_name="thinr", category="general"
        )
        with_context = classifier.classify(
            product_name="TINER", category="paint"
        )
        self.assertTrue(without_context.is_unknown)
        self.assertEqual(with_context.identified_product_type, "paint_thinner")
        self.assertEqual(with_context.seasonal_relevance.value, "unknown")

    def test_generated_seasonal_claim_is_discarded(self) -> None:
        classifier, _ = self.classifier(
            proposal(
                "paint_roller",
                explanation="This has 40% more rainy-season demand.",
            )
        )
        result = classifier.classify(product_name="Paint roller")
        self.assertNotIn("40%", result.explanation)
        self.assertEqual(result.seasonal_relevance.value, "unknown")

    def test_high_confidence_is_capped_without_direct_name_support(self) -> None:
        classifier, _ = self.classifier(proposal("rebar"))
        result = classifier.classify(
            product_name="16mm ribbed reinforcement",
            description="Steel embedded in concrete",
        )
        self.assertEqual(result.identification_confidence.value, "medium")

    def test_settings_reads_existing_dotenv_without_exporting_or_logging_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("GEMINI_CLASSIFICATION_KEY=test-secret-value\n")
            with patch.dict(os.environ, {}, clear=True), patch(
                "app.classification.gemini._dotenv_candidates",
                return_value=(path,),
            ):
                settings = GeminiClassificationSettings.from_environment()
            self.assertEqual(settings.api_key, "test-secret-value")
            self.assertNotIn("GEMINI_CLASSIFICATION_KEY", os.environ)


if __name__ == "__main__":
    unittest.main()
