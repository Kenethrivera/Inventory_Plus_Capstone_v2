"""Run only isolated daily-policy tests; never load runtime credentials or jobs."""
import unittest


def main():
    suite = unittest.defaultTestLoader.loadTestsFromName("tests.test_daily_forecast_policy")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful() and not result.skipped
    print("PASS: simulated 03:00 Manila workflow" if passed
          else "FAIL: simulated 03:00 Manila workflow", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
