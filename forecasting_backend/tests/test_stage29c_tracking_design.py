from __future__ import annotations

import hashlib
import json
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
from uuid import UUID, uuid4


@dataclass(frozen=True)
class ForecastPayload:
    product_id: UUID
    location_id: UUID
    model: str
    version: str
    history_days: int
    experimental: bool
    generated_at: datetime
    source_data_as_of: datetime
    period_start: date
    period_end: date
    predicted_demand: Decimal
    available_inventory: Decimal
    unit: str

    def digest(self) -> str:
        value = {
            "available_inventory": str(self.available_inventory),
            "experimental": self.experimental,
            "generated_at": self.generated_at.isoformat(),
            "history_days": self.history_days,
            "location_id": str(self.location_id),
            "model": self.model,
            "period_end": self.period_end.isoformat(),
            "period_start": self.period_start.isoformat(),
            "predicted_demand": str(self.predicted_demand),
            "product_id": str(self.product_id),
            "source_data_as_of": self.source_data_as_of.isoformat(),
            "unit": self.unit,
            "version": self.version,
        }
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class Product:
    product_id: UUID
    location_id: UUID
    name: str
    sku: str
    unit: str
    stock: Decimal
    active: bool = True


@dataclass(frozen=True)
class Snapshot:
    snapshot_id: int
    request_id: UUID
    payload_hash: str
    product_id_snapshot: UUID
    location_id_snapshot: UUID
    product_name_snapshot: str
    sku_snapshot: str
    unit_snapshot: str
    predicted: Decimal
    available: Decimal
    suggested: Decimal
    created_at: datetime


@dataclass(frozen=True)
class Receipt:
    receipt_id: UUID
    product_id: UUID
    location_id: UUID
    created_at: datetime
    quantity: Decimal
    transaction_type: str = "stock_in"
    canonical_unit: str | None = None


class TrackingFixture:
    """In-memory behavioral contract for the proposed append-only SQL."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.products: dict[UUID, Product] = {}
        self.snapshots: dict[int, Snapshot] = {}
        self.request_index: dict[tuple[UUID, UUID], int] = {}
        self.receipts: dict[UUID, Receipt] = {}
        self.allocations: dict[tuple[int, UUID], Decimal] = {}
        self.reconciled: dict[int, bool] = {}
        self.next_snapshot_id = 1

    def save(
        self,
        *,
        request_id: UUID,
        payload: ForecastPayload,
        trusted_server: bool,
        now: datetime,
    ) -> tuple[Snapshot, bool]:
        if not trusted_server:
            raise PermissionError("trusted FastAPI boundary required")
        if (
            payload.model != "lightgbm"
            or payload.version != "1"
            or payload.history_days != 365
            or payload.experimental
            or payload.period_end != payload.period_start + timedelta(days=27)
            or payload.generated_at < now - timedelta(hours=24)
            or payload.generated_at > now + timedelta(minutes=5)
        ):
            raise ValueError("unapproved or stale forecast")

        key = (payload.location_id, request_id)
        payload_hash = payload.digest()
        with self.lock:
            existing_id = self.request_index.get(key)
            if existing_id is not None:
                existing = self.snapshots[existing_id]
                if existing.payload_hash != payload_hash:
                    raise ValueError("request conflict")
                return existing, True

            product = self.products.get(payload.product_id)
            if product is None or not product.active:
                raise ValueError("product unavailable")
            if product.location_id != payload.location_id:
                raise ValueError("wrong location")
            if product.stock != payload.available_inventory:
                raise ValueError("stale inventory")
            if product.unit.lower() != payload.unit.lower():
                raise ValueError("unit mismatch")
            suggested = max(
                Decimal("0"),
                (payload.predicted_demand - payload.available_inventory).to_integral_value(
                    rounding=ROUND_CEILING
                ),
            )
            snapshot = Snapshot(
                snapshot_id=self.next_snapshot_id,
                request_id=request_id,
                payload_hash=payload_hash,
                product_id_snapshot=product.product_id,
                location_id_snapshot=product.location_id,
                product_name_snapshot=product.name,
                sku_snapshot=product.sku,
                unit_snapshot=product.unit,
                predicted=payload.predicted_demand,
                available=payload.available_inventory,
                suggested=suggested,
                created_at=now,
            )
            self.next_snapshot_id += 1
            self.snapshots[snapshot.snapshot_id] = snapshot
            self.request_index[key] = snapshot.snapshot_id
            return snapshot, False

    def delete_product(self, product_id: UUID) -> None:
        """Simulate the live product delete plus transaction-history cascade."""
        with self.lock:
            self.products.pop(product_id, None)
            for receipt_id, receipt in list(self.receipts.items()):
                if receipt.product_id == product_id:
                    self.receipts.pop(receipt_id)

    def match(self, snapshot_id: int, receipt_id: UUID, quantity: Decimal) -> bool:
        with self.lock:
            key = (snapshot_id, receipt_id)
            if key in self.allocations:
                if self.allocations[key] != quantity:
                    raise ValueError("allocation conflict")
                return True
            if snapshot_id in self.reconciled:
                raise ValueError("already reconciled")
            snapshot = self.snapshots[snapshot_id]
            receipt = self.receipts.get(receipt_id)
            if (
                receipt is None
                or receipt.transaction_type != "stock_in"
                or receipt.quantity <= 0
                or receipt.product_id != snapshot.product_id_snapshot
                or receipt.location_id != snapshot.location_id_snapshot
                or receipt.created_at < snapshot.created_at
                or quantity <= 0
            ):
                raise ValueError("ineligible receipt")
            if receipt.canonical_unit is None:
                raise ValueError("receipt unit cannot be verified")
            if receipt.canonical_unit.lower() != snapshot.unit_snapshot.lower():
                raise ValueError("unit mismatch; supplier packs are not inventory units")
            allocated = sum(
                value
                for (_, allocated_receipt), value in self.allocations.items()
                if allocated_receipt == receipt_id
            )
            if allocated + quantity > receipt.quantity:
                raise ValueError("over-allocation")
            self.allocations[key] = quantity
            return False

    def reconcile(self, snapshot_id: int, *, confirm_no_receipts: bool) -> None:
        with self.lock:
            values = [
                value
                for (allocated_snapshot, _), value in self.allocations.items()
                if allocated_snapshot == snapshot_id
            ]
            if not values and not confirm_no_receipts:
                raise ValueError("explicit no-receipt confirmation required")
            if values and confirm_no_receipts:
                raise ValueError("no-receipt confirmation conflicts with allocations")
            self.reconciled[snapshot_id] = confirm_no_receipts

    def evaluation(self, snapshot_id: int) -> dict[str, Decimal | str | None]:
        snapshot = self.snapshots[snapshot_id]
        values = [
            value
            for (allocated_snapshot, _), value in self.allocations.items()
            if allocated_snapshot == snapshot_id
        ]
        if snapshot_id in self.reconciled:
            status = "reconciled"
            received = sum(values, Decimal("0"))
        elif values:
            status = "partially_received"
            received = sum(values, Decimal("0"))
        else:
            status = "pending"
            received = None
        signed = received - snapshot.suggested if received is not None else None
        return {
            "status": status,
            "received": received,
            "signed": signed,
            "absolute": abs(signed) if signed is not None else None,
            "percentage": (
                signed / snapshot.suggested * Decimal("100")
                if signed is not None and snapshot.suggested > 0
                else None
            ),
        }


class Stage29CTrackingDesignTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 11, 11, 4, tzinfo=timezone.utc)
        self.location_id = uuid4()
        self.product_id = uuid4()
        self.tracker = TrackingFixture()
        self.tracker.products[self.product_id] = Product(
            product_id=self.product_id,
            location_id=self.location_id,
            name="Concrete Hollow Blocks",
            sku="SEAS-SUM-001",
            unit="pcs",
            stock=Decimal("20"),
        )
        self.payload = ForecastPayload(
            product_id=self.product_id,
            location_id=self.location_id,
            model="lightgbm",
            version="1",
            history_days=365,
            experimental=False,
            generated_at=self.now,
            source_data_as_of=self.now,
            period_start=date(2026, 11, 11),
            period_end=date(2026, 12, 8),
            predicted_demand=Decimal("50.2"),
            available_inventory=Decimal("20"),
            unit="pcs",
        )

    def save(self, request_id: UUID | None = None) -> Snapshot:
        snapshot, reused = self.tracker.save(
            request_id=request_id or uuid4(),
            payload=self.payload,
            trusted_server=True,
            now=self.now,
        )
        self.assertFalse(reused)
        return snapshot

    def test_idempotent_retry_survives_inventory_change(self) -> None:
        request_id = uuid4()
        first, reused = self.tracker.save(
            request_id=request_id,
            payload=self.payload,
            trusted_server=True,
            now=self.now,
        )
        self.assertFalse(reused)
        self.tracker.products[self.product_id] = replace(
            self.tracker.products[self.product_id], stock=Decimal("99")
        )
        retry, reused = self.tracker.save(
            request_id=request_id,
            payload=self.payload,
            trusted_server=True,
            now=self.now,
        )
        self.assertTrue(reused)
        self.assertEqual(retry, first)
        self.assertEqual(retry.available, Decimal("20"))

    def test_conflicting_idempotent_retry_is_rejected(self) -> None:
        request_id = uuid4()
        self.save(request_id)
        with self.assertRaisesRegex(ValueError, "request conflict"):
            self.tracker.save(
                request_id=request_id,
                payload=replace(self.payload, predicted_demand=Decimal("51")),
                trusted_server=True,
                now=self.now,
            )

    def test_product_deletion_preserves_snapshot_and_allocation(self) -> None:
        snapshot = self.save()
        receipt_id = uuid4()
        self.tracker.receipts[receipt_id] = Receipt(
            receipt_id=receipt_id,
            product_id=self.product_id,
            location_id=self.location_id,
            created_at=self.now + timedelta(days=2),
            quantity=Decimal("15"),
            canonical_unit="pcs",
        )
        self.tracker.match(snapshot.snapshot_id, receipt_id, Decimal("10"))
        self.tracker.delete_product(self.product_id)
        self.assertEqual(snapshot.product_name_snapshot, "Concrete Hollow Blocks")
        self.assertEqual(
            self.tracker.allocations[(snapshot.snapshot_id, receipt_id)], Decimal("10")
        )

    def test_untrusted_experimental_and_stale_submissions_are_rejected(self) -> None:
        with self.assertRaises(PermissionError):
            self.tracker.save(
                request_id=uuid4(),
                payload=self.payload,
                trusted_server=False,
                now=self.now,
            )
        with self.assertRaisesRegex(ValueError, "unapproved"):
            self.tracker.save(
                request_id=uuid4(),
                payload=replace(
                    self.payload, model="seasonal_experimental", experimental=True
                ),
                trusted_server=True,
                now=self.now,
            )
        with self.assertRaisesRegex(ValueError, "unapproved"):
            self.tracker.save(
                request_id=uuid4(),
                payload=replace(
                    self.payload,
                    generated_at=self.now - timedelta(days=2),
                ),
                trusted_server=True,
                now=self.now,
            )

    def test_first_save_rejects_stale_inventory(self) -> None:
        with self.assertRaisesRegex(ValueError, "stale inventory"):
            self.tracker.save(
                request_id=uuid4(),
                payload=replace(self.payload, available_inventory=Decimal("19")),
                trusted_server=True,
                now=self.now,
            )

    def test_partial_and_multiple_receipts_remain_partial_until_confirmed(self) -> None:
        snapshot = self.save()
        for day, quantity in ((2, Decimal("10")), (5, Decimal("12"))):
            receipt_id = uuid4()
            self.tracker.receipts[receipt_id] = Receipt(
                receipt_id=receipt_id,
                product_id=self.product_id,
                location_id=self.location_id,
                created_at=self.now + timedelta(days=day),
                quantity=quantity,
                canonical_unit="pcs",
            )
            self.tracker.match(snapshot.snapshot_id, receipt_id, quantity)
        partial = self.tracker.evaluation(snapshot.snapshot_id)
        self.assertEqual(partial["status"], "partially_received")
        self.assertEqual(partial["received"], Decimal("22"))
        self.tracker.reconcile(snapshot.snapshot_id, confirm_no_receipts=False)
        self.assertEqual(
            self.tracker.evaluation(snapshot.snapshot_id)["status"], "reconciled"
        )

    def test_concurrent_allocations_cannot_overallocate_one_receipt(self) -> None:
        first = self.save()
        second, _ = self.tracker.save(
            request_id=uuid4(),
            payload=replace(
                self.payload,
                generated_at=self.now + timedelta(minutes=1),
                source_data_as_of=self.now + timedelta(minutes=1),
            ),
            trusted_server=True,
            now=self.now,
        )
        receipt_id = uuid4()
        self.tracker.receipts[receipt_id] = Receipt(
            receipt_id=receipt_id,
            product_id=self.product_id,
            location_id=self.location_id,
            created_at=self.now + timedelta(days=1),
            quantity=Decimal("10"),
            canonical_unit="pcs",
        )
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(self.tracker.match, sid, receipt_id, Decimal("6"))
                for sid in (first.snapshot_id, second.snapshot_id)
            ]
        successes = sum(f.exception() is None for f in futures)
        failures = [f.exception() for f in futures if f.exception() is not None]
        self.assertEqual(successes, 1)
        self.assertEqual(len(failures), 1)
        self.assertIn("over-allocation", str(failures[0]))

    def test_unknown_or_supplier_pack_units_are_not_guessed_or_converted(self) -> None:
        snapshot = self.save()
        unknown_id = uuid4()
        self.tracker.receipts[unknown_id] = Receipt(
            receipt_id=unknown_id,
            product_id=self.product_id,
            location_id=self.location_id,
            created_at=self.now + timedelta(days=1),
            quantity=Decimal("2"),
            canonical_unit=None,
        )
        with self.assertRaisesRegex(ValueError, "cannot be verified"):
            self.tracker.match(snapshot.snapshot_id, unknown_id, Decimal("1"))
        box_id = uuid4()
        self.tracker.receipts[box_id] = Receipt(
            receipt_id=box_id,
            product_id=self.product_id,
            location_id=self.location_id,
            created_at=self.now + timedelta(days=1),
            quantity=Decimal("2"),
            canonical_unit="box",
        )
        with self.assertRaisesRegex(ValueError, "supplier packs"):
            self.tracker.match(snapshot.snapshot_id, box_id, Decimal("1"))

    def test_pending_does_not_treat_missing_receipts_as_zero(self) -> None:
        evaluation = self.tracker.evaluation(self.save().snapshot_id)
        self.assertEqual(evaluation["status"], "pending")
        self.assertIsNone(evaluation["received"])
        self.assertIsNone(evaluation["signed"])

    def test_zero_recommendation_can_be_explicitly_reconciled_without_receipts(self) -> None:
        snapshot, _ = self.tracker.save(
            request_id=uuid4(),
            payload=replace(
                self.payload,
                predicted_demand=Decimal("5"),
                available_inventory=Decimal("20"),
            ),
            trusted_server=True,
            now=self.now,
        )
        self.assertEqual(snapshot.suggested, Decimal("0"))
        self.assertIsNone(self.tracker.evaluation(snapshot.snapshot_id)["received"])
        self.tracker.reconcile(snapshot.snapshot_id, confirm_no_receipts=True)
        evaluation = self.tracker.evaluation(snapshot.snapshot_id)
        self.assertEqual(evaluation["status"], "reconciled")
        self.assertEqual(evaluation["received"], Decimal("0"))
        self.assertIsNone(evaluation["percentage"])


if __name__ == "__main__":
    unittest.main()
