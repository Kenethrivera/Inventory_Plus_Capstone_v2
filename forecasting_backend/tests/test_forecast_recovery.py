import unittest
from unittest.mock import Mock, patch
from run_forecast_recovery import main, recover

ID = "11111111-1111-4111-8111-111111111111"


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.repo = Mock()
        self.args = dict(location_id=ID, job_id=ID, approval_id=ID, operator_id="1",
                         reason="publication_serialization_corrected", implementation_digest="a" * 64)

    def test_no_approval_never_calls_database(self):
        with self.assertRaises(ValueError):
            recover(self.repo, **self.args)
        self.repo._rpc.assert_not_called()

    def test_authorized_recovery_and_duplicate_return_same_job(self):
        for duplicate in (False, True):
            self.repo._rpc.return_value = dict(job_id=ID, status="queued", duplicate=duplicate)
            result = recover(self.repo, approved=True, **self.args)
            self.assertEqual(result["job_id"], ID)
            self.assertEqual(result["duplicate"], duplicate)
        payload = self.repo._rpc.call_args.args[1]
        self.assertEqual(payload["p_approval_id"], ID)
        self.assertEqual(payload["p_operator_id"], 1)
        self.assertIs(type(payload["p_operator_id"]), int)
        self.assertEqual(payload["p_expected_implementation_digest"], "a" * 64)

    def test_rejection_is_not_reported_as_success(self):
        self.repo._rpc.side_effect = RuntimeError("not eligible")
        with self.assertRaises(RuntimeError):
            recover(self.repo, approved=True, **self.args)

    def test_invalid_reason_never_calls_database(self):
        self.args["reason"] = "reset_everything"
        with self.assertRaises(ValueError):
            recover(self.repo, approved=True, **self.args)
        self.repo._rpc.assert_not_called()

    def test_bigint_operator_ids_are_not_truncated(self):
        self.repo._rpc.return_value = dict(job_id=ID, status="queued", duplicate=False)
        for value in (1, "1", "9007199254740993", "9223372036854775807"):
            with self.subTest(value=value):
                self.args["operator_id"] = value
                recover(self.repo, approved=True, **self.args)
                self.assertEqual(self.repo._rpc.call_args.args[1]["p_operator_id"], int(value))

    def test_invalid_operator_never_calls_database(self):
        for value in (ID, None, True, 1.0, "1.0", "1e0", "", "0", "-1",
                      "9223372036854775808"):
            with self.subTest(value=value):
                self.args["operator_id"] = value
                with self.assertRaises(ValueError):
                    recover(self.repo, approved=True, **self.args)
        self.repo._rpc.assert_not_called()

    def test_approval_reference_still_requires_uuid(self):
        self.args["approval_id"] = "1"
        with self.assertRaises(ValueError):
            recover(self.repo, approved=True, **self.args)
        self.repo._rpc.assert_not_called()

    def test_profile_authorization_rejection_propagates(self):
        self.repo._rpc.side_effect = PermissionError("Operator not authorized in scope")
        with self.assertRaises(PermissionError):
            recover(self.repo, approved=True, **self.args)

    def test_cli_accepts_admin_profile_one(self):
        args = ["run_forecast_recovery.py", "--approved", "--location-id", ID,
                "--job-id", ID, "--approval-id", ID, "--operator-id", "1",
                "--reason", "publication_serialization_corrected"]
        env = {"FORECAST_MAINTENANCE_LOCATIONS": ID,
               "SUPABASE_URL": "https://example.invalid", "SUPABASE_SECRET_KEY": "fixture"}
        with patch("sys.argv", args), patch.dict("os.environ", env, clear=True), \
                patch("run_forecast_recovery.load_dotenv"), \
                patch("run_forecast_recovery.SupabaseWorkerRepository", return_value=self.repo), \
                patch("run_forecast_recovery.recover", return_value={"status": "queued"}) as call, \
                patch("builtins.print"):
            main()
        self.assertEqual(call.call_args.kwargs["operator_id"], 1)
        self.assertEqual(call.call_args.kwargs["approval_id"], ID)
        self.repo.close.assert_called_once()
