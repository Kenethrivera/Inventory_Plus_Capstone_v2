"""Local entrypoint: python run_api.py"""

import os

import uvicorn


def server_binding_from_environment() -> tuple[str, int]:
    host = os.getenv("FORECAST_API_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port_text = os.getenv("FORECAST_API_PORT", "8000").strip()
    try:
        port = int(port_text)
    except ValueError as error:
        raise RuntimeError("FORECAST_API_PORT must be an integer") from error
    if not 1 <= port <= 65535:
        raise RuntimeError("FORECAST_API_PORT must be between 1 and 65535")
    return host, port


if __name__ == "__main__":
    server_host, server_port = server_binding_from_environment()
    uvicorn.run(
        "app.api.main:create_app",
        factory=True,
        host=server_host,
        port=server_port,
    )
