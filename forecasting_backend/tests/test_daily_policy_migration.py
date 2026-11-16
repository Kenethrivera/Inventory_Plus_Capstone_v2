"""Static SQL safeguards only; these tests do not execute PostgreSQL."""
from pathlib import Path
import re
import unittest


class DailyPolicyMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[2] / 'database/stage_6b_daily_forecast_policy.sql'
        cls.sql = re.sub(r'--[^\n]*', '', path.read_text(encoding='utf-8'))

    def body(self, name):
        match = re.search(r'CREATE (?:OR REPLACE )?FUNCTION ' + re.escape(name)
                          + r'\(.*?AS \$\$(.*?)END \$\$;', self.sql, re.S)
        self.assertIsNotNone(match)
        return match.group(1)

    def test_signal_reads_jobs_after_revision_lock_in_a_separate_statement(self):
        body = self.body('private.signal_initial_forecast_v1')
        lock_end = body.index('FOR UPDATE;') + len('FOR UPDATE;')
        self.assertNotIn('private.forecast_jobs', body[:lock_end])
        self.assertIn('ON CONFLICT(location_id,product_id) DO NOTHING;', body[:lock_end])
        self.assertIn('UPDATE private.forecast_input_revisions', body[lock_end:])
        self.assertIn('NOT EXISTS(', body[lock_end:])
        self.assertIn('j.location_id=NEW.location_id AND j.product_id=NEW.id', body[lock_end:])

    def test_intraday_events_are_recorded_without_changing_frozen_sales_revision(self):
        body = self.body('private.track_order_history_demand_revision_v1')
        self.assertIn("AT TIME ZONE 'Asia/Manila'", body)
        self.assertIn('o.business_date < business_today', body)
        self.assertIn('n.business_date < business_today', body)
        self.assertIn('GROUP BY location_id,product_id', body)
        self.assertIn('CASE WHEN changed.affects_frozen_history THEN 1 ELSE 0 END', body)
        self.assertIn('sales_event_revision=target.sales_event_revision+1', body)
        self.assertIn('IF FOUND AND changed.affects_frozen_history THEN', body)

    def test_atomic_restricted_read_rpc_and_no_recovery_or_result_redefinition(self):
        self.assertTrue(self.sql.strip().startswith('BEGIN;'))
        self.assertTrue(self.sql.strip().endswith('COMMIT;'))
        self.assertIn("SET LOCAL lock_timeout = '10s';", self.sql)
        signature = 'public.forecast_initial_pending_page_v1(uuid,date,uuid,integer)'
        self.assertIn(f'REVOKE ALL ON FUNCTION {signature} FROM PUBLIC,anon,authenticated;', self.sql)
        self.assertIn(f'GRANT EXECUTE ON FUNCTION {signature} TO service_role;', self.sql)
        self.assertIn('private.forecast_maintenance_scope_v1(p_location_id)', self.body('public.forecast_initial_pending_page_v1'))
        self.assertNotIn('forecast_execution_results', self.sql)
        self.assertNotIn('recover_forecast_job_v1', self.sql)
        self.assertNotIn('DISABLE ROW LEVEL SECURITY', self.sql)


if __name__ == '__main__':
    unittest.main()
