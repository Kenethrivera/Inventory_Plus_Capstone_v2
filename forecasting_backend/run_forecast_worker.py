"""Run the trusted forecast worker independently from FastAPI/Uvicorn."""
from __future__ import annotations

import argparse
import logging
import json
import os
import signal
from threading import Event
from uuid import UUID

from dotenv import load_dotenv

from app.worker.repository import SupabaseWorkerRepository
from app.worker.runtime import ForecastJobWorker


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Process durable Inventory Plus forecast jobs")
    parser.add_argument("--job-id", help="Process only this queued job UUID")
    parser.add_argument("--max-jobs", type=int, default=None)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--lease-seconds", type=int, default=300)
    parser.add_argument("--poll-seconds", type=float, default=2.0)
    parser.add_argument("--once", action="store_true", help="Claim at most one job and exit")
    parser.add_argument("--identity-only", action="store_true", help="Print source/runtime identity without credentials or database access")
    return parser


def main() -> int:
    load_dotenv()
    args = _parser().parse_args()
    if args.identity_only:
        from app.api.implementation_manifest import implementation_manifest
        print(json.dumps(implementation_manifest(), indent=2, sort_keys=True))
        return 0
    logging.basicConfig(
        level=os.getenv("FORECAST_WORKER_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if args.job_id:
        try:
            args.job_id = str(UUID(args.job_id))
        except ValueError:
            raise SystemExit("--job-id must be a UUID")
        args.max_jobs = 1
    if args.once:
        args.max_jobs = min(args.max_jobs or 1, 1)
    if args.max_jobs is not None and args.max_jobs < 1:
        raise SystemExit("--max-jobs must be positive")
    if os.getenv("FORECAST_WORKER_ENABLED", "").strip().lower() not in {"1", "true", "yes", "on"}:
        raise SystemExit("Set FORECAST_WORKER_ENABLED=true to start the worker")

    url = os.getenv("SUPABASE_URL", "").strip()
    secret = (
        os.getenv("SUPABASE_SECRET_KEY", "").strip()
        or os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    )
    if not url or not secret:
        raise SystemExit("SUPABASE_URL and a server-only Supabase secret are required")
    try:
        timeout = float(os.getenv("FORECAST_UPSTREAM_TIMEOUT_SECONDS", "30"))
        repository = SupabaseWorkerRepository(
            url=url, secret_key=secret, timeout_seconds=timeout
        )
        worker = ForecastJobWorker(
            repository,
            lease_seconds=args.lease_seconds,
            poll_seconds=args.poll_seconds,
            concurrency=args.concurrency,
        )
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from error

    shutdown = Event()
    signal.signal(signal.SIGINT, lambda *_: shutdown.set())
    signal.signal(signal.SIGTERM, lambda *_: shutdown.set())
    try:
        counts = worker.run(
            shutdown=shutdown,
            max_jobs=args.max_jobs,
            job_id=args.job_id,
            stop_when_idle=args.once,
        )
        logging.getLogger("inventory_plus.forecasting.worker").info(
            "worker_stopped claimed=%d succeeded=%d failed=%d superseded=%d lease_lost=%d",
            counts["claimed"], counts["succeeded"], counts["failed"],
            counts["superseded"], counts["lease_lost"],
        )
    finally:
        repository.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
