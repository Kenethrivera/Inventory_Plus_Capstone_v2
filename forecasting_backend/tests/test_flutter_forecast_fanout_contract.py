from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORECASTING_PAGE = ROOT / "lib" / "ui" / "forecasting_page.dart"


class FlutterForecastFanoutContractTests(unittest.TestCase):
    def test_overview_probes_one_product_before_bounded_fanout(self) -> None:
        source = FORECASTING_PAGE.read_text(encoding="utf-8")
        probe = source.index("final probe = await loadProduct(_items.first);")
        fanout = source.index("const maxConcurrentAnalyses = 2;")
        self.assertLess(probe, fanout)
        self.assertIn("final remaining = _items.skip(1)", source)
        self.assertNotIn("start += 4", source)


if __name__ == "__main__":
    unittest.main()
