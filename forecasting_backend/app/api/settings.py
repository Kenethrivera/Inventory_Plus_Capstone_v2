from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import timedelta
from urllib.parse import urlparse


@dataclass(frozen=True)
class ApiSettings:
    mode: str
    supabase_url: str | None
    supabase_publishable_key: str | None
    request_timeout_seconds: float
    review_period_days: int
    policy_version: str
    synthetic_session_token: str
    deployment_environment: str = "production"
    synthetic_mode_enabled: bool = False
    cors_origins: tuple[str, ...] = ()
    supabase_secret_key: str | None = field(default=None, repr=False)
    recommendation_persistence_enabled: bool = False

    @classmethod
    def from_environment(cls) -> ApiSettings:
        mode = os.getenv("FORECAST_API_MODE", "supabase").strip().lower()
        if mode not in {"supabase", "synthetic"}:
            raise RuntimeError("FORECAST_API_MODE must be supabase or synthetic")
        deployment_environment = os.getenv(
            "FORECAST_DEPLOYMENT_ENV", "production"
        ).strip().lower()
        if deployment_environment not in {"production", "development", "test"}:
            raise RuntimeError(
                "FORECAST_DEPLOYMENT_ENV must be production, development, or test"
            )
        synthetic_token = os.getenv("FORECAST_SYNTHETIC_SESSION_TOKEN", "").strip()
        if mode == "synthetic":
            if deployment_environment not in {"development", "test"}:
                raise RuntimeError(
                    "Synthetic forecasting mode is forbidden in production"
                )
            if not synthetic_token:
                raise RuntimeError(
                    "FORECAST_SYNTHETIC_SESSION_TOKEN must be explicitly configured"
                )
        review_text = os.getenv("FORECAST_REVIEW_PERIOD_DAYS", "").strip()
        if mode == "supabase" and not review_text:
            raise RuntimeError(
                "FORECAST_REVIEW_PERIOD_DAYS must be explicitly configured"
            )
        review_days = int(review_text or "7")
        if review_days < 0:
            raise RuntimeError("FORECAST_REVIEW_PERIOD_DAYS cannot be negative")
        url = os.getenv("SUPABASE_URL", "").strip() or None
        key = os.getenv("SUPABASE_PUBLISHABLE_KEY", "").strip() or None
        if mode == "supabase" and (url is None or key is None):
            raise RuntimeError(
                "SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required"
            )
        persistence_enabled = _environment_bool(
            "FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED",
            default=False,
        )
        secret_key = (
            os.getenv("SUPABASE_SECRET_KEY", "").strip()
            or os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
            or None
        )
        if persistence_enabled:
            if mode != "supabase":
                raise RuntimeError(
                    "Recommendation persistence requires FORECAST_API_MODE=supabase"
                )
            if secret_key is None:
                raise RuntimeError(
                    "SUPABASE_SECRET_KEY is required when recommendation "
                    "persistence is enabled"
                )
            if secret_key == key or secret_key.startswith("sb_publishable_"):
                raise RuntimeError(
                    "Recommendation persistence requires a server-only "
                    "Supabase secret key"
                )
        cors_origins = tuple(
            origin.strip().rstrip("/")
            for origin in os.getenv("FORECAST_CORS_ORIGINS", "").split(",")
            if origin.strip()
        )
        for origin in cors_origins:
            parsed = urlparse(origin)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise RuntimeError(
                    "FORECAST_CORS_ORIGINS must contain absolute HTTP(S) origins"
                )
            if parsed.path not in {"", "/"} or parsed.params or parsed.query:
                raise RuntimeError(
                    "FORECAST_CORS_ORIGINS entries cannot contain paths or queries"
                )
        return cls(
            mode=mode,
            supabase_url=url,
            supabase_publishable_key=key,
            request_timeout_seconds=float(
                os.getenv("FORECAST_UPSTREAM_TIMEOUT_SECONDS", "15")
            ),
            review_period_days=review_days,
            policy_version=os.getenv(
                "FORECAST_POLICY_VERSION", "stage5d-periodic-review-v1"
            ).strip(),
            synthetic_session_token=synthetic_token,
            deployment_environment=deployment_environment,
            synthetic_mode_enabled=mode == "synthetic",
            cors_origins=cors_origins,
            supabase_secret_key=secret_key,
            recommendation_persistence_enabled=persistence_enabled,
        )

    @property
    def max_forecast_age(self) -> timedelta:
        return timedelta(hours=24)


def _environment_bool(name: str, *, default: bool) -> bool:
    value = os.getenv(name)
    if value is None or not value.strip():
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be true or false")
