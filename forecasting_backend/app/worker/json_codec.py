from __future__ import annotations

import json
import math
from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Any, Mapping


def json_safe(value: Any) -> Any:
    if isinstance(value, Enum):
        return json_safe(value.value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("forecast output contains a non-finite number")
        return value
    if isinstance(value, Mapping):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [json_safe(item) for item in value]
    if value is None or isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("forecast output contains a non-finite number")
        return value
    raise TypeError(f"unsupported forecast output value: {type(value).__name__}")


def encode_json(value: Any) -> bytes:
    """Encode Decimal values as exact JSON numbers, not quoted strings/floats."""
    value = json_safe(value)

    def encode(item: Any) -> str:
        if isinstance(item, Decimal):
            return format(item, "f")
        if isinstance(item, dict):
            return "{" + ",".join(
                f"{json.dumps(key, ensure_ascii=False)}:{encode(child)}"
                for key, child in item.items()
            ) + "}"
        if isinstance(item, list):
            return "[" + ",".join(encode(child) for child in item) + "]"
        return json.dumps(item, ensure_ascii=False, allow_nan=False, separators=(",", ":"))

    return encode(value).encode("utf-8")
