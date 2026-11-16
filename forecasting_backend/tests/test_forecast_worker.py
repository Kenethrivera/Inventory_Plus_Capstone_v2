from __future__ import annotations

from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from threading import Event
from types import SimpleNamespace
import json
import unittest
from zoneinfo import ZoneInfo

from app.api.job_materialization import demand_input_digest, forecast_model_identity
from app.data.models import DailyDemand
from app.forecasting import (
    CalibratedBlendConfig,
    CalibratedBlendForecaster,
    HistoricalDemandDataset,
    LightGBMConfig,
    LightGBMForecaster,
    Mean28Forecaster,
    ForecastProduct,
)
from app.forecasting.execution import (
    DemandForecastExecution,
    DemandForecastExecutionInput,
    DemandForecastExecutor,
)
from app.worker.json_codec import encode_json
from app.worker.repository import (
    FrozenJobInputs,
    SupabaseWorkerRepository,
    WorkerRpcError,
)
from app.worker.runtime import ForecastJobWorker, classify_failure


MANILA = ZoneInfo("Asia/Manila")
LOCATION = "11111111-1111-4111-8111-111111111111"
PRODUCT = "31000000-0000-4000-8000-000000000001"
AS_OF = datetime(2026, 11, 13, tzinfo=MANILA)


def history_fixture() -> HistoricalDemandDataset:
    end = AS_OF.date() - timedelta(days=1)
    product = ForecastProduct(LOCATION, PRODUCT, "Test product", "pcs", "SKU-1")
    row = DailyDemand(end, LOCATION, PRODUCT, "Test product", "pcs", Decimal("4.25"), 1, "SKU-1")
    return HistoricalDemandDataset.from_real_observations(
        product=product, history_start=end - timedelta(days=27),
        history_end=end, observations=(row,),
    )


class FakeExecutor:
    def __init__(self) -> None:
        self.calls = []
        self.mean = Mean28Forecaster()

    def execute(self, inputs: DemandForecastExecutionInput) -> DemandForecastExecution:
        self.calls.append(inputs)
        values = tuple(self.mean.forecast(inputs.history, horizon_days=inputs.horizon_days))
        values = tuple(replace(v, metadata=replace(v.metadata, model_name="calibrated_lightgbm_mean28_blend")) for v in values)
        preliminary = tuple(self.mean.forecast(inputs.history, horizon_days=28))
        return DemandForecastExecution(
            requested_forecasts=values,
            recommendation_forecasts=values,
            preliminary_forecasts=preliminary,
            as_of=inputs.as_of,
            source_data_as_of=inputs.source_data_as_of,
        )


class FailingExecutor(FakeExecutor):
    def execute(self, inputs: DemandForecastExecutionInput) -> DemandForecastExecution:
        self.calls.append(inputs)
        from app.worker.repository import WorkerNetworkError

        raise WorkerNetworkError("temporary transport outage")


class BlendFallbackExecutor(FakeExecutor):
    def execute(self, inputs: DemandForecastExecutionInput) -> DemandForecastExecution:
        self.calls.append(inputs)
        mean_values = self.mean.forecast(inputs.history, horizon_days=inputs.horizon_days)
        fallback = tuple(CalibratedBlendForecaster._fallback(
            mean_values, "blend_unavailable:insufficient_training_history"
        ))
        return DemandForecastExecution(
            requested_forecasts=fallback,
            recommendation_forecasts=fallback,
            preliminary_forecasts=fallback,
            as_of=inputs.as_of,
            source_data_as_of=inputs.source_data_as_of,
        )


class FakeRepository:
    def __init__(self, history: HistoricalDemandDataset) -> None:
        self.history = history
        self.renew_status = "active"
        self.calls = []
        self.published = None
        self.publish_status = "succeeded"
        self.publish_calls = 0
        self.publish_network_error_once = False

    def load_frozen_inputs(self, job):
        return FrozenJobInputs(self.history, AS_OF, "revision-fingerprint")

    def renew_lease(self, **kwargs):
        self.calls.append(("renew", kwargs))
        return self.renew_status

    def publish(self, **kwargs):
        self.publish_calls += 1
        self.published = kwargs
        if self.publish_network_error_once and self.publish_calls == 1:
            from app.worker.repository import WorkerNetworkError

            raise WorkerNetworkError("response lost after commit")
        return {"result_id": "result-1", "status": self.publish_status}

    def supersede(self, **kwargs):
        self.calls.append(("supersede", kwargs))
        return True

    def fail(self, **kwargs):
        self.calls.append(("fail", kwargs))
        return "failed"


def make_service(executor):
    blend = CalibratedBlendForecaster(
        mean28=Mean28Forecaster(),
        lightgbm=LightGBMForecaster(mean28=Mean28Forecaster()),
    )
    lightgbm = LightGBMForecaster(mean28=Mean28Forecaster())
    return SimpleNamespace(
        _forecast_executor=executor,
        _blend=blend,
        _lightgbm=lightgbm,
        _mean28=Mean28Forecaster(),
        _seasonal_experimental=SimpleNamespace(
            MODEL_VERSION="1",
            config=LightGBMConfig(),
            include_seasonal_features=True,
            zero_never_sold_forecasts=True,
            resolver=SimpleNamespace(CALENDAR_VERSION="test-calendar-v1"),
        ),
    )


def make_job(history):
    identity = forecast_model_identity(make_service(FakeExecutor()))
    return {
        "id": "43d2a99e-a7e1-4e33-b667-b14d37be14cc",
        "lease_token": "c65cc408-20b2-4564-9ead-0f66e8f82b41",
        "status": "running",
        "requested_model_key": "blend",
        "requested_model_version": identity.model_version,
        "requested_model_config_digest": identity.config_digest,
        "requested_implementation_digest": identity.implementation_digest,
        "horizon_days": 28,
        "history_window_days": 365,
        "as_of_business_date": AS_OF.date().isoformat(),
        "as_of_at": AS_OF.isoformat(),
        "sales_revision": 0,
        "product_revision": 0,
        "request_input_digest": demand_input_digest(history, source_data_as_of=AS_OF),
        "attempt_count": 1,
    }


class ForecastWorkerTests(unittest.TestCase):
    def test_real_short_history_blend_fallback_publishes_explicit_reason(self):
        history = history_fixture()
        mean = Mean28Forecaster()
        lightgbm = LightGBMForecaster(mean28=mean)
        executor = DemandForecastExecutor(
            mean28=mean,
            lightgbm=lightgbm,
            blend=CalibratedBlendForecaster(mean28=mean, lightgbm=lightgbm),
            seasonal_experimental=None,  # Blend does not use this model.
        )
        execution = executor.execute(DemandForecastExecutionInput(
            history, "blend", 28, AS_OF, AS_OF, 28
        ))
        self.assertEqual(
            execution.requested_forecasts[0].metadata.model_name,
            "mean28_fallback",
        )
        from app.worker.bundle import build_output_bundle

        job = make_job(history)
        bundle = build_output_bundle(
            execution=execution,
            job=job,
            history=history,
            implementation_digest=job["requested_implementation_digest"],
            producer_config_digests={
                "blend": job["requested_model_config_digest"],
                "lightgbm": "a" * 64,
                "mean28": "b" * 64,
                "seasonal_experimental": "c" * 64,
            },
        )
        requested = bundle["outputs"]["requested_forecasts"]
        self.assertEqual(requested["series"][0]["producer"]["key"], "mean28")
        self.assertEqual(
            requested["fallback_reason"],
            execution.requested_forecasts[0].metadata.fallback_reason,
        )
        self.assertEqual(len(requested["series"][0]["points"]), 28)

    def test_blend_fallback_bundle_passes_requested_model_publication_rule(self):
        history = history_fixture()
        repository = FakeRepository(history)
        worker = ForecastJobWorker(
            repository, service=make_service(BlendFallbackExecutor())
        )
        self.assertEqual(worker.process_claim(make_job(history)), "succeeded")
        requested = repository.published["output_bundle"]["outputs"]["requested_forecasts"]
        self.assertEqual(requested["series"][0]["producer"]["key"], "mean28")
        self.assertEqual(
            requested["fallback_reason"],
            "blend_unavailable:insufficient_training_history",
        )

    def test_worker_digest_matches_materializer_for_database_utc_timestamp(self):
        history = history_fixture()
        job = make_job(history)
        job["as_of_at"] = AS_OF.astimezone(timezone.utc).isoformat()

        repository = object.__new__(SupabaseWorkerRepository)
        repository._product = lambda _job: {
            "id": PRODUCT,
            "location_id": LOCATION,
            "product_name": "Test product",
            "sku": "SKU-1",
            "unit": "pcs",
            "created_at": "2024-01-01T00:00:00+00:00",
        }
        repository._location_demand = lambda _job: tuple(history.observations)

        frozen = repository.load_frozen_inputs(job)
        materializer_history = HistoricalDemandDataset.from_real_observations(
            product=history.product,
            history_start=AS_OF.date() - timedelta(days=365),
            history_end=AS_OF.date() - timedelta(days=1),
            observations=history.observations,
        )

        self.assertEqual(frozen.source_data_as_of, AS_OF)
        self.assertEqual(
            demand_input_digest(frozen.history, source_data_as_of=frozen.source_data_as_of),
            demand_input_digest(materializer_history, source_data_as_of=AS_OF),
        )

    def test_complete_bundle_has_three_roles_and_decimal_json_number(self):
        history = history_fixture()
        executor = FakeExecutor()
        execution = executor.execute(DemandForecastExecutionInput(
            history, "blend", 28, AS_OF, AS_OF, 28
        ))
        job = make_job(history)
        from app.worker.bundle import build_output_bundle

        bundle = build_output_bundle(
            execution=execution, job=job, history=history,
            implementation_digest=job["requested_implementation_digest"],
            producer_config_digests={
                "blend": job["requested_model_config_digest"],
                "lightgbm": "a" * 64,
                "mean28": "b" * 64,
                "seasonal_experimental": "c" * 64,
            },
        )
        encoded = encode_json(bundle).decode("utf-8")
        parsed = json.loads(encoded, parse_float=Decimal)
        self.assertIsInstance(
            parsed["outputs"]["requested_forecasts"]["series"][0]["points"][0]["quantity"],
            Decimal,
        )
        self.assertEqual(set(parsed["outputs"]), {
            "requested_forecasts", "recommendation_forecasts", "preliminary_forecasts"
        })
        self.assertEqual(len(parsed["outputs"]["requested_forecasts"]["series"][0]["points"]), 28)

    def test_worker_dispatches_executor_and_publishes_bundle(self):
        history = history_fixture()
        executor = FakeExecutor()
        repository = FakeRepository(history)
        worker = ForecastJobWorker(repository, service=make_service(executor))
        result = worker.process_claim(make_job(history), Event())
        self.assertEqual(result, "succeeded")
        self.assertEqual(len(executor.calls), 1)
        self.assertEqual(executor.calls[0].model, "blend")
        self.assertEqual(executor.calls[0].horizon_days, 28)
        self.assertEqual(set(repository.published["output_bundle"]["outputs"]), {
            "requested_forecasts", "recommendation_forecasts", "preliminary_forecasts"
        })

    def test_digest_mismatch_supersedes_without_execution(self):
        history = history_fixture()
        executor = FakeExecutor()
        repository = FakeRepository(history)
        worker = ForecastJobWorker(repository, service=make_service(executor))
        job = dict(make_job(history), request_input_digest="0" * 64)
        self.assertEqual(worker.process_claim(job), "superseded")
        self.assertEqual(executor.calls, [])
        self.assertEqual(repository.calls[-1][0], "supersede")

    def test_lease_loss_prevents_execution_and_publication(self):
        history = history_fixture()
        executor = FakeExecutor()
        repository = FakeRepository(history)
        repository.renew_status = "lease_lost"
        worker = ForecastJobWorker(repository, service=make_service(executor))
        self.assertEqual(worker.process_claim(make_job(history)), "lease_lost")
        self.assertEqual(executor.calls, [])
        self.assertIsNone(repository.published)

    def test_source_revision_change_during_publish_is_not_reported_as_success(self):
        history = history_fixture()
        executor = FakeExecutor()
        repository = FakeRepository(history)
        repository.publish_status = "superseded"
        worker = ForecastJobWorker(repository, service=make_service(executor))
        self.assertEqual(worker.process_claim(make_job(history)), "superseded")

    def test_uncertain_publication_is_replayed_idempotently_without_second_execution(self):
        history = history_fixture()
        executor = FakeExecutor()
        repository = FakeRepository(history)
        repository.publish_network_error_once = True
        worker = ForecastJobWorker(repository, service=make_service(executor))
        self.assertEqual(worker.process_claim(make_job(history)), "succeeded")
        self.assertEqual(repository.publish_calls, 2)
        self.assertEqual(len(executor.calls), 1)

    def test_transient_rpc_error_is_retried_but_constraint_error_is_terminal(self):
        retry, retry_code = classify_failure(WorkerRpcError("publish", 503))
        terminal, terminal_code = classify_failure(WorkerRpcError("publish", 409))
        self.assertTrue(retry)
        self.assertEqual(retry_code, "transient_rpc_failure")
        self.assertFalse(terminal)
        self.assertEqual(terminal_code, "upstream_rpc_rejected")

    def test_network_failure_records_bounded_retry(self):
        history = history_fixture()
        repository = FakeRepository(history)
        worker = ForecastJobWorker(repository, service=make_service(FailingExecutor()))
        self.assertEqual(worker.process_claim(make_job(history)), "failed")
        failure = [call for call in repository.calls if call[0] == "fail"][-1][1]
        self.assertTrue(failure["retryable"])
        self.assertEqual(failure["retry_delay_seconds"], 15)

    def test_mean28_executor_matches_direct_forecaster_on_frozen_fixture(self):
        history = history_fixture()
        mean = Mean28Forecaster()
        executor = DemandForecastExecutor(
            mean28=mean,
            lightgbm=LightGBMForecaster(mean28=mean),
            blend=CalibratedBlendForecaster(
                mean28=mean, lightgbm=LightGBMForecaster(mean28=mean)
            ),
            seasonal_experimental=None,  # not selected by this test
        )
        expected = mean.forecast(history, horizon_days=28)
        actual = executor.execute(DemandForecastExecutionInput(
            history, "mean28", 28, AS_OF, AS_OF, 28
        )).requested_forecasts
        self.assertEqual(actual, tuple(expected))


if __name__ == "__main__":
    unittest.main()
