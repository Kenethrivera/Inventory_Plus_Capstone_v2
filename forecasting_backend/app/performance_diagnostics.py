from __future__ import annotations

import logging
from contextlib import contextmanager
from contextvars import ContextVar
from time import perf_counter
from typing import Iterator
from uuid import uuid4


_logger = logging.getLogger("inventory_plus.forecasting.performance")
_request_context: ContextVar[tuple[bool, str | None]] = ContextVar(
    "forecast_performance_request", default=(False, None)
)


def _write(message: str, *arguments: object) -> None:
    try:
        _logger.info(message, *arguments)
    except Exception:
        # Diagnostic sinks must never change forecast or API behavior.
        return


def diagnostics_enabled(environment: str) -> bool:
    return environment.casefold() in {"development", "test"}


def configure_performance_logging(enabled: bool) -> None:
    """Expose diagnostic INFO messages only in explicitly enabled environments."""
    if not enabled:
        return
    if not _logger.handlers:
        handler = logging.StreamHandler()
        handler.setLevel(logging.INFO)
        handler.setFormatter(
            logging.Formatter(
                "%(asctime)s %(levelname)s %(name)s %(message)s"
            )
        )
        _logger.addHandler(handler)
    for handler in _logger.handlers:
        if handler.level == logging.NOTSET or handler.level > logging.INFO:
            handler.setLevel(logging.INFO)
    _logger.disabled = False
    _logger.setLevel(logging.INFO)
    _logger.propagate = False


@contextmanager
def performance_request(enabled: bool) -> Iterator[str | None]:
    request_id = uuid4().hex[:12] if enabled else None
    token = _request_context.set((enabled, request_id))
    try:
        yield request_id
    finally:
        _request_context.reset(token)


def start_timer(*, enabled: bool | None = None) -> float:
    context_enabled, _ = _request_context.get()
    should_time = context_enabled if enabled is None else enabled
    return perf_counter() if should_time else 0.0


def log_event(operation: str, **metrics: object) -> None:
    enabled, request_id = _request_context.get()
    if not enabled:
        return
    details = " ".join(f"{key}={value}" for key, value in metrics.items())
    _write("forecast_perf request_id=%s op=%s %s", request_id, operation, details)


def log_startup_duration(
    operation: str, started_at: float, *, enabled: bool, **metrics: object
) -> None:
    if not enabled:
        return
    duration_ms = (perf_counter() - started_at) * 1000
    details = " ".join(f"{key}={value}" for key, value in metrics.items())
    _write(
        "forecast_perf request_id=process-startup op=%s duration_ms=%.1f %s",
        operation,
        duration_ms,
        details,
    )


def log_duration(
    operation: str,
    started_at: float,
    *,
    enabled: bool | None = None,
    **metrics: object,
) -> None:
    context_enabled, request_id = _request_context.get()
    should_log = context_enabled if enabled is None else enabled
    if not should_log:
        return
    duration_ms = (perf_counter() - started_at) * 1000
    details = " ".join(f"{key}={value}" for key, value in metrics.items())
    _write(
        "forecast_perf request_id=%s op=%s duration_ms=%.1f %s",
        request_id or "process-startup",
        operation,
        duration_ms,
        details,
    )
