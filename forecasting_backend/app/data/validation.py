from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Any
from uuid import UUID


class DemandDataError(ValueError):
    """Raised when persisted sales data cannot be interpreted safely."""


def required_identifier(value: Any, field: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise DemandDataError(f"{field} is required")
    try:
        UUID(text)
    except ValueError as error:
        raise DemandDataError(f"{field} must be a UUID") from error
    return text


def positive_decimal(value: Any, field: str) -> Decimal:
    try:
        number = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as error:
        raise DemandDataError(f"{field} must be numeric") from error
    if not number.is_finite() or number <= 0:
        raise DemandDataError(f"{field} must be greater than zero")
    return number


def parse_timestamp(value: Any, field: str) -> datetime:
    if isinstance(value, datetime):
        parsed = value
    else:
        text = str(value or "").strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError as error:
            raise DemandDataError(f"{field} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise DemandDataError(f"{field} must include a timezone")
    return parsed


def parse_date(value: Any, field: str) -> date:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    try:
        return date.fromisoformat(str(value))
    except ValueError as error:
        raise DemandDataError(f"{field} must be an ISO date") from error

