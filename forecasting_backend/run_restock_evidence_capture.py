"""Opt-in supervised capture process, entirely independent of Restock Records GET."""
import argparse
import json
import logging
import os
from pathlib import Path
import signal
from threading import Event
from uuid import UUID
from dotenv import load_dotenv
from app.api.settings import ApiSettings
from app.worker.maintenance_state import exclusive_state, save_state
from app.worker.restock_capture import RestockCaptureRepository, capture_cycle


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", action="store_true", help="Explicitly permit evidence-only database writes")
    parser.add_argument("--location-id", required=True)
    parser.add_argument("--batch-size", type=int, default=25)
    parser.add_argument("--max-pages", type=int, default=1)
    parser.add_argument("--interval-seconds", type=int, default=0)
    parser.add_argument("--state-file", default=".runtime/restock-evidence-capture.json")
    args = parser.parse_args(argv)
    if not args.capture:
        parser.error("--capture is required; this process writes historical evidence")
    if not 1 <= args.batch_size <= 100 or not 1 <= args.max_pages <= 100:
        parser.error("Use batch-size and max-pages within 1..100")
    if args.interval_seconds != 0 and args.interval_seconds < 60:
        parser.error("Interval must be 0 (one bounded cycle) or at least 60 seconds")
    load_dotenv()
    settings = ApiSettings.from_environment()
    location = str(UUID(args.location_id))
    allowed = [x.strip() for x in os.getenv("FORECAST_MAINTENANCE_LOCATIONS", "").split(",") if x.strip()]
    if location not in {str(UUID(x)) for x in allowed}:
        parser.error("Location is outside FORECAST_MAINTENANCE_LOCATIONS")
    if settings.mode != "supabase":
        parser.error("FORECAST_API_MODE=supabase is required")
    repo = RestockCaptureRepository(allowed_locations=allowed, url=settings.supabase_url or "",
        secret_key=settings.supabase_secret_key or "", timeout_seconds=settings.request_timeout_seconds)
    stop = Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    logging.basicConfig(level=logging.INFO)
    path = Path(args.state_file).resolve()
    try:
        with exclusive_state(path):
            state = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
            logging.info("restock_capture_started batch_size=%d max_pages=%d interval_seconds=%d",
                         args.batch_size, args.max_pages, args.interval_seconds)
            while not stop.is_set():
                try:
                    report = capture_cycle(repo, location_id=location, state=state,
                        save=lambda value: save_state(path, value), limit=args.batch_size,
                        max_pages=args.max_pages, wait=stop.wait, should_stop=stop.is_set)
                    print(json.dumps(report), flush=True)
                    logging.info("restock_capture_cycle visited=%d captured=%d sweep_complete=%s",
                                 report["visited"], report["captured"], report["sweep_complete"])
                except Exception as error:
                    # Never log HTTP payloads, credentials or exception messages.
                    logging.error("restock_capture_failed category=%s", type(error).__name__)
                    if not args.interval_seconds:
                        return 1
                if not args.interval_seconds or stop.wait(args.interval_seconds):
                    break
    finally:
        repo.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
