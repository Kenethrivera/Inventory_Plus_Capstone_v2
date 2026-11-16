"""Prepare a bounded rotation of forecast jobs; never execute models here.

Run this process under a supervisor with server-only credentials and an explicit location allowlist.
The default is a read-only preview. Job creation requires --enqueue.
"""
from __future__ import annotations

import argparse
import logging
import os
from datetime import datetime, timezone
from math import ceil
from uuid import UUID

from dotenv import load_dotenv

from app.api.job_materialization import (
    MAX_MAINTENANCE_BATCH,
)
from app.api.service import ForecastAnalysisService
from app.api.settings import ApiSettings


def select_product_batch(
    product_ids: tuple[str, ...], *, now: datetime, batch_size: int,
    rotation_minutes: int,
) -> tuple[str, ...]:
    """Select one stable batch per scheduler slot, cycling across the catalog."""
    if now.tzinfo is None or not 1 <= batch_size <= MAX_MAINTENANCE_BATCH:
        raise ValueError("A timezone-aware time and bounded batch size are required")
    if rotation_minutes < 1:
        raise ValueError("rotation_minutes must be positive")
    ordered = tuple(sorted(set(product_ids)))
    if not ordered:
        return ()
    batch_count = ceil(len(ordered) / batch_size)
    slot = int(now.timestamp() // (rotation_minutes * 60))
    start = (slot % batch_count) * batch_size
    return ordered[start : start + batch_size]


def main() -> int:
    import json
    import signal
    import time
    from pathlib import Path
    from threading import Event
    from app.worker.maintenance import MaintenanceRepository, MaintenanceInputs, prepare_page
    from app.worker.maintenance_state import exclusive_state, save_state
    from app.api.job_materialization import forecast_model_identity

    load_dotenv()
    parser = argparse.ArgumentParser(description="Server-only bounded forecast preparation (preview by default)")
    parser.add_argument("--enqueue", action="store_true")
    parser.add_argument("--location-id", required=True)
    parser.add_argument("--max-products", type=int, default=10)
    parser.add_argument("--max-pages", type=int, default=1)
    parser.add_argument("--product-id")
    parser.add_argument("--daily-policy", action="store_true",
                        help="Stage 6B: 03:00 Manila daily sweep plus prompt initial-product lane")
    parser.add_argument("--state-file", default=None)
    parser.add_argument("--interval-seconds", type=int, default=0, help="0 exits; otherwise repeat under a process supervisor")
    parser.add_argument("--report-json-stdout", action="store_true",
                        help="Emit each bounded report as one JSON line on stdout for automation")
    args = parser.parse_args()
    if not 1 <= args.max_products <= 25 or not 1 <= args.max_pages <= 100:
        parser.error("Use 1..25 products and 1..100 pages per cycle")
    if args.interval_seconds and args.interval_seconds < (30 if args.daily_policy else 60):
        parser.error("Maintenance interval must be at least 30s (daily policy) or 60s (legacy)")
    if args.daily_policy and args.product_id:
        parser.error("Use either daily policy or the explicit single-product path")
    location = str(UUID(args.location_id))
    product = str(UUID(args.product_id)) if args.product_id else None
    allowed = [x.strip() for x in os.getenv("FORECAST_MAINTENANCE_LOCATIONS", "").split(",") if x.strip()]
    settings = ApiSettings.from_environment()
    if settings.mode != "supabase" or not settings.forecast_job_materialization_enabled:
        raise SystemExit("Supabase forecast materialization must be enabled")
    kwargs = dict(url=settings.supabase_url or "", secret_key=settings.supabase_secret_key or "",
                  timeout_seconds=settings.request_timeout_seconds)
    repository = MaintenanceRepository(allowed_locations=allowed, **kwargs)
    repository.check_scope(location)
    inputs = MaintenanceInputs(**kwargs)
    service = ForecastAnalysisService(adapter=object())
    identity = forecast_model_identity(service)
    stop = Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    state_path = Path(args.state_file or (
        ".runtime/forecast-daily-policy.json" if args.daily_policy
        else ".runtime/forecast-maintenance.json"
    )).resolve()
    try:
        with exclusive_state(state_path):
            state = json.loads(state_path.read_text()) if state_path.exists() else {}
            while not stop.is_set():
                if args.daily_policy:
                    from app.worker.daily_policy import run_policy_cycle
                    started = time.monotonic()
                    reports = run_policy_cycle(
                        repository=repository, inputs=inputs, service=service, identity=identity,
                        location_id=location, state=state,
                        checkpoint=lambda value: save_state(state_path, value),
                        enqueue=args.enqueue, limit=args.max_products, max_pages=args.max_pages,
                    )
                    for report in reports:
                        report["cycle_duration_ms"] = round((time.monotonic()-started)*1000, 1)
                        logging.info("forecast_daily_policy %s", json.dumps(report, sort_keys=True))
                        if args.report_json_stdout:
                            print(json.dumps(report, sort_keys=True), flush=True)
                    if not args.interval_seconds or stop.wait(args.interval_seconds): break
                    continue
                for _ in range(args.max_pages):
                    if stop.is_set(): break
                    cursor = state.get(location)
                    if product:
                        cursor = str(UUID(int=max(0, UUID(product).int-1)))
                    started = time.monotonic()
                    report = prepare_page(repository=repository, inputs=inputs, service=service,
                        identity=identity, location_id=location, now=datetime.now(timezone.utc),
                        after=cursor, limit=1 if product else args.max_products,
                        product_id=product, enqueue=args.enqueue)
                    report["duration_ms"] = round((time.monotonic()-started)*1000, 1)
                    logging.info("forecast_maintenance %s", json.dumps(report, sort_keys=True))
                    if args.report_json_stdout:
                        print(json.dumps(report, sort_keys=True), flush=True)
                    finished = report["visited"] < (1 if product else args.max_products)
                    if args.enqueue and not product:
                        state[location] = None if finished else report["next_cursor"]
                        save_state(state_path, state)
                    if finished or product or not args.enqueue: break
                if not args.interval_seconds or stop.wait(args.interval_seconds): break
    finally:
        inputs.close()
        repository.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
