import unittest
from unittest.mock import Mock
from app.worker.restock_capture import RestockCaptureRepository, capture_cycle

LOCATION = "11111111-1111-1111-1111-111111111111"
CURSOR = "00000000-0000-0000-0000-000000000005"

class RestockCaptureTests(unittest.TestCase):
    def repository(self):
        repo = RestockCaptureRepository(allowed_locations=[LOCATION], url="http://unused.invalid",
                                       secret_key="sb_secret_test", timeout_seconds=1)
        self.addCleanup(repo.close)
        return repo

    def test_scope_denied_without_rpc(self):
        repo = self.repository()
        repo._rpc = Mock()
        with self.assertRaises(PermissionError):
            repo.capture(location_id="22222222-2222-2222-2222-222222222222")
        repo._rpc.assert_not_called()

    def test_payload_and_response(self):
        repo = self.repository()
        repo._rpc = Mock(return_value=dict(visited=1, captured=1, done=True, next_after=None))
        self.assertEqual(repo.capture(location_id=LOCATION)["captured"], 1)
        self.assertEqual(repo._rpc.call_args.args[1]["p_limit"], 25)

    def test_checkpoint_and_resume(self):
        repo = Mock()
        repo.capture.side_effect = [dict(visited=5,captured=2,done=False,next_after=CURSOR),
                                    dict(visited=1,captured=0,done=True,next_after=None)]
        state = {}; save = Mock()
        result = capture_cycle(repo, location_id=LOCATION, state=state, save=save,limit=5,max_pages=2)
        self.assertEqual(result, dict(visited=6,captured=2,sweep_complete=True))
        self.assertEqual(repo.capture.call_args_list[1].kwargs["after"], CURSOR)
        self.assertIsNone(state[LOCATION])
        self.assertEqual(save.call_count, 2)

    def test_failure_does_not_advance_checkpoint(self):
        repo = Mock(); repo.capture.side_effect = RuntimeError("lost response")
        state = {LOCATION: CURSOR}; save = Mock()
        with self.assertRaises(RuntimeError):
            capture_cycle(repo,location_id=LOCATION,state=state,save=save)
        self.assertEqual(state[LOCATION], CURSOR)
        save.assert_not_called()

    def test_repeated_empty_sweep_is_bounded(self):
        repo = Mock(); repo.capture.return_value = dict(visited=0,captured=0,done=True,next_after=None)
        state = {}
        for _ in range(2):
            self.assertEqual(capture_cycle(repo,location_id=LOCATION,state=state,save=Mock(),max_pages=100)["captured"],0)
        self.assertEqual(repo.capture.call_count,2)

    def test_invalid_or_nonadvancing_response_rejected(self):
        repo = self.repository()
        repo._rpc = Mock(return_value=dict(visited=25,captured=1,done=False,next_after=CURSOR))
        with self.assertRaises(ValueError):
            repo.capture(location_id=LOCATION,after=CURSOR)
        repo._rpc.return_value = dict(visited=0,captured=1,done=True,next_after=None)
        with self.assertRaises(ValueError):
            repo.capture(location_id=LOCATION)

    def test_network_retry_reuses_same_cursor(self):
        from app.worker.repository import WorkerNetworkError
        repo = Mock()
        repo.capture.side_effect = [WorkerNetworkError("timeout"),
            dict(visited=0,captured=0,done=True,next_after=None)]
        state = {LOCATION: CURSOR}; wait = Mock()
        with self.assertLogs("inventory_plus.forecasting.restock_capture",level="WARNING") as logs:
            capture_cycle(repo,location_id=LOCATION,state=state,save=Mock(),wait=wait)
        self.assertIn("restock_capture_retry", logs.output[0])
        self.assertIn("WorkerNetworkError", logs.output[0])
        self.assertEqual(repo.capture.call_args_list[0], repo.capture.call_args_list[1])
        wait.assert_called_once_with(1)

    def test_permanent_permission_failure_is_not_retried(self):
        from app.worker.repository import WorkerRpcError
        repo = Mock(); repo.capture.side_effect = WorkerRpcError("capture",403,"42501")
        with self.assertRaises(WorkerRpcError):
            capture_cycle(repo,location_id=LOCATION,state={},save=Mock(),wait=Mock())
        self.assertEqual(repo.capture.call_count,1)

    def test_retry_budget_is_bounded(self):
        from app.worker.repository import WorkerNetworkError
        repo = Mock(); repo.capture.side_effect = WorkerNetworkError("timeout")
        with self.assertRaises(WorkerNetworkError):
            capture_cycle(repo,location_id=LOCATION,state={},save=Mock(),wait=Mock(),max_attempts=3)
        self.assertEqual(repo.capture.call_count,3)

    def test_durable_restart_and_failed_checkpoint_replay(self):
        import tempfile, json
        from pathlib import Path
        from app.worker.maintenance_state import save_state
        repo = Mock(); repo.capture.return_value = dict(visited=5,captured=1,done=False,next_after=CURSOR)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"capture.json"
            capture_cycle(repo,location_id=LOCATION,state={},save=lambda s: save_state(path,s),limit=5)
            restarted = json.loads(path.read_text())
            repo.capture.return_value = dict(visited=0,captured=0,done=True,next_after=None)
            capture_cycle(repo,location_id=LOCATION,state=restarted,save=lambda s: save_state(path,s),limit=5)
            self.assertEqual(repo.capture.call_args.kwargs["after"], CURSOR)
            self.assertIsNone(json.loads(path.read_text())[LOCATION])

    def test_runner_invokes_capture_once_and_closes_repository(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        import tempfile
        from run_restock_evidence_capture import main
        repo = Mock(); repo.capture.return_value = dict(visited=0,captured=0,done=True,next_after=None)
        settings = SimpleNamespace(mode="supabase",supabase_url="https://unused.invalid",
                                   supabase_secret_key="sb_secret_fixture",request_timeout_seconds=1)
        with tempfile.TemporaryDirectory() as directory, \
             patch("run_restock_evidence_capture.load_dotenv"), \
             patch("run_restock_evidence_capture.signal.signal"), \
             patch("run_restock_evidence_capture.ApiSettings.from_environment",return_value=settings), \
             patch("run_restock_evidence_capture.RestockCaptureRepository",return_value=repo), \
             patch.dict("os.environ",{"FORECAST_MAINTENANCE_LOCATIONS":LOCATION}):
            self.assertEqual(main(["--capture","--location-id",LOCATION,"--state-file",directory+"/state.json"]),0)
        repo.capture.assert_called_once()
        repo.close.assert_called_once()
