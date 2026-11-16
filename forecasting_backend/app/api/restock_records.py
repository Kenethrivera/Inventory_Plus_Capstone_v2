"""Validate the historical read contract without reconstructing or persisting anything."""
from decimal import Decimal, InvalidOperation
from uuid import UUID
from .contracts import DataUnavailableError

NUMERIC_FIELDS = ("predicted_demand", "available_inventory", "suggested_quantity",
                  "signed_quantity_difference", "absolute_difference", "training_history_days")
# Already-deployed Stage 6G omits difference/reliability fields. Preserve its
# read compatibility during rollout; the final RPC always supplies these keys.
HISTORICAL_FIELDS = ("predicted_demand", "available_inventory", "suggested_quantity",
                     "training_history_days", "forecast_period_start", "forecast_period_end",
                     "forecast_model", "forecast_version")


def validate_restock_rows(rows):
    if not isinstance(rows, list):
        raise DataUnavailableError("Invalid applied inventory response")
    seen = set()
    for row in rows:
        try:
            if not isinstance(row, dict):
                raise ValueError()
            if not isinstance(row.get("transaction_id"), str):
                raise ValueError()
            key = str(UUID(row["transaction_id"]))
            if key in seen:
                raise ValueError()
            seen.add(key)
            if any(field not in row for field in HISTORICAL_FIELDS):
                raise ValueError()
            assumptions = row.get("assumptions")
            if not isinstance(assumptions, list) or any(not isinstance(x, str) for x in assumptions):
                raise ValueError()
            for field in NUMERIC_FIELDS:
                value = row.get(field)
                if value is not None and (isinstance(value, bool) or not Decimal(str(value)).is_finite()):
                    raise ValueError()
            if row.get("reliability") not in (None, "normal", "provisional", "unavailable"):
                raise ValueError()
        except (KeyError, ValueError, TypeError, InvalidOperation) as error:
            raise DataUnavailableError("Invalid historical restock response contract") from error
    return rows
