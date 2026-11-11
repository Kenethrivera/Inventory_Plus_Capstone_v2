from __future__ import annotations

import argparse
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from app.simulation.seasonal_backtest import FullInventorySeasonalBacktester


def _jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the experimental season-aware full-inventory backtest"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("simulation_reports/seasonal_candidate_676d.json"),
    )
    args = parser.parse_args()
    report = _jsonable(FullInventorySeasonalBacktester().run())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(report["overall"], indent=2, sort_keys=True))
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
