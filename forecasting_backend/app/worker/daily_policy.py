"""Clock-injected orchestration of the existing bounded materializer.

No models, sessions, or private table writes here. The initial-pending RPC
requires Stage 6B. State is separate from previous trial cursors.
"""
from copy import deepcopy
from datetime import datetime, time, timezone

from app.api.job_materialization import MANILA
from .maintenance import prepare_page


def daily_due(now: datetime) -> bool:
    if now.tzinfo is None:
        raise ValueError("Scheduler clock must be timezone-aware")
    return now.astimezone(MANILA).time() >= time(3)


def run_policy_cycle(*, repository, inputs, service, identity, location_id,
                     state, checkpoint, enqueue=False, limit=10, max_pages=1,
                      clock=lambda: datetime.now(timezone.utc),
                      lightgbm_identity=None):
    """Poll indexed new-product signals, then advance today's daily sweep.

    Checkpoints follow each committed preparation page. A crash before saving
    replays only that page; SQL logical uniqueness remains authoritative.
    """
    if not 1 <= limit <= 25 or not 1 <= max_pages <= 100:
        raise ValueError("Invalid bounded scheduler page settings")
    if lightgbm_identity is not None and lightgbm_identity.model_key != "lightgbm":
        raise ValueError("The restock maintenance identity must be LightGBM")
    working = state if enqueue else deepcopy(state)
    scopes = working.setdefault("daily_policy_v1", {})
    scope = scopes.setdefault(location_id, {})
    reports = []

    def save():
        if enqueue:
            checkpoint(working)

    def prepare(kind, now, cursor):
        result = prepare_page(
            repository=repository, inputs=inputs, service=service, identity=identity,
            location_id=location_id, now=now, after=cursor, limit=limit,
            enqueue=enqueue, initial_only=kind == "initial",
        )
        result["lane"] = kind
        result["business_date"] = now.astimezone(MANILA).date().isoformat()
        reports.append(result)
        return result

    # Check urgent signals between bounded daily pages, not after a full catalog
    # traversal. A failed initial preparation remains pending and cursors advance.
    for _ in range(max_pages):
        now = clock()
        due = daily_due(now)
        day = now.astimezone(MANILA).date().isoformat()
        initial = prepare("initial", now, scope.get("initial_cursor"))
        scope["initial_cursor"] = initial["next_cursor"] if initial["visited"] == limit else None
        save()
        if not due or scope.get("completed_date") == day:
            break
        if scope.get("sweep_date") != day:
            scope.update(sweep_date=day, daily_cursor=None, sweep_errors=0, retry_after=0)
        if now.timestamp() < scope.get("retry_after", 0):
            break
        daily = prepare("daily", now, scope.get("daily_cursor"))
        scope["sweep_errors"] += daily["preparation_errors"] + daily["skipped"] + daily["stale"]
        if daily["visited"] < limit:
            scope["daily_cursor"] = None
            if not scope["sweep_errors"]:
                scope["completed_date"] = day
            else:
                # Preparation errors are not successful coverage. Retry a bounded
                # sweep after backoff; queued/terminal identities are skipped by SQL.
                scope.update(retry_after=now.timestamp() + 300, sweep_errors=0)
            save()
            break
        scope["daily_cursor"] = daily["next_cursor"]
        save()
        if not enqueue:
            break

    # This lane has its own durable cursor and retry delay. The existing Blend
    # sweep and prompt new-product lane above remain unchanged.
    if lightgbm_identity is not None:
        for _ in range(max_pages):
            now = clock()
            if not daily_due(now):
                break
            day = now.astimezone(MANILA).date().isoformat()
            if scope.get("lightgbm_completed_date") == day:
                break
            if scope.get("lightgbm_sweep_date") != day:
                scope.update(lightgbm_sweep_date=day, lightgbm_cursor=None,
                             lightgbm_errors=0, lightgbm_retry_after=0)
            if now.timestamp() < scope.get("lightgbm_retry_after", 0):
                break
            result = prepare_page(
                repository=repository, inputs=inputs, service=service,
                identity=lightgbm_identity, location_id=location_id, now=now,
                after=scope.get("lightgbm_cursor"), limit=limit,
                enqueue=enqueue,
            )
            result["lane"] = "lightgbm"
            result["business_date"] = day
            result["terminal_failures"] = result["coverage"]["failed"]
            reports.append(result)
            scope["lightgbm_errors"] += (
                result["preparation_errors"] + result["skipped"] + result["stale"]
            )
            if result["visited"] < limit:
                scope["lightgbm_cursor"] = None
                if not scope["lightgbm_errors"]:
                    # Completion means the catalogue was scanned, not that the
                    # worker has published every result or recovered failures.
                    scope["lightgbm_completed_date"] = day
                else:
                    scope.update(lightgbm_retry_after=now.timestamp() + 300,
                                 lightgbm_errors=0)
                save()
                break
            scope["lightgbm_cursor"] = result["next_cursor"]
            save()
            if not enqueue:
                break
    return reports
