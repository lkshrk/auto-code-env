import importlib.metadata
import os
from pathlib import Path
import sys
import unittest


expected = os.environ["EXPECTED_OPENHANDS_VERSION"]
if expected not in {"1.44.0", "1.46.0"}:
    raise SystemExit("Unsupported contract version")
for package in ("openhands-agent-server", "openhands-sdk"):
    actual = importlib.metadata.version(package)
    print(f"{package}=={actual}", flush=True)
    if actual != expected:
        raise SystemExit(f"Expected {package}=={expected}, found {actual}")
if importlib.metadata.version("agent-client-protocol") != "0.10.1":
    raise SystemExit("Expected agent-client-protocol==0.10.1")
root = Path(__file__).resolve().parent
suite = unittest.TestSuite()
for pattern in ("test_backup_profile.py", "test_applier_contract.py", "test_settings_triggers.py"):
    tests = unittest.defaultTestLoader.discover(str(root), pattern=pattern)
    if not tests.countTestCases():
        raise SystemExit(f"No tests discovered for {pattern}")
    suite.addTests(tests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() and not result.skipped else 1)
