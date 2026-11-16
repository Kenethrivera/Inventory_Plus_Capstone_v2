from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone

from run_forecast_maintenance import select_product_batch
from app.api.contracts import ProductNotFoundError
from tests.test_forecast_job_materialization import (
    AS_OF, PRODUCT_A, PRODUCT_B, FakeCatalog, FakeRepository,
    ForecastJobMaterializationTests, _history,
)


class ForecastMaintenanceTests(unittest.TestCase):
    def test_rotation_is_bounded_stable_and_covers_catalog(self):
        products = tuple(f"product-{number:02d}" for number in range(7))
        start = datetime(2026, 11, 13, 0, 0, tzinfo=timezone.utc)
        batches = [
            select_product_batch(
                products, now=start + timedelta(minutes=5 * index),
                batch_size=3, rotation_minutes=5,
            ) for index in range(3)
        ]
        self.assertEqual({item for batch in batches for item in batch}, set(products))
        self.assertEqual(
            batches[0], select_product_batch(
                products, now=start + timedelta(minutes=4),
                batch_size=3, rotation_minutes=5,
            ),
        )
        self.assertTrue(all(len(batch) <= 3 for batch in batches))

    def test_bounded_materialization_only_initializes_selected_products(self):
        fixture = ForecastJobMaterializationTests()
        fixture.setUp()
        fixture.catalog = FakeCatalog({
            PRODUCT_A: _history(PRODUCT_A), PRODUCT_B: _history(PRODUCT_B),
        })
        fixture.repository = FakeRepository()
        materializer = fixture._materializer()
        report = materializer.bootstrap(
            profile=fixture.profile, session_token="test-token", now=AS_OF,
            product_ids=(PRODUCT_B,),
        )
        self.assertEqual(report.active_products, 1)
        self.assertEqual(report.queued, 1)
        self.assertEqual(set(fixture.repository.revisions), {PRODUCT_B})
        repeat = materializer.bootstrap(
            profile=fixture.profile, session_token="test-token", now=AS_OF,
            product_ids=(PRODUCT_B,),
        )
        self.assertEqual(repeat.duplicate, 1)

    def test_batch_rejects_unauthorized_or_unbounded_selection(self):
        fixture = ForecastJobMaterializationTests()
        fixture.setUp()
        materializer = fixture._materializer()
        with self.assertRaises(ValueError):
            materializer.bootstrap(
                profile=fixture.profile, session_token="test-token", now=AS_OF,
                product_ids=tuple(
                    f"00000000-0000-4000-8000-{number:012d}" for number in range(26)
                ),
            )
        with self.assertRaises(ProductNotFoundError):
            materializer.bootstrap(
                profile=fixture.profile, session_token="test-token", now=AS_OF,
                product_ids=(PRODUCT_B,),
            )
        self.assertFalse(fixture.repository.revisions)


if __name__ == "__main__":
    unittest.main()
