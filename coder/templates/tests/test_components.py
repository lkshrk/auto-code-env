import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "shared" / "components.py"
spec = importlib.util.spec_from_file_location("components", SCRIPT)
components = importlib.util.module_from_spec(spec)
spec.loader.exec_module(components)


class ComponentsTests(unittest.TestCase):
    def test_composition(self):
        result = components.configuration({
            "CODER_OMNI_STACKS": "go,python,k8s,go",
            "CODER_BACKEND": "docker",
        })
        self.assertEqual(result["stacks"], ["go", "python", "k8s"])
        self.assertEqual(result["agents"], [])
        self.assertNotIn("personalization", result)

    def test_invalid_configuration(self):
        # Stack/agent name validation (e.g. unknown stacks) is intentionally
        # NOT exercised here: it is dotfiles' coder-components.py resolver's
        # responsibility (exercised by that repository's own test suite),
        # not duplicated in this configuration() function. Only fields this
        # module actually owns (backend, agent-plugin pairing, boolean env
        # vars) are validated here.
        for env in [
            {"CODER_BACKEND": "production"},
            {"CODER_AGENT_PLUGINS": "1"},
            {"CODER_ENABLE_DIND": "yes"},
        ]:
            with self.subTest(env=env), self.assertRaises(ValueError):
                components.configuration(env)

    def test_empty_and_whitespace(self):
        result = components.configuration({"CODER_OMNI_STACKS": " , go, , python "})
        self.assertEqual(result["stacks"], ["go", "python"])

    def test_real_command_checks(self):
        result = components.check_commands({
            "python": [sys.executable, "--version"],
            "failure": [sys.executable, "-c", "raise SystemExit(7)"],
            "missing": ["coder-component-that-does-not-exist"],
            "timeout": [sys.executable, "-c", "import time; time.sleep(2)"],
        }, timeout=0.5)
        self.assertEqual(result, {"python": True, "failure": False, "missing": False, "timeout": False})

    def test_repository_markers_are_scoped_to_current_start(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_id = "00000000-0000-0000-0000-000000000000"
            new_id = "11111111-1111-1111-1111-111111111111"
            key = "a" * 64
            (root / old_id).mkdir()
            (root / old_id / key).touch()
            self.assertFalse(components.wait_repositories(root, [key], new_id, timeout=0))
            (root / new_id).mkdir()
            (root / new_id / key).touch()
            self.assertTrue(components.wait_repositories(root, [key], new_id, timeout=0))
            self.assertTrue(components.wait_repositories(root, [], "", timeout=0))
            with self.assertRaises(ValueError):
                components.wait_repositories(root, ["../escape"], new_id, timeout=0)

    def test_report_is_private_and_atomic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "ready.json"
            components.write_report(path, {"ready": False})
            components.write_report(path, {"ready": True})
            self.assertEqual(json.loads(path.read_text()), {"ready": True})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_bootstrap_package_detection_uses_real_dpkg(self):
        script = SCRIPT.with_name("install-base.sh")
        result = subprocess.run([
            "bash", "-c", 'source "$1"; coder_missing_packages bash coder-package-that-does-not-exist', "bash", str(script)
        ], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "coder-package-that-does-not-exist")

    def test_invalid_cli_has_no_ready_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ready.json"
            env = {"PATH": os.environ["PATH"], "CODER_BACKEND": "production"}
            result = subprocess.run([sys.executable, str(SCRIPT), "validate", "--report", str(path)], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(path.exists())

    def test_check_action_only_checks_docker_when_enabled(self):
        # Tool readiness is install-stacks.py's own final_check()'s job now
        # (see components.py's module docstring comment): the "check" action
        # here only re-verifies docker-engine reachability, a genuine live
        # daemon check that can't be folded into a package-install state.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ready.json"
            env = {"PATH": os.environ["PATH"]}
            result = subprocess.run([sys.executable, str(SCRIPT), "check", "--report", str(path)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(path.read_text())
            self.assertEqual(report["checks"], {})
            self.assertTrue(report["ready"])

    def test_check_action_reports_docker_engine_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ready.json"
            env = {"PATH": os.environ["PATH"], "CODER_ENABLE_DIND": "1"}
            result = subprocess.run([sys.executable, str(SCRIPT), "check", "--report", str(path)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(path.read_text())
            self.assertFalse(report["checks"]["docker-engine"])
            self.assertFalse(report["ready"])


if __name__ == "__main__":
    unittest.main()
