from __future__ import annotations

import argparse
import json
from pathlib import Path

from app.simulation.stage29b_replenishment_validation import (
    render_markdown,
    run_validation,
)


DEFAULT_OUTPUT = Path(__file__).resolve().parent / "simulation_reports" / "stage29b"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run isolated Stage 2.9B replenishment validation fixtures."
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    report = run_validation()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "stage29b_replenishment_validation.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.output_dir / "STAGE29B_REPLENISHMENT_VALIDATION.md").write_text(
        render_markdown(report),
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "decision": report["decision"],
                "passed": report["passed_count"],
                "failed": report["failed_count"],
                "output_dir": str(args.output_dir),
            },
            indent=2,
        )
    )
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

