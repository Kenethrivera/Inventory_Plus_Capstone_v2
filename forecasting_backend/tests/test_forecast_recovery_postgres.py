"""Opt-in tests for a disposable PostgreSQL clone. Never point at application data."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
from uuid import UUID, uuid4
from run_forecast_recovery import profile_id

ENABLED = os.getenv("FORECAST_RECOVERY_ISOLATED_CONFIRM") == "disposable"


@unittest.skipUnless(ENABLED, "Requires an explicitly configured disposable PostgreSQL clone")
class RecoveryPostgresTests(unittest.TestCase):
    def setUp(self):
        self.psql = shutil.which("psql")
        if not self.psql:
            self.fail("psql is required for isolated database tests")
        self.job = str(UUID(os.environ["FORECAST_RECOVERY_TEST_JOB"]))
        self.operator = profile_id(os.environ["FORECAST_RECOVERY_TEST_OPERATOR_ID"])
        self.env = dict(os.environ, PGDATABASE=os.environ["FORECAST_RECOVERY_ISOLATED_DSN"])

    def sql(self, query):
        result = subprocess.run([self.psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
                                input=query, text=True, capture_output=True, env=self.env, timeout=30)
        if result.returncode:
            self.fail("Isolated PostgreSQL check failed; inspect the clone's server log")
        return result.stdout.strip()

    def test_rollback_integrity_authorization_and_existing_retry(self):
        path = Path(__file__).resolve().parents[2] / "database/stage_6_forecast_recovery_validation.sql"
        script = path.read_text().replace(":'failed_job_id'", "'" + self.job + "'")
        script = script.replace(":'operator_id'", "'" + str(self.operator) + "'")
        self.sql(script)

    def test_concurrent_approvals_create_one_child_and_preserve_parent(self):
        before = self.sql(f"SELECT to_jsonb(j) FROM private.forecast_jobs j WHERE id='{self.job}';")
        job = json.loads(before)
        self.assertEqual(job["status"], "failed")
        # Two independent transactions target the same parent. Both commit in
        # this DISPOSABLE clone so the second can observe the first's child.
        def request(_):
            return json.loads(self.sql(
                "BEGIN; SELECT public.recover_forecast_job_v1("
                f"'{job['location_id']}','{self.job}','{uuid4()}',{self.operator},"
                f"'publication_serialization_corrected','{job['requested_implementation_digest']}'); COMMIT;"
            ))
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(request, range(2)))
        self.assertEqual(responses[0]["job_id"], responses[1]["job_id"])
        self.assertEqual(sorted(r["duplicate"] for r in responses), [False, True])
        self.assertEqual(before, self.sql(f"SELECT to_jsonb(j) FROM private.forecast_jobs j WHERE id='{self.job}';"))
        self.assertEqual(self.sql(f"SELECT count(*) FROM private.forecast_jobs WHERE recovery_parent_id='{self.job}';"), "1")
