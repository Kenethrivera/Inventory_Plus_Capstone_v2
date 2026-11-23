"""Read-only breakdown of the existing implementation identity.

This diagnostic deliberately lives outside the hashed modules. It reconstructs
and checks the existing digest; it never substitutes a different identity.
"""
from __future__ import annotations

import hashlib
import importlib.metadata
import inspect
import json
import platform
from pathlib import Path

from . import job_materialization as materialization


def implementation_manifest() -> dict[str, object]:
    names = (
        "ForecastAnalysisService", "ForecastJobMaterializer", "SupabaseForecastAdapter",
        "DemandForecastExecutor", "CalibratedBlendForecaster", "LightGBMForecaster",
        "Mean28Forecaster", "ProductSpecificSeasonalLightGBMForecaster",
        "PhilippineSeasonResolver", "RollingOriginBacktester", "prepare_history",
        "HistoricalDemandDataset", "DailyDemand", "DemandDataError",
        "canonical_history_input", "demand_input_digest",
    )
    root = Path(materialization.__file__).resolve().parents[2]
    paths = {Path(inspect.getsourcefile(getattr(materialization, name)) or "").resolve()
             for name in names}
    digest = hashlib.sha256()
    files = []
    for path in sorted(paths, key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
        content = path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
        files.append({"path": relative, "bytes": len(content),
                      "sha256": hashlib.sha256(content).hexdigest(),
                      "crlf_lines": content.count(b"\r\n")})
    runtime = {"python": platform.python_version(), **{
        name: importlib.metadata.version(name) for name in ("lightgbm", "numpy", "scikit-learn")}}
    digest.update(json.dumps(runtime, sort_keys=True, separators=(",", ":")).encode())
    identity = materialization._implementation_digest()
    if digest.hexdigest() != identity:
        raise RuntimeError("Identity diagnostic inputs differ from the production digest implementation")
    return {"implementation_digest": identity, "runtime": runtime, "files": files,
            "packages": {distribution.metadata["Name"]: distribution.version
                         for distribution in importlib.metadata.distributions()
                         if distribution.metadata["Name"]}}
