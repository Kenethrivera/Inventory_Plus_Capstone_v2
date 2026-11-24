from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import asdict
from datetime import date, datetime, timedelta
from hashlib import sha256
import logging
import json
import os
import socket
from threading import Event, Thread
import time
from typing import Any, Mapping
from uuid import uuid4

from app.api.contracts import DataUnavailableError
from app.api.job_materialization import (
    BUSINESS_TIMEZONE,
    DEFAULT_HORIZON_DAYS,
    DEFAULT_HISTORY_DAYS,
    _sha256_json,
    _implementation_digest,
    demand_input_digest,
    forecast_model_identity,
)
from app.api.service import ForecastAnalysisService
from app.forecasting.execution import (
    DemandForecastExecutionInput,
    DemandForecastExecutor,
)
from app.forecasting.series import prepare_history

from .bundle import build_output_bundle
from .repository import (
    SupabaseWorkerRepository,
    WorkerNetworkError,
    WorkerRpcError,
)


_LOGGER = logging.getLogger("inventory_plus.forecasting.worker")
_RETRY_DELAYS = (15, 60, 180)


class LeaseLost(RuntimeError):
    pass


class StaleInputs(RuntimeError):
    pass


class ForecastJobWorker:
    def __init__(
        self,
        repository: SupabaseWorkerRepository,
        *,
        lease_seconds: int = 300,
        poll_seconds: float = 2.0,
        concurrency: int = 1,
        service: ForecastAnalysisService | None = None,
    ) -> None:
        if not 30 <= lease_seconds <= 900:
            raise ValueError("lease_seconds must be between 30 and 900")
        if not 0.25 <= poll_seconds <= 60:
            raise ValueError("poll_seconds must be between 0.25 and 60")
        if not 1 <= concurrency <= 8:
            raise ValueError("concurrency must be between 1 and 8")
        self.repository = repository
        self.lease_seconds = lease_seconds
        self.poll_seconds = poll_seconds
        self.concurrency = concurrency
        self.service = service or ForecastAnalysisService(adapter=object())  # type: ignore[arg-type]
        self._implementation_digest = _implementation_digest()
        _LOGGER.info("forecast_worker_identity implementation_digest=%s", self._implementation_digest)
        self._model_identity = forecast_model_identity(self.service)

    def process_claim(self, job: Mapping[str, Any], shutdown: Event | None = None) -> str:
        job_id = str(job.get("id") or "")
        lease_token = str(job.get("lease_token") or "")
        if not job_id or not lease_token or job.get("status") != "running":
            raise DataUnavailableError("Claim RPC returned an incomplete running job")

        lost_lease = Event()
        heartbeat_stop = Event()
        heartbeat = Thread(
            target=self._heartbeat,
            args=(job_id, lease_token, heartbeat_stop, lost_lease),
            name=f"forecast-lease-{job_id[:8]}",
            daemon=True,
        )
        heartbeat.start()
        started = time.monotonic()
        try:
            if shutdown is not None and shutdown.is_set():
                self._fail_job(job, "worker_shutdown", retryable=True)
                return "released"
            self._validate_job_identity(job)
            frozen = self.repository.load_frozen_inputs(job)
            actual_digest = demand_input_digest(
                frozen.history, source_data_as_of=frozen.source_data_as_of
            )
            if actual_digest != str(job.get("request_input_digest")):
                raise StaleInputs("queued_input_digest_mismatch")
            expected_end = date.fromisoformat(str(job["as_of_business_date"])) - timedelta(days=1)
            if frozen.history.history_end != expected_end:
                raise StaleInputs("queued_history_bounds_mismatch")
            prepare_history(frozen.history)
            if lost_lease.is_set():
                raise LeaseLost("lease heartbeat reported loss")
            current = self.repository.renew_lease(
                job_id=job_id,
                lease_token=lease_token,
                lease_seconds=self.lease_seconds,
            )
            if current == "stale":
                _LOGGER.info("forecast_job_superseded job_ref=%s", _safe_ref(job_id))
                return "superseded"
            if current != "active":
                raise LeaseLost("worker no longer owns the forecast job lease")

            execution = self.service._forecast_executor.execute(
                DemandForecastExecutionInput(
                    history=frozen.history,
                    model=str(job["requested_model_key"]),
                    horizon_days=int(job["horizon_days"]),
                    as_of=_parse_datetime(job["as_of_at"]),
                    source_data_as_of=frozen.source_data_as_of,
                    preliminary_horizon_days=28,
                )
            )
            if lost_lease.is_set():
                raise LeaseLost("worker lost its lease while executing the model")
            bundle = build_output_bundle(
                execution=execution,
                job=job,
                history=frozen.history,
                implementation_digest=self._implementation_digest,
                producer_config_digests={
                    "blend": self._model_identity.config_digest,
                    "lightgbm": _digest_model_config(
                        "lightgbm", self.service._lightgbm.MODEL_VERSION,
                        asdict(self.service._lightgbm.config),
                    ),
                    "mean28": _digest_model_config(
                        "mean28", self.service._mean28.MODEL_VERSION,
                        {"lookback_days": self.service._mean28.LOOKBACK_DAYS},
                    ),
                    "seasonal_experimental": _digest_model_config(
                        "seasonal_experimental",
                        self.service._seasonal_experimental.MODEL_VERSION,
                        {
                            "config": asdict(self.service._seasonal_experimental.config),
                            "include_seasonal_features": self.service._seasonal_experimental.include_seasonal_features,
                            "zero_never_sold_forecasts": self.service._seasonal_experimental.zero_never_sold_forecasts,
                            "calendar_version": self.service._seasonal_experimental.resolver.CALENDAR_VERSION,
                        },
                    ),
                },
                recommendation_history=(
                    DemandForecastExecutor._bounded_history(
                        frozen.history, history_days=365
                    )
                    if str(job["requested_model_key"]) == "seasonal_experimental"
                    else frozen.history
                ),
                preliminary_history=(
                    DemandForecastExecutor._bounded_history(
                        frozen.history, history_days=365
                    )
                    if str(job["requested_model_key"]) == "seasonal_experimental"
                    else frozen.history
                ),
            )
            try:
                result = self.repository.publish(
                    job_id=job_id,
                    lease_token=lease_token,
                    output_bundle=bundle,
                )
            except (WorkerNetworkError, WorkerRpcError) as error:
                if isinstance(error, WorkerRpcError) and not error.retryable:
                    raise
                # A timed-out publication may already have committed. The RPC
                # returns the stored immutable result on replay, avoiding a
                # second model run and resolving the uncertain response.
                _LOGGER.warning("forecast_publish_response_uncertain job_ref=%s", _safe_ref(job_id))
                result = self.repository.publish(
                    job_id=job_id,
                    lease_token=lease_token,
                    output_bundle=bundle,
                )
            if result.get("status") == "superseded":
                return "superseded"
            if result.get("status") != "succeeded":
                raise DataUnavailableError("Forecast publication did not complete successfully")
            _LOGGER.info(
                "forecast_job_succeeded job_ref=%s elapsed_ms=%d result_ref=%s",
                _safe_ref(job_id),
                int((time.monotonic() - started) * 1000),
                _safe_ref(str(result.get("result_id") or result.get("id") or "")),
            )
            return "succeeded"
        except StaleInputs as error:
            try:
                self.repository.supersede(
                    job_id=job_id,
                    lease_token=lease_token,
                    error_code=str(error),
                )
            except Exception:
                _LOGGER.warning("forecast_job_supersede_failed job_ref=%s", _safe_ref(job_id))
            return "superseded"
        except LeaseLost:
            _LOGGER.info("forecast_job_lease_lost job_ref=%s", _safe_ref(job_id))
            return "lease_lost"
        except WorkerRpcError as error:
            if error.error_code == "40001":
                try:
                    self.repository.supersede(
                        job_id=job_id,
                        lease_token=lease_token,
                        error_code="forecast_inputs_superseded",
                    )
                except Exception:
                    _LOGGER.warning("forecast_job_supersede_failed job_ref=%s", _safe_ref(job_id))
                return "superseded"
            if error.error_code == "55000":
                return "lease_lost"
            retryable, code = classify_failure(error)
            self._fail_job(job, code, retryable=retryable)
            _LOGGER.warning(
                "forecast_job_failed job_ref=%s category=%s retryable=%s safe_error=%s",
                _safe_ref(job_id), type(error).__name__, retryable, code,
            )
            return "failed"
        except Exception as error:
            retryable, code = classify_failure(error)
            self._fail_job(job, code, retryable=retryable)
            _LOGGER.warning(
                "forecast_job_failed job_ref=%s category=%s retryable=%s safe_error=%s",
                _safe_ref(job_id),
                type(error).__name__,
                retryable,
                code,
            )
            return "failed"
        finally:
            heartbeat_stop.set()
            heartbeat.join(timeout=2.0)

    def run(
        self,
        *,
        shutdown: Event,
        max_jobs: int | None = None,
        job_id: str | None = None,
        stop_when_idle: bool = False,
    ) -> dict[str, int]:
        counts = {"claimed": 0, "succeeded": 0, "failed": 0, "superseded": 0, "lease_lost": 0}
        worker_id = f"{socket.gethostname()[:40]}:{os.getpid()}:{uuid4().hex[:12]}"
        active: dict[Future[str], None] = {}
        claimed = 0
        next_health_log = time.monotonic() + 300
        _LOGGER.info("forecast_worker_started concurrency=%d lease_seconds=%d poll_seconds=%s",
                     self.concurrency, self.lease_seconds, self.poll_seconds)
        with ThreadPoolExecutor(max_workers=self.concurrency, thread_name_prefix="forecast") as pool:
            while not shutdown.is_set():
                if time.monotonic() >= next_health_log:
                    _LOGGER.info("forecast_worker_health active=%d claimed=%d succeeded=%d failed=%d lease_lost=%d",
                                 len(active), counts["claimed"], counts["succeeded"],
                                 counts["failed"], counts["lease_lost"])
                    next_health_log = time.monotonic() + 300
                while len(active) < self.concurrency and not shutdown.is_set():
                    if max_jobs is not None and claimed >= max_jobs:
                        break
                    if job_id is not None and claimed >= 1:
                        break
                    try:
                        job = self.repository.claim_job(
                            worker_id=worker_id,
                            lease_seconds=self.lease_seconds,
                            job_id=job_id if claimed == 0 else None,
                        )
                    except Exception as error:
                        _LOGGER.warning("forecast_claim_failed category=%s", type(error).__name__)
                        break
                    if not job:
                        if job_id is not None:
                            _LOGGER.info("forecast_target_job_not_claimable job_ref=%s", _safe_ref(job_id))
                            shutdown.set()
                        break
                    claimed += 1
                    counts["claimed"] += 1
                    active[pool.submit(self.process_claim, job, shutdown)] = None
                if active:
                    completed = [future for future in active if future.done()]
                    if not completed:
                        shutdown.wait(0.2)
                        continue
                    for future in completed:
                        active.pop(future, None)
                        try:
                            outcome = future.result()
                        except Exception:
                            outcome = "failed"
                        if outcome in counts:
                            counts[outcome] += 1
                        if job_id is not None:
                            shutdown.set()
                elif max_jobs is not None and claimed >= max_jobs:
                    break
                elif stop_when_idle:
                    break
                else:
                    shutdown.wait(self.poll_seconds)
        return counts

    def _heartbeat(
        self, job_id: str, lease_token: str, stop: Event, lost: Event
    ) -> None:
        interval = max(5.0, self.lease_seconds / 3)
        while not stop.wait(interval):
            try:
                status = self.repository.renew_lease(
                    job_id=job_id,
                    lease_token=lease_token,
                    lease_seconds=self.lease_seconds,
                )
            except Exception as error:
                _LOGGER.warning(
                    "forecast_lease_heartbeat_error job_ref=%s category=%s",
                    _safe_ref(job_id),
                    type(error).__name__,
                )
                lost.set()
                return
            if status != "active":
                lost.set()
                return

    def _validate_job_identity(self, job: Mapping[str, Any]) -> None:
        model_key = str(job["requested_model_key"])
        horizon = int(job["horizon_days"])
        history_days = int(job["history_window_days"])
        versions = {
            "mean28": self.service._mean28.MODEL_VERSION,
            "lightgbm": self.service._lightgbm.MODEL_VERSION,
            "blend": self.service._blend.MODEL_VERSION,
            "seasonal_experimental": self.service._seasonal_experimental.MODEL_VERSION,
        }
        expected_history = 1095 if model_key == "seasonal_experimental" else DEFAULT_HISTORY_DAYS
        if model_key not in versions or not 1 <= horizon <= 90 or history_days != expected_history:
            raise DataUnavailableError("Queued forecast model identity is not supported by this worker")
        config_digest = forecast_model_identity(self.service, model_key).config_digest if horizon == DEFAULT_HORIZON_DAYS and history_days == expected_history else self._model_config_digest(model_key, horizon, history_days)
        checks = (
            str(job["requested_model_version"]) == versions[model_key],
            str(job["requested_model_config_digest"]) == config_digest,
            str(job["requested_implementation_digest"]) == self._implementation_digest,
        )
        if not all(checks):
            _LOGGER.error(
                "forecast_job_identity_mismatch job_ref=%s model=%s requested_implementation=%s worker_implementation=%s version_matches=%s config_matches=%s",
                _safe_ref(str(job.get("id", ""))), model_key,
                job["requested_implementation_digest"], self._implementation_digest,
                checks[0], checks[1],
            )
            raise DataUnavailableError("Queued forecast model configuration is not supported by this worker")

    def _model_config_digest(self, model_key: str, horizon: int, history_days: int) -> str:
        manifest = {
            "schema": "inventory-plus-model-config-v1",
            "requested_model": model_key,
            "requested_model_version": {
                "mean28": self.service._mean28.MODEL_VERSION,
                "lightgbm": self.service._lightgbm.MODEL_VERSION,
                "blend": self.service._blend.MODEL_VERSION,
                "seasonal_experimental": self.service._seasonal_experimental.MODEL_VERSION,
            }[model_key],
            "horizon_days": horizon,
            "history_window_days": history_days,
            "business_timezone": BUSINESS_TIMEZONE,
            "blend": asdict(self.service._blend.config),
            "lightgbm": asdict(self.service._lightgbm.config),
            "mean28_lookback_days": self.service._mean28.LOOKBACK_DAYS,
            "seasonal_experimental": {
                "config": asdict(self.service._seasonal_experimental.config),
                "include_seasonal_features": self.service._seasonal_experimental.include_seasonal_features,
                "zero_never_sold_forecasts": self.service._seasonal_experimental.zero_never_sold_forecasts,
                "calendar_version": self.service._seasonal_experimental.resolver.CALENDAR_VERSION,
            },
            "executor_auxiliary_outputs": {
                "recommendation_role": "requested_forecasts_for_nonseasonal_models",
                "seasonal_recommendation_model": "lightgbm",
                "preliminary_model": "lightgbm",
                "preliminary_horizon_days": 28,
            },
        }
        return _sha256_json(manifest)

    def _fail_job(self, job: Mapping[str, Any], code: str, *, retryable: bool) -> None:
        attempt = int(job.get("attempt_count") or 1)
        delay = _RETRY_DELAYS[min(max(attempt - 1, 0), len(_RETRY_DELAYS) - 1)]
        try:
            self.repository.fail(
                job_id=str(job["id"]),
                lease_token=str(job["lease_token"]),
                error_code=code,
                retryable=retryable,
                retry_delay_seconds=delay,
            )
        except Exception as error:
            _LOGGER.warning(
                "forecast_job_failure_recording_error job_ref=%s category=%s",
                _safe_ref(str(job["id"])),
                type(error).__name__,
            )


def classify_failure(error: Exception) -> tuple[bool, str]:
    if isinstance(error, WorkerNetworkError):
        return True, "transient_network_failure"
    if isinstance(error, WorkerRpcError):
        return error.retryable, "transient_rpc_failure" if error.retryable else "upstream_rpc_rejected"
    if isinstance(error, (TimeoutError, ConnectionError)):
        return True, "transient_io_failure"
    if isinstance(error, DataUnavailableError):
        return False, "forecast_input_unavailable"
    if isinstance(error, (ValueError, TypeError, KeyError, AssertionError)):
        return False, "forecast_execution_invalid"
    return False, "forecast_execution_failed"


def make_shutdown_event() -> Event:
    return Event()


def _parse_datetime(value: Any) -> datetime:
    parsed = value if isinstance(value, datetime) else datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("job timestamps must include timezone information")
    return parsed


def _safe_ref(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()[:12]


def _digest_model_config(model_key: str, version: str, config: Any) -> str:
    raw = json.dumps(
        {
            "schema": "inventory-plus-producer-config-v1",
            "model_key": model_key,
            "model_version": version,
            "config": config,
        },
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    ).encode("utf-8")
    return sha256(raw).hexdigest()
