"""Bounded server-only preparation; no personal session and no model execution."""
from __future__ import annotations

from datetime import datetime
import logging
from types import SimpleNamespace
from uuid import UUID

from app.api.contracts import SessionProfile
from app.api.job_materialization import ForecastJobMaterializer, MANILA, SupabaseForecastJobRepository
from .repository import SupabaseWorkerRepository

LOG = logging.getLogger("inventory_plus.forecasting.maintenance")


class MaintenanceRepository(SupabaseForecastJobRepository):
    def __init__(self, *, allowed_locations, **kwargs):
        super().__init__(**kwargs)
        self.allowed_locations = frozenset(str(UUID(x)) for x in allowed_locations)
        if not self.allowed_locations:
            raise ValueError("An explicit maintenance location allowlist is required")

    def check_scope(self, location_id):
        if location_id not in self.allowed_locations:
            raise PermissionError("Maintenance location is not allowed")

    def page(self, *, location_id, business_date, identity, after=None, limit=10):
        self.check_scope(location_id)
        if not 1 <= limit <= 25:
            raise ValueError("Maintenance pages must contain 1 to 25 products")
        return self._rpc("forecast_maintenance_page_v1", {
            "p_location_id": location_id, "p_business_date": business_date.isoformat(),
            "p_config_digest": identity.config_digest,
            "p_implementation_digest": identity.implementation_digest,
            "p_after": after, "p_limit": limit,
        })

    def initialize_revisions(self, *, location_id, product_ids):
        self.check_scope(location_id)
        return super().initialize_revisions(location_id=location_id, product_ids=product_ids)

    def initial_page(self, *, location_id, business_date, identity, after=None, limit=10):
        self.check_scope(location_id)
        if not 1 <= limit <= 25:
            raise ValueError("Initial preparation pages must contain 1 to 25 products")
        return self._rpc("forecast_initial_pending_page_v1", {
            "p_location_id": location_id, "p_business_date": business_date.isoformat(),
            "p_after": after, "p_limit": limit,
        })

    def enqueue_jobs(self, *, location_id, jobs):
        self.check_scope(location_id)
        return self._rpc("forecast_maintenance_enqueue_v1", {
            "p_location_id": location_id, "p_jobs": list(jobs),
        })


class MaintenanceInputs(SupabaseWorkerRepository):
    """Reuse the worker's exact date normalization and frozen dataset builder.

    This sequential maintenance reader uses the separately authorized demand
    RPC, not a forged worker lease. Its one-location history cache is bounded
    and keyed by the complete scope revision fingerprint returned by SQL.
    """
    def load_frozen_inputs(self, job):
        self._maintenance_scope = job
        return super().load_frozen_inputs(job)

    def _rpc(self, function, payload):
        if function == "forecast_worker_daily_demand_v1":
            job = self._maintenance_scope
            return super()._rpc("forecast_maintenance_demand_v1", {
                "p_location_id": job["location_id"],
                "p_business_date": job["as_of_business_date"],
                "p_offset": payload["p_offset"], "p_limit": payload["p_limit"],
            })
        return super()._rpc(function, payload)


class MaintenanceCatalog:
    def __init__(self, inputs, location_id, rows, fingerprint):
        self.inputs, self.location_id = inputs, location_id
        self.rows = {str(row["id"]): row for row in rows}
        self.fingerprint = fingerprint

    def list_active_products(self, *, profile, session_token):
        if profile.location_id != self.location_id:
            raise PermissionError("Maintenance scope mismatch")
        return tuple(self.rows)

    def load_analysis_context(self, *, profile, session_token, product_id, now, history_days):
        if profile.location_id != self.location_id or product_id not in self.rows:
            raise PermissionError("Maintenance scope mismatch")
        frozen = self.inputs.load_frozen_inputs({
            "id": "maintenance", "lease_token": "not-a-worker-lease",
            "product_id": product_id, "location_id": self.location_id,
            "as_of_at": now.isoformat(), "as_of_business_date": now.astimezone(MANILA).date().isoformat(),
            "history_window_days": history_days, "scope_revision_vector": self.fingerprint,
        })
        return SimpleNamespace(history=frozen.history, source_data_as_of=frozen.source_data_as_of)


def prepare_page(*, repository, inputs, service, identity, location_id, now: datetime,
                 after=None, limit=10, enqueue=False, product_id=None, initial_only=False):
    """Advance past every inspected product, including failures; never starve later IDs."""
    read_page = repository.initial_page if initial_only else repository.page
    page = read_page(location_id=location_id, business_date=now.astimezone(MANILA).date(),
                           identity=identity, after=after, limit=limit)
    rows = page["items"]
    coverage = {state: int(page["coverage"].get(state, 0)) for state in
                ("current", "missing", "stale", "queued", "retry_pending", "running", "failed", "superseded", "cancelled", "excluded")}
    report = {"active_products": page["active_products"], "eligible_products": page["active_products"]-coverage["excluded"], "coverage": coverage,
              "visited": len(rows), "queued": 0, "duplicate": 0, "stale": 0,
              "skipped": 0, "preparation_errors": 0, "queued_job_ids": [],
              "next_cursor": str(rows[-1]["id"]) if rows else None}
    # These are terminal states for this exact logical identity. Re-enqueueing
    # them would only hit the unique job key forever. A changed revision/date
    # is reported as stale/missing by SQL and receives a new identity.
    candidates = [row for row in rows if row["state"] in {"missing", "stale"}
                  and (product_id is None or str(row["id"]) == product_id)]
    report["candidates"] = len(candidates)
    if not enqueue:
        return report
    catalog = MaintenanceCatalog(inputs, location_id, candidates, page["revision_fingerprint"])
    materializer = ForecastJobMaterializer(catalog=catalog, repository=repository, service=service)
    # This is an internal service identity, never a session accepted by public APIs.
    profile = SessionProfile("forecast-maintenance", "admin", location_id, "forecast-maintenance")
    for row in candidates:
        try:
            result = materializer.bootstrap(profile=profile, session_token="", now=now,
                                            product_id=str(row["id"]))
            if result.skipped:
                LOG.warning("maintenance_product_skipped product_id=%s", row["id"])
            for field in ("queued", "duplicate", "stale", "skipped"):
                report[field] += getattr(result, field)
            for job in getattr(result, "jobs", ()):
                if job.get("outcome") == "queued" and job.get("job_id"):
                    report["queued_job_ids"].append(str(job["job_id"]))
        except Exception as error:
            # Log only safe category and product scope, never payload or credentials.
            report["preparation_errors"] += 1
            LOG.error("maintenance_product_failed product_id=%s category=%s", row["id"], type(error).__name__)
    return report
