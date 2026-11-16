"""Explicit operator-authorized recovery. Never run from maintenance or UI loading."""
import argparse
import json
import os
import re
from uuid import UUID

from dotenv import load_dotenv
from app.api.job_materialization import _implementation_digest
from app.worker.repository import SupabaseWorkerRepository

REASONS = ("publication_serialization_corrected", "dependency_corrected",
           "input_adapter_corrected", "execution_environment_corrected")


def profile_id(value):
    """Parse a real application profile ID, without UUID or float coercion."""
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError("Operator ID must be a positive BIGINT public.profiles.id")
    text = str(value).strip()
    if not re.fullmatch(r"[0-9]{1,19}", text):
        raise ValueError("Operator ID must be a positive BIGINT public.profiles.id")
    number = int(text)
    if not 1 <= number <= 9223372036854775807:
        raise ValueError("Operator ID must be a positive BIGINT public.profiles.id")
    return number


def recover(repository, *, location_id, job_id, approval_id, operator_id, reason,
            approved=False, implementation_digest=None):
    if not approved:
        raise ValueError("Explicit recovery approval is required")
    if reason not in REASONS:
        raise ValueError("Unsupported recovery reason")
    payload = {"p_location_id": str(UUID(location_id)), "p_job_id": str(UUID(job_id)),
               "p_approval_id": str(UUID(approval_id)), "p_operator_id": profile_id(operator_id),
               "p_reason": reason,
               "p_expected_implementation_digest": implementation_digest or _implementation_digest()}
    result = repository._rpc("recover_forecast_job_v1", payload)
    if not isinstance(result, dict) or not result.get("job_id") or "duplicate" not in result:
        raise ValueError("Recovery returned an invalid response")
    UUID(str(result["job_id"]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approved", action="store_true")
    for name in ("location-id", "job-id", "approval-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--operator-id", required=True, type=profile_id,
                        help="Existing Admin public.profiles.id (BIGINT), e.g. 1")
    parser.add_argument("--reason", choices=REASONS, required=True)
    args = parser.parse_args()
    if not args.approved:
        parser.error("--approved is required after the operator approves this recovery")
    load_dotenv()
    allowed = {x.strip() for x in os.getenv("FORECAST_MAINTENANCE_LOCATIONS", "").split(",")}
    if args.location_id not in allowed:
        parser.error("Location is outside the configured maintenance allowlist")
    repository = SupabaseWorkerRepository(
        url=os.environ["SUPABASE_URL"],
        secret_key=os.getenv("SUPABASE_SECRET_KEY") or os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        timeout_seconds=30,
    )
    try:
        print(json.dumps(recover(repository, **vars(args)), sort_keys=True))
    finally:
        repository.close()


if __name__ == "__main__":
    main()
