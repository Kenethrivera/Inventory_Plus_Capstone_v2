from __future__ import annotations

import json
import unittest
from pathlib import Path

from app.classification import HardwareProductClassifier


FIXTURE = Path(__file__).parent / "fixtures" / "hardware_classification_cases.json"


class HardwareProductClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.classifier = HardwareProductClassifier.load_default(
            semantic_mode="disabled"
        )
        cls.lexical_classifier = HardwareProductClassifier.load_default(
            semantic_mode="disabled"
        )
        cls.cases = json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]

    def test_matches_independently_labeled_cases(self) -> None:
        mismatches: list[str] = []
        for case in self.cases:
            result = self.classifier.classify(
                product_name=case["name"],
                category=case["category"],
                description=case["description"],
            )
            if result.identified_product_type != case["expected_type"]:
                mismatches.append(
                    f'{case["id"]}: type={result.identified_product_type}'
                )
            if result.seasonal_relevance.value != case["expected_relevance"]:
                mismatches.append(
                    f'{case["id"]}: relevance={result.seasonal_relevance.value}'
                )
        self.assertEqual(mismatches, [])

    def test_existing_inventory_cases_are_all_present(self) -> None:
        inventory_cases = [case for case in self.cases if case["inventory"]]
        self.assertEqual(len(inventory_cases), 13)

    def test_misleading_category_reduces_identification_confidence(self) -> None:
        result = self.classifier.classify(
            product_name="Portland Cement",
            category="Hand Tools",
            description="Binder for mortar and concrete.",
        )
        self.assertEqual(result.identified_product_type, "portland_cement")
        self.assertEqual(result.identification_confidence.value, "medium")

    def test_ambiguous_and_unsupported_products_abstain(self) -> None:
        for name, category in (
            ("Universal Sealant", ""),
            ("Pro Tool 500", "Tools"),
            ("Laptop Charger", "Electronics"),
            ("Unknown Product XYZ", "General"),
        ):
            with self.subTest(name=name):
                result = self.classifier.classify(
                    product_name=name, category=category
                )
                self.assertTrue(result.is_unknown)
                self.assertEqual(result.identification_confidence.value, "unknown")
                self.assertEqual(result.seasonal_evidence_level.value, "insufficient")

    def test_new_product_does_not_require_catalog_profile(self) -> None:
        result = self.classifier.classify(
            product_name="Waterproofing Sealant",
            category="Waterproofing",
            description="Seals wall cracks against water ingress.",
        )
        self.assertEqual(result.identified_product_type, "waterproofing_sealant")
        self.assertEqual(result.seasonal_relevance.value, "rainy")
        self.assertNotEqual(result.seasonal_evidence_level.value, "verified")

    def test_generalizes_required_manual_cases_without_new_exact_rules(self) -> None:
        cases = (
            ("paint", "", "architectural_paint"),
            ("paint roller", "", "paint_roller"),
            ("galvanize steel", "", "galvanized_steel_material"),
            ("TINER", "paint", "paint_thinner"),
        )
        for name, category, expected in cases:
            with self.subTest(name=name):
                result = self.lexical_classifier.classify(
                    product_name=name,
                    category=category,
                )
                self.assertEqual(result.identified_product_type, expected)
                self.assertIn(result.identification_confidence.value, {"low", "medium"})
                self.assertEqual(result.seasonal_relevance.value, "unknown")
                self.assertEqual(result.seasonal_evidence_level.value, "insufficient")
                self.assertEqual(result.identification_method, "lexical_taxonomy")

    def test_context_guards_abstain_instead_of_forcing_ambiguous_types(self) -> None:
        for name, category in (
            ("TINER", "general"),
            ("roller", "general"),
            ("blade", "tools"),
            ("galvanized", "general"),
            ("Unknown Product XYZ", "general"),
        ):
            with self.subTest(name=name):
                result = self.lexical_classifier.classify(
                    product_name=name,
                    category=category,
                )
                self.assertTrue(result.is_unknown)
                self.assertTrue(result.clarification_needed)

    def test_generalized_outputs_are_limited_to_controlled_taxonomy(self) -> None:
        taxonomy = json.loads(
            (FIXTURE.parents[2] / "app" / "classification" / "hardware_taxonomy.json")
            .read_text(encoding="utf-8")
        )
        allowed = {value["product_type"] for value in taxonomy["types"]}
        for name, category in (
            ("adjustible spanner", "manual tools"),
            ("zinc protected steel stock", "fabrication"),
            ("wall color coating", "decorating"),
        ):
            result = self.lexical_classifier.classify(
                product_name=name,
                category=category,
            )
            self.assertIn(result.identified_product_type, allowed | {"unknown"})

    def test_no_rule_contains_a_numerical_demand_multiplier(self) -> None:
        payload = json.loads(
            (FIXTURE.parents[2] / "app" / "classification" / "hardware_knowledge_base.json")
            .read_text(encoding="utf-8")
        )
        for rule in payload["rules"]:
            self.assertFalse(any("multiplier" in key.casefold() for key in rule))
            self.assertFalse(any(isinstance(value, (int, float)) for value in rule.values()))
        taxonomy = json.loads(
            (FIXTURE.parents[2] / "app" / "classification" / "hardware_taxonomy.json")
            .read_text(encoding="utf-8")
        )
        self.assertNotIn("multiplier", json.dumps(taxonomy).casefold())


if __name__ == "__main__":
    unittest.main()
