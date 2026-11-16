"""Static safety checks, not a substitute for isolated PostgreSQL execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "database/stage_6g_historical_restock_matching.sql").read_text(encoding="utf-8")

class HistoricalRestockMatchingContractTests(unittest.TestCase):
    def test_historical_scope_and_default_request_identity(self):
        for clause in ("er.created_at<t.created_at", "er.product_id=t.product_id",
                       "er.location_id=t.location_id", "AT TIME ZONE 'Asia/Manila'",
                       "er.requested_model_key='blend' AND er.horizon_days=28",
                       "ORDER BY er.created_at DESC,er.id DESC LIMIT 1"):
            self.assertIn(clause, SQL)

    def test_authorized_applied_transaction_and_stock_evidence(self):
        for clause in ("private.require_app_session_v1(p_session_token)",
                       "actor.role IS DISTINCT FROM 'admin'", "t.location_id=actor.location_id",
                       "a.status='approved'", "a.requested_quantity=t.quantity_change",
                       "t.transaction_type='stock_in'", "t.new_quantity-t.quantity_change"):
            self.assertIn(clause, SQL)

    def test_immutable_idempotent_evidence_and_original_snapshot_precedence(self):
        for clause in ("transaction_id uuid PRIMARY KEY", "ON CONFLICT (transaction_id) DO NOTHING",
                       "BEFORE UPDATE OR DELETE", "BEFORE TRUNCATE",
                       "CASE WHEN h.id IS NOT NULL THEN to_jsonb(h.predicted_demand) ELSE e.payload->'predicted_demand' END", "supporting_series jsonb NOT NULL"):
            self.assertIn(clause, SQL)
        self.assertNotIn("UPDATE public.", SQL)
        self.assertNotIn("INSERT INTO public.transaction_history", SQL)
        self.assertNotIn("CASCADE", SQL)

    def test_preliminary_role_and_invalid_evidence(self):
        for clause in ("preliminary_forecasts", "= 'no_history'", "<> 28", "p_day+27",
                       "greatest(0,ceil(demand-p_stock))", "EXCEPTION WHEN data_exception THEN RETURN NULL"):
            self.assertIn(clause, SQL)
        self.assertNotIn("outputs,requested_forecasts", SQL)

    def test_private_permissions_and_no_approval_hook(self):
        self.assertIn("SET search_path = pg_catalog", SQL)
        self.assertIn("ENABLE ROW LEVEL SECURITY", SQL)
        self.assertIn("FROM PUBLIC, anon, authenticated, service_role", SQL)
        self.assertNotIn("ON public.approval_requests", SQL)
        self.assertNotIn("ON public.transaction_history", SQL)

    def test_api_and_ui_keep_read_only_history(self):
        api = (ROOT / "forecasting_backend/app/api/main.py").read_text(encoding="utf-8")
        ui = (ROOT / "lib/ui/forecasting_page.dart").read_text(encoding="utf-8")
        self.assertIn('"read_only": True, "inventory_read_only": True', api)
        self.assertIn("item.evidenceLabel", ui)
        self.assertIn("Historical suggestion not recorded", ui)


class BackgroundBoundaryTests(unittest.TestCase):
    def test_read_function_contains_no_writes(self):
        body = SQL.split("CREATE OR REPLACE FUNCTION public.forecast_applied_restocks_v1", 1)[1]
        self.assertIn("STABLE SECURITY DEFINER", body)
        for forbidden in ("INSERT INTO", "UPDATE ", "DELETE ", "capture_restock_forecast_evidence_v1"):
            self.assertNotIn(forbidden, body)

    def test_capture_requires_successful_earlier_publication_and_bounded_scope(self):
        for clause in ("published.status='succeeded'", "published.completed_at<t.created_at",
                       "private.forecast_maintenance_scope_v1(p_location_id)",
                       "ORDER BY t.id LIMIT p_limit", "t.id=ANY(v_ids)",
                       "TO service_role", "FROM PUBLIC,anon,authenticated"):
            self.assertIn(clause, SQL)

if __name__ == "__main__":
    unittest.main()
