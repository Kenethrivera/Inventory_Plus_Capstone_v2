from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from app.classification import HardwareProductClassifier, HardwareTaxonomyMatcher


CLASSIFICATION_DIR = Path(__file__).parents[1] / "app" / "classification"


class HierarchicalSeasonalityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.classifier = HardwareProductClassifier.load_default(
            semantic_mode="disabled"
        )

    def classify(self, name: str, category: str = "", description: str = ""):
        return self.classifier.classify(
            product_name=name,
            category=category,
            description=description,
        )

    def test_concrete_blocks_inherit_documented_construction_relationship(self) -> None:
        result = self.classify(
            "Concrete Hollow Blocks",
            "Masonry",
            "Hollow concrete units for exterior wall construction",
        )
        self.assertEqual(result.identified_product_type, "concrete_hollow_block")
        self.assertEqual(result.seasonal_relevance.value, "dry")
        self.assertEqual(
            result.seasonal_match_type.value,
            "inherited_industry_activity",
        )
        self.assertEqual(
            result.seasonal_evidence_level.value,
            "inherited_industry_evidence",
        )
        self.assertIn("Masonry construction", result.seasonal_hierarchy)
        self.assertIn(
            "Outdoor/weather-exposed construction", result.seasonal_hierarchy
        )
        self.assertEqual(len(result.evidence), 2)

    def test_product_specific_evidence_has_priority_over_inheritance(self) -> None:
        cases = (
            ("Portland Cement", "portland_cement", "dry"),
            ("Metal roofing sheet", "roofing_sheet", "dry"),
            ("Waterproofing sealant", "waterproofing_sealant", "rainy"),
        )
        for name, product_type, relevance in cases:
            with self.subTest(name=name):
                result = self.classify(name)
                self.assertEqual(result.identified_product_type, product_type)
                self.assertEqual(result.seasonal_relevance.value, relevance)
                self.assertEqual(
                    result.seasonal_match_type.value,
                    "product_specific",
                )
                self.assertGreater(len(result.evidence), 0)

    def test_unsupported_inheritance_remains_unknown(self) -> None:
        cases = (
            ("Chicken wire", "Fencing", "poultry_netting"),
            ("General screwdriver", "Hand Tools", "screwdriver"),
        )
        for name, category, product_type in cases:
            with self.subTest(name=name):
                result = self.classify(name, category)
                self.assertEqual(result.identified_product_type, product_type)
                self.assertEqual(result.seasonal_relevance.value, "unknown")
                self.assertEqual(result.seasonal_match_type.value, "insufficient")
                self.assertEqual(result.seasonal_evidence_level.value, "insufficient")
                self.assertEqual(result.evidence, ())

    def test_unknown_product_has_unknown_identity_and_seasonality(self) -> None:
        result = self.classify("Unknown Product XYZ", "General")
        self.assertTrue(result.is_unknown)
        self.assertEqual(result.seasonal_relevance.value, "unknown")
        self.assertEqual(result.seasonal_match_type.value, "insufficient")

    def test_reassessment_uses_new_knowledge_without_product_persistence(self) -> None:
        payload = json.loads(
            (CLASSIFICATION_DIR / "hardware_knowledge_base.json").read_text(
                encoding="utf-8"
            )
        )
        revised = copy.deepcopy(payload)
        revised["version"] = "reassessment-test"
        activity = revised["industry_activity_groups"][
            "outdoor_weather_exposed_construction"
        ]
        activity["seasonal_relevance"] = "rainy"
        activity["seasonal_explanation"] = (
            "Test-only revised relationship proving that results are recomputed."
        )
        classifier = HardwareProductClassifier(
            payload=revised,
            taxonomy_matcher=HardwareTaxonomyMatcher.load_default(
                semantic_mode="disabled"
            ),
        )
        result = classifier.classify(
            product_name="Concrete Hollow Blocks",
            category="Masonry",
        )
        self.assertEqual(result.seasonal_relevance.value, "rainy")


if __name__ == "__main__":
    unittest.main()
