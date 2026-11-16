"""Background-only historical evidence capture; no model or inventory execution."""
import time
import logging
from uuid import UUID
from .repository import SupabaseWorkerRepository, WorkerNetworkError, WorkerRpcError

LOG = logging.getLogger("inventory_plus.forecasting.restock_capture")


class RestockCaptureRepository(SupabaseWorkerRepository):
    def __init__(self, *, allowed_locations, **kwargs):
        super().__init__(**kwargs)
        self.allowed_locations = frozenset(str(UUID(x)) for x in allowed_locations)

    def capture(self, *, location_id, after=None, limit=25):
        location_id = str(UUID(location_id))
        if location_id not in self.allowed_locations:
            raise PermissionError("Restock capture location is not allowed")
        if not 1 <= limit <= 100:
            raise ValueError("Capture limit must be 1..100")
        result = self._rpc("capture_restock_forecast_evidence_v1", {
            "p_location_id": location_id,
            "p_after": str(UUID(after)) if after else None, "p_limit": limit,
        })
        if not isinstance(result, dict):
            raise ValueError("Invalid capture response")
        visited, captured, done = (result.get(k) for k in ("visited", "captured", "done"))
        if (type(visited) is not int or type(captured) is not int or type(done) is not bool
                or not 0 <= captured <= visited <= limit):
            raise ValueError("Invalid capture counts")
        if done != (visited < limit):
            raise ValueError("Capture completion does not match page size")
        if done:
            if result.get("next_after") is not None:
                raise ValueError("Completed sweep must reset cursor")
        elif visited != limit or not result.get("next_after"):
            raise ValueError("Incomplete sweep must advance cursor")
        else:
            cursor = UUID(result["next_after"])
            if after and cursor.int <= UUID(after).int:
                raise ValueError("Capture cursor did not advance")
        return result


def capture_cycle(repository, *, location_id, state, save, limit=25, max_pages=1,
                  max_attempts=3, wait=time.sleep, should_stop=lambda: False):
    """Checkpoint only committed RPC responses. Replaying a lost response is safe."""
    if not 1 <= max_pages <= 100:
        raise ValueError("Capture cycle must contain 1..100 pages")
    if not 1 <= max_attempts <= 5:
        raise ValueError("Capture attempts must be 1..5")
    if not isinstance(state, dict):
        raise ValueError("Capture checkpoint must be an object")
    if state.get(location_id) is not None:
        UUID(state[location_id])
    total = {"visited": 0, "captured": 0, "sweep_complete": False}
    for _ in range(max_pages):
        if should_stop():
            break
        for attempt in range(max_attempts):
            try:
                result = repository.capture(location_id=location_id, after=state.get(location_id), limit=limit)
                break
            except (WorkerNetworkError, WorkerRpcError) as error:
                retryable = isinstance(error, WorkerNetworkError) or error.retryable
                if not retryable or attempt + 1 == max_attempts:
                    raise
                delay = min(2 ** attempt, 30)
                LOG.warning("restock_capture_retry category=%s attempt=%d delay_seconds=%d",
                            type(error).__name__, attempt + 1, delay)
                wait(delay)
                if should_stop():
                    return total
        next_state = dict(state, **{location_id: result["next_after"]})
        save(next_state)
        state.update(next_state)
        total["visited"] += result["visited"]
        total["captured"] += result["captured"]
        if result["done"]:
            total["sweep_complete"] = True
            break
    return total
