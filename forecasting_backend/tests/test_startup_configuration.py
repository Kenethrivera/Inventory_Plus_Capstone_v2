from __future__ import annotations

import unittest
from unittest.mock import patch

from run_api import server_binding_from_environment


class StartupConfigurationTests(unittest.TestCase):
    def test_defaults_to_windows_localhost_binding(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual(
                server_binding_from_environment(),
                ("127.0.0.1", 8000),
            )

    def test_host_and_port_can_be_exposed_for_device_testing(self) -> None:
        with patch.dict(
            "os.environ",
            {"FORECAST_API_HOST": "0.0.0.0", "FORECAST_API_PORT": "8765"},
            clear=True,
        ):
            self.assertEqual(
                server_binding_from_environment(),
                ("0.0.0.0", 8765),
            )

    def test_invalid_port_fails_before_server_start(self) -> None:
        for value in ("not-a-port", "0", "65536"):
            with self.subTest(value=value), patch.dict(
                "os.environ",
                {"FORECAST_API_PORT": value},
                clear=True,
            ):
                with self.assertRaisesRegex(RuntimeError, "FORECAST_API_PORT"):
                    server_binding_from_environment()


if __name__ == "__main__":
    unittest.main()
