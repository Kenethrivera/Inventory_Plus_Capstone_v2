"""Focused process interruption tests; no live database or forecasting execution."""
from threading import Event
from unittest import TestCase
from unittest.mock import Mock
from app.worker.runtime import ForecastJobWorker
from app.worker.repository import WorkerNetworkError
from app.worker.restock_capture import capture_cycle

class ProcessRecoveryTests(TestCase):
    def worker(self, repository):
        worker = object.__new__(ForecastJobWorker)
        worker.repository = repository
        worker.concurrency, worker.lease_seconds, worker.poll_seconds = 1, 300, 0.25
        return worker

    def test_worker_claim_network_failure_then_supervisor_restart_rechecks_queue(self):
        repository = Mock()
        repository.claim_job.side_effect = [WorkerNetworkError("isolated outage"), None]
        first = self.worker(repository).run(shutdown=Event(), max_jobs=1, stop_when_idle=True)
        second = self.worker(repository).run(shutdown=Event(), max_jobs=1, stop_when_idle=True)
        self.assertEqual(first["claimed"], 0)
        self.assertEqual(second["claimed"], 0)
        self.assertEqual(repository.claim_job.call_count, 2)

    def test_capture_interrupt_keeps_last_committed_cursor(self):
        repository = Mock()
        cursor = "00000000-0000-0000-0000-000000000005"
        repository.capture.return_value = dict(visited=5,captured=1,done=False,next_after=cursor)
        checkpoints = []
        stop = Event()
        def save(state):
            checkpoints.append(dict(state))
            stop.set()
        state = {}
        report = capture_cycle(repository, location_id="loc",state=state,save=save,
                               limit=5,max_pages=10,should_stop=stop.is_set)
        self.assertEqual(report["captured"],1)
        self.assertEqual(repository.capture.call_count,1)
        self.assertEqual(checkpoints[-1]["loc"],cursor)
        self.assertEqual(state["loc"],cursor)
