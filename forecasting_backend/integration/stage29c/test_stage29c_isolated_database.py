from __future__ import annotations

import json
import os
import threading
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

try:
    import psycopg
except ImportError:  # pragma: no cover - exercised only in configured runs
    psycopg = None


ROOT = Path(__file__).resolve().parents[3]
PROPOSAL = ROOT / "database" / "stage_2_9c_recommendation_tracking_PROPOSAL.sql"
CLEANUP = Path(__file__).with_name("stage29c_cleanup.sql")
PROTECTED_PROJECT_REF = "pzotcznujkuzymndluwl"
LOCATION_ID = "29c00000-0000-4000-8000-000000000001"
PRODUCT_ID = "29c00000-0000-4000-8000-000000000001"
PRODUCT_2_ID = "29c00000-0000-4000-8000-000000000002"
ADMIN_TOKEN = "stage29c-admin-token"
HELPER_TOKEN = "stage29c-helper-token"


def _env(name: str) -> str:
    return os.getenv(name, "").strip()


def _assert_raises_message(test: unittest.TestCase, expected: str, action) -> None:
    with test.assertRaises(Exception) as caught:
        action()
    test.assertIn(expected, str(caught.exception))


class Stage29CIsolatedDatabaseTests(unittest.TestCase):
    """Destructive only after an operator-created disposable marker is found."""

    @classmethod
    def setUpClass(cls) -> None:
        configured = any(
            _env(name)
            for name in (
                "STAGE29C_TEST_DATABASE_URL",
                "STAGE29C_TEST_PROJECT_REF",
                "STAGE29C_TEST_ENVIRONMENT_MARKER",
                "STAGE29C_TEST_WRITE_CONFIRMATION",
            )
        )
        if not configured:
            raise unittest.SkipTest("Stage 2.9C disposable database is not configured")
        if psycopg is None:
            raise RuntimeError("Install integration/stage29c/requirements.txt")

        cls.database_url = _env("STAGE29C_TEST_DATABASE_URL")
        cls.project_ref = _env("STAGE29C_TEST_PROJECT_REF")
        marker = _env("STAGE29C_TEST_ENVIRONMENT_MARKER")
        confirmation = _env("STAGE29C_TEST_WRITE_CONFIRMATION")
        if not cls.database_url or not cls.project_ref:
            raise RuntimeError("Disposable database URL and project ref are required")
        if cls.project_ref.lower() == PROTECTED_PROJECT_REF:
            raise RuntimeError("Refusing to test the protected Inventory Plus project")
        if PROTECTED_PROJECT_REF in cls.database_url.lower():
            raise RuntimeError("Database URL points at the protected project")
        if marker != "inventory-plus-stage29c":
            raise RuntimeError("Stage 2.9C isolated environment marker is invalid")
        if confirmation != "I_APPROVE_STAGE29C_WRITES_ON_THIS_DISPOSABLE_DATABASE":
            raise RuntimeError("Stage 2.9C disposable write confirmation is invalid")

        cls.connection = psycopg.connect(cls.database_url, autocommit=True)
        with cls.connection.cursor() as cursor:
            cursor.execute(
                """
                select project_ref, purpose, allow_schema_writes
                from private.stage29c_isolated_environment
                where marker = 'inventory-plus-stage29c'
                """
            )
            identity = cursor.fetchone()
        expected = (
            cls.project_ref,
            "inventory-plus-stage29c-isolated-integration",
            True,
        )
        if identity != expected:
            cls.connection.close()
            raise RuntimeError("Database-side Stage 2.9C authorization is absent")

        cls._assert_proposal_absent()
        try:
            cls._execute(PROPOSAL.read_text(encoding="utf-8"))
            cls._seed_fixtures()
        except Exception:
            # If proposal compilation succeeded but fixture setup failed, do not
            # leave test-owned objects behind on the disposable database.
            with cls.connection.cursor() as cursor:
                cursor.execute(
                    "select set_config(%s, %s, false)",
                    ("inventory_plus.stage29c_expected_project_ref", cls.project_ref),
                )
            try:
                cls._execute(CLEANUP.read_text(encoding="utf-8"))
            finally:
                cls.connection.close()
            raise

    @classmethod
    def tearDownClass(cls) -> None:
        connection = getattr(cls, "connection", None)
        if connection is None:
            return
        try:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select set_config(%s, %s, false)",
                    ("inventory_plus.stage29c_expected_project_ref", cls.project_ref),
                )
            cls._execute(CLEANUP.read_text(encoding="utf-8"))
            cls._assert_proposal_absent()
        finally:
            connection.close()

    @classmethod
    def _execute(cls, statement: str, params=None):
        with cls.connection.cursor() as cursor:
            cursor.execute(statement, params)
            if cursor.description:
                return cursor.fetchall()
        return []

    @classmethod
    def _assert_proposal_absent(cls) -> None:
        rows = cls._execute(
            """
            select count(*)
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public'
              and c.relname like 'forecast_recommendation_%'
            """
        )
        if rows[0][0] != 0:
            raise RuntimeError("Stage 2.9C objects already exist; refusing ownership")

    @classmethod
    def _seed_fixtures(cls) -> None:
        cls._execute(
            """
            insert into public.locations (id, location_name, store_key)
            values (%s, 'Stage29C Disposable', 'stage29c-disposable')
            """,
            (LOCATION_ID,),
        )
        cls._execute(
            """
            insert into public.profiles (id, name, username, password, role, location_id)
            values
              (-29001, 'Stage29C Admin', 'stage29c_admin', 'not-used', 'admin', %s),
              (-29002, 'Stage29C Helper', 'stage29c_helper', 'not-used', 'helper', %s)
            """,
            (LOCATION_ID, LOCATION_ID),
        )
        cls._execute(
            """
            insert into private.app_sessions (token_hash, profile_id, expires_at)
            values
              (extensions.digest(convert_to(%s, 'UTF8'), 'sha256'), -29001,
                now() + interval '1 day'),
              (extensions.digest(convert_to(%s, 'UTF8'), 'sha256'), -29002,
                now() + interval '1 day')
            """,
            (ADMIN_TOKEN, HELPER_TOKEN),
        )
        cls._execute(
            """
            insert into public.products (
              id, sku, product_name, unit, product_quantity, max_quantity,
              location_id, is_active
            ) values
              (%s, 'S29C-1', 'Stage29C Product', 'pcs', 10, 100, %s, true),
              (%s, 'S29C-2', 'Stage29C Zero Product', 'pcs', 10, 100, %s, true);
            """,
            (PRODUCT_ID, LOCATION_ID, PRODUCT_2_ID, LOCATION_ID),
        )

    @staticmethod
    def _forecast_args(
        request_id: str,
        *,
        product_id: str = PRODUCT_ID,
        predicted: str = "28.4",
        available: str = "10",
        model: str = "lightgbm",
        experimental: bool = False,
    ) -> tuple:
        generated = datetime.now(timezone.utc).replace(microsecond=0)
        start = generated.astimezone(ZoneInfo("Asia/Manila")).date()
        return (
            ADMIN_TOKEN,
            request_id,
            product_id,
            model,
            "1",
            365,
            experimental,
            generated,
            generated,
            28,
            start,
            start + timedelta(days=27),
            predicted,
            available,
            "pcs",
            json.dumps(["owner_review_required"]),
        )

    @classmethod
    def _save(cls, args: tuple):
        return cls._execute(
            """
            select public.save_forecast_recommendation_snapshot_v1(
              %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb
            )
            """,
            args,
        )[0][0]

    def test_01_migration_signatures_and_privileges(self) -> None:
        expected = (
            "forecast_recommendation_snapshot_by_request_v1(text,uuid)",
            "save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamp with time zone,timestamp with time zone,integer,date,date,numeric,numeric,text,jsonb)",
            "match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)",
            "reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)",
            "forecast_recommendation_tracking_v1(text,uuid)",
        )
        for signature in expected:
            with self.subTest(signature=signature):
                self.assertEqual(
                    self._execute("select to_regprocedure(%s) is not null", (signature,))[0][0],
                    True,
                )
                self.assertFalse(
                    self._execute(
                        "select has_function_privilege('anon', %s, 'EXECUTE')",
                        (signature,),
                    )[0][0]
                )
                self.assertTrue(
                    self._execute(
                        "select has_function_privilege('service_role', %s, 'EXECUTE')",
                        (signature,),
                    )[0][0]
                )

    def test_02_authorization_forgery_staleness_and_idempotency(self) -> None:
        request_id = str(uuid.uuid4())
        args = self._forecast_args(request_id)
        result = self._save(args)
        self.assertFalse(result["reused"])
        self.assertIsInstance(result["recommendation_id"], int)

        helper_args = (HELPER_TOKEN,) + args[1:]
        _assert_raises_message(
            self,
            "Only Admin accounts",
            lambda: self._save(helper_args),
        )
        _assert_raises_message(
            self,
            "invalid or expired",
            lambda: self._save(("invalid-token",) + args[1:]),
        )
        _assert_raises_message(
            self,
            "invalid_or_unapproved",
            lambda: self._save(self._forecast_args(str(uuid.uuid4()), model="seasonal_experimental", experimental=True)),
        )
        _assert_raises_message(
            self,
            "inventory_snapshot_is_stale",
            lambda: self._save(self._forecast_args(str(uuid.uuid4()), available="999")),
        )

        self._execute(
            "update public.products set product_quantity = 7 where id = %s",
            (PRODUCT_ID,),
        )
        retried = self._save(args)
        self.assertTrue(retried["reused"])
        self.assertEqual(retried["recommendation_id"], result["recommendation_id"])
        _assert_raises_message(
            self,
            "request_conflict",
            lambda: self._save(self._forecast_args(request_id, predicted="29.4", available="10")),
        )

        _assert_raises_message(
            self,
            "records_are_immutable",
            lambda: self._execute(
                "update public.forecast_recommendation_snapshots set predicted_demand = 1 where id = %s",
                (result["recommendation_id"],),
            ),
        )
        self.__class__.primary_recommendation_id = result["recommendation_id"]

    def test_03_pending_partial_multiple_receipts_and_reconciliation(self) -> None:
        recommendation_id = self.primary_recommendation_id
        pending = self._execute(
            "select evaluation_status, matched_received_quantity from public.forecast_recommendation_tracking_v1(%s, %s)",
            (ADMIN_TOKEN, PRODUCT_ID),
        )[0]
        self.assertEqual(pending, ("pending", None))

        receipt_ids = (str(uuid.uuid4()), str(uuid.uuid4()))
        self._execute(
            """
            insert into public.transaction_history (
              id, product_id, user_id, user_name, transaction_type,
              quantity_change, new_quantity, location_id, operation_id,
              operation_scope, created_at
            ) values
              (%s,%s,-29001,'Stage29C Admin','stock_in',8,15,%s,%s,
                'stage29c-isolated-test',clock_timestamp()),
              (%s,%s,-29001,'Stage29C Admin','stock_in',6,21,%s,%s,
                'stage29c-isolated-test',clock_timestamp() + interval '1 second')
            """,
            (
                receipt_ids[0], PRODUCT_ID, LOCATION_ID, str(uuid.uuid4()),
                receipt_ids[1], PRODUCT_ID, LOCATION_ID, str(uuid.uuid4()),
            ),
        )
        inventory_before = self._execute(
            "select product_quantity from public.products where id = %s", (PRODUCT_ID,)
        )[0][0]
        for receipt_id, quantity in zip(receipt_ids, ("3", "6")):
            response = self._execute(
                "select public.match_forecast_recommendation_receipt_v1(%s,%s,%s,%s)",
                (ADMIN_TOKEN, recommendation_id, receipt_id, quantity),
            )[0][0]
            self.assertFalse(response["reused"])
        inventory_after = self._execute(
            "select product_quantity from public.products where id = %s", (PRODUCT_ID,)
        )[0][0]
        self.assertEqual(inventory_before, inventory_after)

        partial = self._execute(
            "select evaluation_status, matched_received_quantity, signed_quantity_difference from public.forecast_recommendation_tracking_v1(%s, %s)",
            (ADMIN_TOKEN, PRODUCT_ID),
        )[0]
        self.assertEqual(partial[0], "partially_received")
        self.assertEqual(partial[1], 9)
        self.assertEqual(partial[2], -10)

        reconciliation_request = str(uuid.uuid4())
        reconciled = self._execute(
            "select public.reconcile_forecast_recommendation_v1(%s,%s,%s,false,%s)",
            (ADMIN_TOKEN, reconciliation_request, recommendation_id, "owner confirmed complete"),
        )[0][0]
        self.assertFalse(reconciled["reused"])
        final = self._execute(
            "select evaluation_status, matched_received_quantity, absolute_difference from public.forecast_recommendation_tracking_v1(%s, %s)",
            (ADMIN_TOKEN, PRODUCT_ID),
        )[0]
        self.assertEqual(final, ("reconciled", 9, 10))

    def test_04_concurrent_allocation_prevents_overallocation(self) -> None:
        self._execute("update public.products set product_quantity = 7 where id = %s", (PRODUCT_ID,))
        first = self._save(self._forecast_args(str(uuid.uuid4()), available="7"))["recommendation_id"]
        second = self._save(self._forecast_args(str(uuid.uuid4()), available="7"))["recommendation_id"]
        receipt_id = str(uuid.uuid4())
        self._execute(
            """
            insert into public.transaction_history (
              id, product_id, user_id, user_name, transaction_type,
              quantity_change, new_quantity, location_id, operation_id,
              operation_scope, created_at
            ) values (%s,%s,-29001,'Stage29C Admin','stock_in',10,17,%s,%s,
              'stage29c-isolated-test',clock_timestamp())
            """,
            (receipt_id, PRODUCT_ID, LOCATION_ID, str(uuid.uuid4())),
        )
        outcomes: list[str] = []
        barrier = threading.Barrier(2)

        def allocate(recommendation_id: int) -> None:
            try:
                with psycopg.connect(self.database_url, autocommit=True) as connection:
                    barrier.wait(timeout=10)
                    with connection.cursor() as cursor:
                        cursor.execute(
                            "select public.match_forecast_recommendation_receipt_v1(%s,%s,%s,7)",
                            (ADMIN_TOKEN, recommendation_id, receipt_id),
                        )
                outcomes.append("saved")
            except Exception as error:  # exact SQL exception is the assertion
                outcomes.append(str(error))

        threads = [threading.Thread(target=allocate, args=(value,)) for value in (first, second)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=20)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(outcomes.count("saved"), 1)
        self.assertEqual(sum("allocation_exceeds_received_quantity" in item for item in outcomes), 1)
        allocated = self._execute(
            "select sum(allocated_inventory_quantity) from public.forecast_recommendation_receipt_allocations where transaction_history_id_snapshot = %s",
            (receipt_id,),
        )[0][0]
        self.assertEqual(allocated, 7)

    def test_05_zero_variance_state_and_product_deletion_compatibility(self) -> None:
        zero = self._save(
            self._forecast_args(
                str(uuid.uuid4()), product_id=PRODUCT_2_ID, predicted="4", available="10"
            )
        )["recommendation_id"]
        self._execute(
            "select public.reconcile_forecast_recommendation_v1(%s,%s,%s,true,%s)",
            (ADMIN_TOKEN, str(uuid.uuid4()), zero, "explicitly no receipts"),
        )
        zero_row = self._execute(
            "select evaluation_status, matched_received_quantity, percentage_variance from public.forecast_recommendation_tracking_v1(%s, %s)",
            (ADMIN_TOKEN, PRODUCT_2_ID),
        )[0]
        self.assertEqual(zero_row, ("reconciled", 0, None))

        snapshot_count = self._execute(
            "select count(*) from public.forecast_recommendation_snapshots where product_id_snapshot = %s",
            (PRODUCT_ID,),
        )[0][0]
        self._execute("delete from public.products where id = %s", (PRODUCT_ID,))
        preserved = self._execute(
            "select count(*) from public.forecast_recommendation_snapshots where product_id_snapshot = %s",
            (PRODUCT_ID,),
        )[0][0]
        self.assertEqual(preserved, snapshot_count)


if __name__ == "__main__":
    unittest.main(verbosity=2)
