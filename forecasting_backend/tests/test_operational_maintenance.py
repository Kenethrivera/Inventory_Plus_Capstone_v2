from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from uuid import UUID

from app.worker.maintenance import MaintenanceRepository, MaintenanceInputs, prepare_page
from app.worker.maintenance_state import exclusive_state, save_state
from app.worker.runtime import ForecastJobWorker


class OperationalMaintenanceTests(unittest.TestCase):
    def test_cursor_covers_38_products_and_one_failure_does_not_starve_later_products(self):
        ids = [str(UUID(int=i)) for i in range(1, 39)]
        visited = []
        repository = Mock()
        def page(**kwargs):
            rows = [x for x in ids if kwargs['after'] is None or x > kwargs['after']][:kwargs['limit']]
            return dict(items=[dict(id=x, state='missing') for x in rows],
                        active_products=38, coverage={'missing': 38}, revision_fingerprint='test')
        repository.page.side_effect = page
        materializer = Mock()
        def bootstrap(**kwargs):
            visited.append(kwargs['product_id'])
            if kwargs['product_id'] == ids[0]: raise RuntimeError('fixture failure')
            return SimpleNamespace(queued=1, duplicate=0, stale=0, skipped=0)
        materializer.bootstrap.side_effect = bootstrap
        cursor = None
        errors = queued = 0
        with patch('app.worker.maintenance.ForecastJobMaterializer', return_value=materializer):
            for _ in range(4):
                report = prepare_page(repository=repository, inputs=Mock(), service=Mock(), identity=Mock(),
                    location_id='location', now=datetime.now(timezone.utc), after=cursor, limit=10, enqueue=True)
                cursor = report['next_cursor']
                errors += report['preparation_errors']
                queued += report['queued']
        self.assertEqual(visited, ids)
        self.assertEqual((errors, queued), (1, 37))

    def test_current_queued_running_failed_excluded_are_not_reprepared(self):
        repository = Mock()
        repository.page.return_value = dict(items=[dict(id=str(i), state=s) for i,s in enumerate(
            ['current','queued','running','retry_pending','failed','excluded'])],
            active_products=6, coverage={}, revision_fingerprint='test')
        with patch('app.worker.maintenance.ForecastJobMaterializer') as materializer:
            result = prepare_page(repository=repository, inputs=Mock(), service=Mock(), identity=Mock(),
                location_id='location', now=datetime.now(timezone.utc), enqueue=True)
        self.assertEqual(result['candidates'], 0)
        materializer.return_value.bootstrap.assert_not_called()

    def test_terminal_states_are_reported_and_only_new_identity_is_prepared(self):
        repository = Mock()
        repository.page.return_value = dict(
            items=[
                dict(id="cancelled-product", state="cancelled"),
                dict(id="completed-product", state="current"),
                dict(id="queued-product", state="queued"),
                dict(id="running-product", state="running"),
                dict(id="failed-product", state="failed"),
                dict(id="superseded-product", state="superseded"),
                dict(id="new-revision-product", state="stale"),
            ],
            active_products=7,
            coverage={"cancelled": 1, "current": 1, "queued": 1, "running": 1,
                      "failed": 1, "superseded": 1, "stale": 1},
            revision_fingerprint="test",
        )
        materializer = Mock()
        materializer.bootstrap.return_value = SimpleNamespace(
            queued=1, duplicate=0, stale=0, skipped=0,
        )
        with patch(
            "app.worker.maintenance.ForecastJobMaterializer",
            return_value=materializer,
        ):
            report = prepare_page(
                repository=repository, inputs=Mock(), service=Mock(), identity=Mock(),
                location_id="location", now=datetime.now(timezone.utc), enqueue=True,
            )
        self.assertEqual(report["coverage"]["cancelled"], 1)
        self.assertEqual(report["coverage"]["current"], 1)
        self.assertEqual(report["coverage"]["queued"], 1)
        self.assertEqual(report["coverage"]["running"], 1)
        self.assertEqual(report["coverage"]["failed"], 1)
        self.assertEqual(report["coverage"]["superseded"], 1)
        self.assertEqual(report["candidates"], 1)
        self.assertEqual(report["queued"], 1)
        self.assertEqual(
            {call.kwargs["product_id"] for call in materializer.bootstrap.call_args_list},
            {"new-revision-product"},
        )

    def test_trial_report_lists_only_new_queued_job_ids(self):
        repository = Mock()
        repository.page.return_value = dict(
            items=[dict(id="one", state="missing"), dict(id="two", state="stale")],
            active_products=2, coverage={"missing": 1, "stale": 1},
            revision_fingerprint="test",
        )
        materializer = Mock()
        materializer.bootstrap.side_effect = [
            SimpleNamespace(queued=1, duplicate=0, stale=0, skipped=0,
                            jobs=({"outcome": "queued", "job_id": "new-job"},)),
            SimpleNamespace(queued=0, duplicate=1, stale=0, skipped=0,
                            jobs=({"outcome": "duplicate", "job_id": "old-job"},)),
        ]
        with patch("app.worker.maintenance.ForecastJobMaterializer", return_value=materializer):
            report = prepare_page(repository=repository, inputs=Mock(), service=Mock(),
                                  identity=Mock(), location_id="location",
                                  now=datetime.now(timezone.utc), limit=5, enqueue=True)
        self.assertEqual(report["queued_job_ids"], ["new-job"])
        self.assertEqual((report["queued"], report["duplicate"]), (1, 1))

    def test_preview_never_initializes_revisions_or_queues(self):
        repository = Mock()
        repository.page.return_value = dict(items=[dict(id='one', state='missing')],
            active_products=1, coverage={'missing':1}, revision_fingerprint='test')
        result = prepare_page(repository=repository, inputs=Mock(), service=Mock(), identity=Mock(),
            location_id='location', now=datetime.now(timezone.utc))
        self.assertEqual(result['candidates'], 1)
        repository.initialize_revisions.assert_not_called()
        repository.enqueue_jobs.assert_not_called()

    def test_location_allowlist_fails_before_rpc(self):
        repository = MaintenanceRepository(url='https://example.invalid', secret_key='sb_secret_fixture',
            timeout_seconds=1, allowed_locations=['11111111-1111-1111-1111-111111111111'])
        self.addCleanup(repository.close)
        with patch.object(repository, '_rpc') as rpc, self.assertRaises(PermissionError):
            repository.page(location_id='22222222-2222-2222-2222-222222222222',
                business_date=datetime.now().date(),identity=Mock())
        rpc.assert_not_called()

    def test_checkpoint_survives_restart_and_lock_releases(self):
        with TemporaryDirectory() as folder:
            path = Path(folder)/'cursor.json'
            with exclusive_state(path): save_state(path, {'location':'last-product'})
            with exclusive_state(path): self.assertIn('last-product',path.read_text())

    def test_once_worker_exits_when_queue_empty(self):
        worker = object.__new__(ForecastJobWorker)
        worker.repository = Mock()
        worker.repository.claim_job.return_value = None
        worker.concurrency, worker.lease_seconds, worker.poll_seconds = 1, 300, 2
        counts = worker.run(shutdown=Event(), max_jobs=1, stop_when_idle=True)
        self.assertEqual(counts['claimed'], 0)
        worker.repository.claim_job.assert_called_once()

    def test_maintenance_reads_use_separate_scope_rpc_not_forged_lease(self):
        repo = MaintenanceInputs(url='https://example.invalid',secret_key='sb_secret_fixture',timeout_seconds=1)
        self.addCleanup(repo.close)
        repo._maintenance_scope = {'location_id':'loc','as_of_business_date':'2026-11-14'}
        with patch('app.worker.repository.SupabaseWorkerRepository._rpc',return_value=[]) as rpc:
            repo._rpc('forecast_worker_daily_demand_v1',{'p_job_id':'unused','p_lease_token':'unused','p_offset':0,'p_limit':1000})
        self.assertEqual(rpc.call_args.args, ('forecast_maintenance_demand_v1', {
            'p_location_id':'loc','p_business_date':'2026-11-14','p_offset':0,'p_limit':1000}))

    def test_maintenance_and_worker_freeze_identical_history_and_digest(self):
        from app.api.job_materialization import demand_input_digest
        from app.worker.repository import SupabaseWorkerRepository
        from tests.test_forecast_worker import history_fixture, AS_OF, PRODUCT, LOCATION
        history = history_fixture()
        job = {'id':'unused','lease_token':'unused','location_id':LOCATION,'product_id':PRODUCT,
               'as_of_at':AS_OF.astimezone(timezone.utc).isoformat(),
               'as_of_business_date':AS_OF.date().isoformat(),'history_window_days':365,'scope_revision_vector':[]}
        product = {'id':PRODUCT,'location_id':LOCATION,'product_name':history.product.product_name,
                   'sku':history.product.sku,'unit':history.product.unit,
                   'created_at':datetime.combine(history.history_start,datetime.min.time(),tzinfo=AS_OF.tzinfo).isoformat()}
        args=dict(url='https://example.invalid',secret_key='sb_secret_fixture',timeout_seconds=1)
        worker = SupabaseWorkerRepository(**args)
        maintenance = MaintenanceInputs(**args)
        self.addCleanup(worker.close)
        self.addCleanup(maintenance.close)
        with patch.object(worker,'_product',return_value=product), patch.object(worker,'_location_demand',return_value=history.observations), patch.object(maintenance,'_product',return_value=product), patch.object(maintenance,'_location_demand',return_value=history.observations):
            first = worker.load_frozen_inputs(job)
            second = maintenance.load_frozen_inputs(job)
        self.assertEqual(first.history, second.history)
        self.assertEqual(demand_input_digest(first.history, source_data_as_of=first.source_data_as_of),
                         demand_input_digest(second.history, source_data_as_of=second.source_data_as_of))
