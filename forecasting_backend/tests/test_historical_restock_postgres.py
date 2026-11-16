"""Opt-in LOCAL EMPTY disposable PostgreSQL integration, rolled back in full.

Set RESTOCK_ISOLATED_CONFIRM=disposable and RESTOCK_ISOLATED_DSN to a local
postgresql:// URL for an EMPTY throwaway database. Requires psql and a superuser.
No production endpoints are accepted. Dependencies mirror repository column contracts;
this is not a substitute for deployed metadata verification.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest
from urllib.parse import urlparse
from app.api.restock_records import validate_restock_rows
from tests.restock_contract_support import check_actual_dart_parser

ROOT = Path(__file__).resolve().parents[2]
AVAILABLE = shutil.which("psql") and os.getenv("RESTOCK_ISOLATED_CONFIRM") == "disposable"

@unittest.skipUnless(AVAILABLE, "Local psql and explicitly authorized empty disposable database unavailable")
class HistoricalRestockPostgresTests(unittest.TestCase):
    def test_migration_capture_permissions_immutability_read_and_dart_contract(self):
        dsn = os.environ.get("RESTOCK_ISOLATED_DSN", "")
        target = urlparse(dsn)
        self.assertIn(target.scheme, ("postgresql", "postgres"))
        self.assertIn(target.hostname, ("127.0.0.1", "localhost", "::1"), "Only local disposable PostgreSQL allowed")
        self.assertTrue(target.path.strip("/"), "Specify an empty disposable database")
        def body(path):
            text = path.read_text(encoding="utf-8")
            return re.sub(r"(?m)^(BEGIN|COMMIT|ROLLBACK);\s*$", "", text)
        scripts = [ROOT/"forecasting_backend/tests/sql/restock_contract_schema.sql",
                   ROOT/"database/stage_6g_applied_restock_records.sql",
                   ROOT/"database/stage_6g_historical_restock_matching.sql",
                   ROOT/"forecasting_backend/tests/sql/restock_contract_rows.sql",
                   ROOT/"database/stage_6g_historical_restock_matching_validation.sql"]
        sql = "BEGIN;\n" + "\n".join(body(p) for p in scripts) + "\nROLLBACK;"
        run = subprocess.run([shutil.which("psql"),"-X","-qAt","-v","ON_ERROR_STOP=1"],
            input=sql,text=True,capture_output=True,env=dict(os.environ,PGDATABASE=dsn),timeout=90)
        self.assertEqual(run.returncode,0,run.stderr)
        rows = json.loads(next(x for x in run.stdout.splitlines() if x.startswith("[{")))
        validate_restock_rows(rows)
        print(check_actual_dart_parser(rows))
