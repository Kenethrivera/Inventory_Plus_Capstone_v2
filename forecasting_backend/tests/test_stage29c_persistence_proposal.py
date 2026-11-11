from __future__ import annotations

import unittest
from pathlib import Path


PROPOSAL = (
    Path(__file__).resolve().parents[2]
    / "database"
    / "stage_2_9c_recommendation_tracking_PROPOSAL.sql"
)


class Stage29CPersistenceProposalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = PROPOSAL.read_text(encoding="utf-8").lower()

    def test_proposal_is_visibly_review_only(self) -> None:
        self.assertIn("review only. this file has not been executed", self.sql)

    def test_snapshot_formula_is_constrained_and_append_only(self) -> None:
        self.assertIn("forecast_recommendation_snapshots_recommended_check", self.sql)
        self.assertIn("ceil(predicted_demand - available_inventory)", self.sql)
        self.assertIn("forecast_recommendation_snapshots_immutable_v1", self.sql)
        self.assertIn("before update or delete", self.sql)

    def test_security_uses_admin_session_rls_and_trusted_server_only(self) -> None:
        self.assertIn("private.require_app_session_v1(p_session_token)", self.sql)
        self.assertIn("v_profile.role <> 'admin'", self.sql)
        self.assertIn("enable row level security", self.sql)
        self.assertIn("revoke all on table public.forecast_recommendation_snapshots", self.sql)
        self.assertIn("to service_role, postgres", self.sql)
        self.assertNotIn("to anon, service_role", self.sql)

    def test_history_uses_snapshots_without_external_deletion_blockers(self) -> None:
        self.assertIn("product_id_snapshot uuid not null", self.sql)
        self.assertIn("transaction_history_id_snapshot uuid not null", self.sql)
        self.assertNotIn("references public.products", self.sql)
        self.assertNotIn("references public.transaction_history", self.sql)
        self.assertNotIn("references public.profiles", self.sql)
        self.assertNotIn("references public.locations", self.sql)

    def test_only_approved_365_day_lightgbm_can_be_saved(self) -> None:
        self.assertIn("forecast_model = 'lightgbm'", self.sql)
        self.assertIn("forecast_version = '1'", self.sql)
        self.assertIn("training_history_days = 365", self.sql)
        self.assertIn("experimental_model = false", self.sql)
        self.assertIn("forecast_recommendation_inventory_snapshot_is_stale", self.sql)

    def test_idempotent_retry_precedes_current_product_lookup(self) -> None:
        retry = self.sql.index("important: the retry check happens before")
        lookup = self.sql.index("first-save freshness is checked")
        self.assertLess(retry, lookup)
        self.assertIn("request_payload_sha256", self.sql)

    def test_server_can_lookup_idempotency_key_without_client_table_access(self) -> None:
        self.assertIn(
            "forecast_recommendation_snapshot_by_request_v1", self.sql
        )
        self.assertIn("where snapshot.location_id_snapshot = v_profile.location_id", self.sql)
        self.assertIn("to service_role, postgres", self.sql)

    def test_receipts_require_explicit_eligible_stock_in_allocation(self) -> None:
        self.assertIn("match_forecast_recommendation_receipt_v1", self.sql)
        self.assertIn("transaction_type is distinct from 'stock_in'", self.sql)
        self.assertIn("receipt_is_not_an_eligible_later_restock", self.sql)
        self.assertIn("receipt_allocation_exceeds_received_quantity", self.sql)
        self.assertIn(
            "unique (recommendation_id, transaction_history_id_snapshot)", self.sql
        )
        self.assertIn("receipt_inventory_unit_cannot_be_verified", self.sql)
        self.assertIn("no pack conversion occurs here", self.sql)

    def test_tracking_has_explicit_pending_partial_and_reconciled_states(self) -> None:
        self.assertIn("'pending'", self.sql)
        self.assertIn("'partially_received'", self.sql)
        self.assertIn("'reconciled'", self.sql)
        self.assertIn("reconcile_forecast_recommendation_v1", self.sql)
        self.assertIn("else null", self.sql)

    def test_comparison_keeps_zero_recommendation_percentage_null(self) -> None:
        self.assertIn("when snapshot.recommended_restock_quantity > 0", self.sql)
        self.assertIn("else null", self.sql)
        self.assertIn("absolute_difference numeric", self.sql)
        self.assertIn("percentage_variance numeric", self.sql)
        self.assertIn("signed_quantity_difference numeric", self.sql)

    def test_proposal_never_mutates_inventory_or_movements(self) -> None:
        self.assertNotIn("update public.products", self.sql)
        self.assertNotIn("insert into public.transaction_history", self.sql)
        self.assertNotIn("update public.transaction_history", self.sql)
        self.assertNotIn("delete from public.transaction_history", self.sql)
        self.assertNotIn("create purchase order", self.sql)


if __name__ == "__main__":
    unittest.main()
