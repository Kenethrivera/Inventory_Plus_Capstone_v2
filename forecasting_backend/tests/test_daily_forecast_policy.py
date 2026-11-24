"""Isolated clock-driven integration. No Supabase, real jobs, or clock changes."""
from copy import deepcopy
from dataclasses import replace
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal
from unittest.mock import Mock, patch
from uuid import UUID, uuid4
import unittest

from app.api.contracts import AnalysisContext, SessionProfile
from app.api.job_materialization import MANILA, forecast_model_identity
from app.api.service import ForecastAnalysisService
from app.api.snapshot_guidance import current_stock_analysis
from app.data.models import DailyDemand
from app.recommendations.models import (InventorySnapshot, InventoryBalanceBasis,
    SupplierPolicySnapshot, SupplierAvailability, RecommendationPolicy)
from app.worker.daily_policy import daily_due, run_policy_cycle
from app.worker.repository import SupabaseWorkerRepository
from app.worker.runtime import ForecastJobWorker
from tests.test_forecast_job_materialization import FakeRepository

LOCATION = '11111111-1111-4111-8111-111111111111'
PRODUCT = '22222222-2222-4222-8222-222222222222'
DAY = datetime(2026, 11, 14, tzinfo=MANILA)


class IsolatedStore(FakeRepository):
    """Transaction-boundary stand-in; SQL checks still need isolated PostgreSQL."""
    def __init__(self):
        super().__init__()
        self.products = {}
        self.pending = set()
        self.rows = []
        self.results = {}
        self.stock = Decimal('10')
        self.page_calls = 0

    def add_product(self, product=PRODUCT, initial=False):
        self.products[product] = dict(id=product, location_id=LOCATION, product_name='Fixture',
            sku='FIXTURE', unit='pcs', created_at=(DAY-timedelta(days=28)).isoformat())
        if initial: self.pending.add(product)

    def _page(self, *, business_date, after, limit, initial=False, **kwargs):
        if not initial: self.page_calls += 1
        model_key = kwargs['identity'].model_key
        rows = []
        for product in sorted(self.pending if initial else self.products):
            matches = [j for j in self.jobs.values() if j['product_id']==product
                       and j['as_of_business_date']==business_date.isoformat()
                       and j['requested_model_key']==model_key]
            state = ('current' if matches[-1]['status']=='succeeded' else matches[-1]['status']) if matches else 'missing'
            rows.append(dict(self.products[product], state=state))
        selected = [r for r in rows if after is None or r['id']>after][:limit]
        return dict(items=selected, active_products=len(rows), coverage={}, revision_fingerprint='isolated')

    def page(self, **kwargs): return self._page(**kwargs)
    def initial_page(self, **kwargs): return self._page(initial=True, **kwargs)

    def enqueue_jobs(self, **kwargs):
        result = super().enqueue_jobs(**kwargs)
        for row in result:
            job = next(j for j in reversed(list(self.jobs.values())) if j['product_id']==row['product_id'])
            job.setdefault('id', str(uuid4()))
            job.setdefault('status', 'queued')
            job.setdefault('attempt_count', 1)
            row['job_id'] = job['id']
            self.pending.discard(job['product_id'])
        return result

    def load_frozen_inputs(self, job):
        # Exercise the same frozen dataset builder as actual maintenance/worker.
        reader = object.__new__(SupabaseWorkerRepository)
        reader._product = lambda _: self.products[job['product_id']]
        cutoff = datetime.fromisoformat(job['as_of_at']).astimezone(MANILA).date()
        reader._location_demand = lambda _: tuple(r for r in self.rows
            if cutoff-timedelta(days=365) <= r.business_date < cutoff)
        return reader.load_frozen_inputs(job)

    def renew_lease(self, **kwargs): return 'active'
    def publish(self, *, job_id, lease_token, output_bundle):
        job = next(j for j in self.jobs.values() if j['id']==job_id)
        self.results.setdefault(job_id, deepcopy(output_bundle))
        job['status'] = 'succeeded'
        return dict(status='succeeded', result_id=job_id)
    def fail(self, **kwargs): raise AssertionError(f"Unexpected worker failure: {kwargs['error_code']}")
    def supersede(self, **kwargs): raise AssertionError(f"Unexpected stale job: {kwargs['error_code']}")


class DailyPolicyTests(unittest.TestCase):
    def setUp(self):
        self.db = IsolatedStore()
        self.db.add_product()
        for days in range(1,29):
            self.sale(DAY-timedelta(days=days), Decimal('4.25'))
        self.service = ForecastAnalysisService(adapter=object())
        self.identity = forecast_model_identity(self.service)
        self.state = {}
        self.worker = ForecastJobWorker(self.db, service=self.service)

    def sale(self, at, quantity):
        self.db.rows.append(DailyDemand(at.date(), LOCATION, PRODUCT, 'Fixture', 'pcs', quantity, 1, 'FIXTURE'))

    def cycle(self, at, **kwargs):
        return run_policy_cycle(repository=self.db, inputs=self.db, service=self.service,
            identity=self.identity, location_id=LOCATION, state=self.state,
            checkpoint=lambda state: None, enqueue=True, limit=5,
            clock=lambda: at, **kwargs)

    def process(self):
        for job in list(self.db.jobs.values()):
            if job['status']!='queued': continue
            job.update(status='running', lease_token=str(uuid4()))
            self.assertEqual(self.worker.process_claim(job), 'succeeded')

    def guidance(self, job, at):
        history = self.db.load_frozen_inputs(job).history
        context = AnalysisContext(history=history,
            inventory=InventorySnapshot(location_id=LOCATION,product_id=PRODUCT,unit='pcs',
                saleable_on_hand=self.db.stock,confirmed_on_order=None,unfulfilled_reservations=Decimal(0),
                backorders=None,max_capacity=None,balance_basis=InventoryBalanceBasis.NET_OF_RESERVATIONS,captured_at=at),
            supplier=SupplierPolicySnapshot(supplier_id='fixture',order_unit='pcs',lead_time_days=7,
                minimum_order_quantity=None,pack_size=None,availability=SupplierAvailability.AVAILABLE,captured_at=at),
            safety_stock=None,conversions=(),policy=RecommendationPolicy(version='fixture',review_period_days=7,
                max_forecast_age=timedelta(days=1),max_inventory_age=timedelta(days=1),
                max_supplier_age=timedelta(days=1),max_safety_stock_age=timedelta(days=1)),
            source_data_as_of=datetime.fromisoformat(job['as_of_at']),adapter_name='isolated')
        bundle = self.db.results[job['id']]
        snapshot = dict(bundle=bundle,product_id=PRODUCT,location_id=LOCATION,inventory_unit='pcs',
            horizon_days=28,history_window_days=365,forecast_start_date=bundle['execution']['forecast_start_date'],
            forecast_end_date=bundle['execution']['forecast_end_date'],created_at=job['as_of_at'],source_data_as_of=job['as_of_at'])
        with patch.object(self.service._forecast_executor, 'execute', side_effect=AssertionError('Read trained a model')):
            return current_stock_analysis(service=self.service, profile=SessionProfile('1','admin',LOCATION,'fixture'),
                context=context,snapshot=snapshot,now=at)

    def test_simulated_0300_daily_workflow_A_through_F(self):
        # Actual executor runs only its legitimate short-history fallback, not fitting.
        self.cycle(DAY.replace(hour=2,minute=59))
        self.assertFalse(self.db.jobs)
        self.cycle(DAY.replace(hour=3))
        self.assertEqual(len(self.db.jobs),1)
        self.process()
        job = next(iter(self.db.jobs.values()))
        original = deepcopy(self.db.results[job['id']])
        self.assertEqual(len(original['outputs']['requested_forecasts']['series'][0]['points']),28)
        self.assertTrue(original['outputs']['requested_forecasts']['fallback_reason'])
        self.cycle(DAY.replace(hour=3,minute=5))
        self.assertEqual(len(self.db.jobs),1)
        morning = self.guidance(job, DAY.replace(hour=9))
        self.sale(DAY.replace(hour=10), Decimal('2'))
        self.db.stock -= 2
        self.cycle(DAY.replace(hour=10))
        sold = self.guidance(job, DAY.replace(hour=10))
        self.assertEqual(len(self.db.jobs),1)
        self.assertEqual(original,self.db.results[job['id']])
        self.assertEqual(morning['forecast']['daily'],sold['forecast']['daily'])
        a=morning['preliminary_restocking_insight']; b=sold['preliminary_restocking_insight']
        self.assertEqual(b['available_inventory'],a['available_inventory']-2)
        self.assertEqual(b['suggested_restock_quantity'],a['suggested_restock_quantity']+2)
        self.db.stock += 5
        receipt = self.guidance(job, DAY.replace(hour=14))
        self.assertEqual(receipt['preliminary_restocking_insight']['suggested_restock_quantity'],b['suggested_restock_quantity']-5)
        self.cycle(DAY.replace(hour=14))
        tomorrow=DAY+timedelta(days=1,hours=3)
        self.cycle(tomorrow)
        self.assertEqual(len(self.db.jobs),2)
        self.process()
        new_job=list(self.db.jobs.values())[-1]
        self.assertNotEqual(job['request_input_digest'],new_job['request_input_digest'])
        self.assertEqual(new_job['as_of_business_date'],tomorrow.date().isoformat())
        history=self.db.load_frozen_inputs(new_job).history
        self.assertEqual(history.history_end,DAY.date())
        self.assertEqual(history.observations[-1].quantity,Decimal('2'))
        self.assertEqual(self.guidance(new_job,tomorrow)['preliminary_restocking_insight']['available_inventory'],13)

    def test_missed_run_and_restart_do_not_duplicate(self):
        self.cycle(DAY.replace(hour=11))
        self.state=deepcopy(self.state) # persisted/reloaded state
        self.cycle(DAY.replace(hour=12))
        self.assertEqual(len(self.db.jobs),1)
        self.state={} # crash before checkpoint: SQL identities still deduplicate
        self.cycle(DAY.replace(hour=12,minute=1))
        self.assertEqual(len(self.db.jobs),1)

    def test_lightgbm_daily_lane_is_separate_and_preserves_terminal_identity(self):
        lightgbm = forecast_model_identity(self.service, 'lightgbm')
        before = self.cycle(DAY.replace(hour=2, minute=59), lightgbm_identity=lightgbm)
        self.assertEqual(len(self.db.jobs), 0)
        self.assertFalse(any(row['lane']=='lightgbm' for row in before))
        reports = self.cycle(DAY.replace(hour=3), lightgbm_identity=lightgbm)
        self.assertEqual({row['lane'] for row in reports}, {'initial', 'daily', 'lightgbm'})
        self.assertEqual({job['requested_model_key'] for job in self.db.jobs.values()},
                         {'blend', 'lightgbm'})
        self.assertEqual(len(self.db.jobs), 2)
        failed = next(job for job in self.db.jobs.values()
                      if job['requested_model_key']=='lightgbm')
        failed['status'] = 'failed'
        self.state = {}  # Even a lost checkpoint cannot replace a terminal SQL identity.
        self.cycle(DAY.replace(hour=3, minute=1), lightgbm_identity=lightgbm)
        self.assertEqual(len(self.db.jobs), 2)
        tomorrow = DAY + timedelta(days=1)
        self.cycle(tomorrow.replace(hour=3), lightgbm_identity=lightgbm)
        self.assertEqual(len(self.db.jobs), 4)
        self.assertEqual(len([job for job in self.db.jobs.values()
                              if job['requested_model_key']=='lightgbm']), 2)

    def test_new_product_queues_on_next_tick_independent_of_daily_cursor(self):
        self.cycle(DAY.replace(hour=3))
        new=str(UUID(int=3))
        self.db.add_product(new,initial=True)
        page_calls=self.db.page_calls
        report=self.cycle(DAY.replace(hour=10,second=30))
        self.assertEqual(report[0]['queued'],1)
        self.assertEqual(self.db.page_calls,page_calls)
        self.process()
        job=next(j for j in self.db.jobs.values() if j['product_id']==new)
        point=self.db.results[job['id']]['outputs']['requested_forecasts']['series'][0]['points'][0]
        self.assertTrue(point['metadata']['is_cold_start'])
        self.assertEqual(self.db.load_frozen_inputs(job).history.observations,())

    def test_utc_clock_and_naive_clock(self):
        self.assertFalse(daily_due(DAY.replace(hour=2,minute=59).astimezone(timezone.utc)))
        self.assertTrue(daily_due(DAY.replace(hour=3).astimezone(timezone.utc)))
        with self.assertRaises(ValueError): daily_due(datetime(2026,11,14,3))

    def test_bounded_backfill_continues_and_preview_does_not_save(self):
        for n in range(1,12): self.db.add_product(str(UUID(int=n)))
        for _ in range(3): self.cycle(DAY.replace(hour=3))
        self.assertEqual(len(self.db.jobs),12)
        self.assertEqual(self.state['daily_policy_v1'][LOCATION]['completed_date'],DAY.date().isoformat())
        state={}; save=Mock()
        run_policy_cycle(repository=self.db,inputs=self.db,service=self.service,identity=self.identity,
            location_id=LOCATION,state=state,checkpoint=save,clock=lambda:DAY.replace(hour=3))
        self.assertEqual(state,{})
        save.assert_not_called()

    def test_failed_preparation_retries_after_backoff_without_stopping_other_products(self):
        original = self.db.load_frozen_inputs
        self.db.load_frozen_inputs = Mock(side_effect=RuntimeError('isolated unavailable input'))
        result = self.cycle(DAY.replace(hour=3))
        self.assertEqual(result[-1]['preparation_errors'],1)
        scope=self.state['daily_policy_v1'][LOCATION]
        self.assertNotIn('completed_date',scope)
        calls=self.db.page_calls
        self.cycle(DAY.replace(hour=3,minute=1))
        self.assertEqual(self.db.page_calls,calls)
        self.db.load_frozen_inputs=original
        self.cycle(DAY.replace(hour=3,minute=5))
        self.assertEqual(len(self.db.jobs),1)

    def test_initial_product_before_0300_does_not_trigger_existing_product_sweep(self):
        self.db.add_product(str(UUID(int=4)),initial=True)
        self.cycle(DAY.replace(hour=2,minute=59))
        self.assertEqual(len(self.db.jobs),1)
        self.assertEqual(self.db.page_calls,0)
        self.assertNotEqual(next(iter(self.db.jobs.values()))['product_id'],PRODUCT)

    def test_clock_rejects_no_timezone_before_query(self):
        with self.assertRaises(ValueError): self.cycle(datetime(2026,11,14,3))
        self.assertEqual(self.db.page_calls,0)


if __name__=='__main__': unittest.main(verbosity=2)
