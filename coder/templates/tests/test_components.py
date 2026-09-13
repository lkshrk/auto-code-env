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

    def test_personal_core_cannot_be_disabled(self):
        for env in ({}, {"CODER_PERSONALIZATION": "none"}, {"CODER_OMNI_STACKS": "go"}):
            commands = components.required_commands(components.configuration(env))
            self.assertTrue({"git", "zsh", "nvim", "tmux", "lazygit", "lefthook"} <= commands.keys())
            self.assertNotIn("node", commands)
            self.assertNotIn("cargo", commands)

    def test_invalid_configuration(self):
        for env in [
            {"CODER_OMNI_STACKS": "go,$(touch /tmp/invalid)"},
            {"CODER_AGENT_CLIENTS": "unknown"},
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

    def test_legacy_aliases_expand_to_all_required_components(self):
        config = components.configuration({"CODER_OMNI_STACKS": "infra,k8s,omni"})
        self.assertEqual(config["stacks"], components.ALIASES["infra"] + ["terminal-recording"])

    def test_bootstrap_package_detection_uses_real_dpkg(self):
        script = SCRIPT.with_name("install-base.sh")
        result = subprocess.run([
            "bash", "-c", 'source "$1"; coder_missing_packages bash coder-package-that-does-not-exist', "bash", str(script)
        ], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "coder-package-that-does-not-exist")

    def test_invalid_cli_has_no_ready_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ready.json"
            env = {"PATH": os.environ["PATH"], "CODER_OMNI_STACKS": "unknown"}
            result = subprocess.run([sys.executable, str(SCRIPT), "validate", "--report", str(path)], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
