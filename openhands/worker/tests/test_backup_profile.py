"""Real settings models plus a loopback transport fixture; no persisted user data."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from openhands.agent_server.persistence import PersistedSettings
from openhands.sdk.settings import ACPAgentSettings


SCRIPT = Path(__file__).resolve().parents[2] / "profiles" / "backup-profile.py"
SPEC = importlib.util.spec_from_file_location("backup_profile", SCRIPT)
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def dump(settings):
    return settings.model_dump(mode="json", context={"expose_secrets": "plaintext"})


def snapshot(settings):
    data = dump(settings)
    return dict(format=backup.FORMAT, version=1, agent_settings=data["agent_settings"],
                conversation_settings=data["conversation_settings"], custom_secrets=None)


class ModelTests(unittest.TestCase):
    def test_same_kind_removes_stale_nested_entries(self):
        original = PersistedSettings()
        original.update({"agent_settings_diff": {
            "llm": {"api_key": "synthetic-key", "litellm_extra_body": {"keep": [1]}},
            "mcp_config": {"service": {"command": "synthetic", "env": {"KEEP": "synthetic-value"}}}}})
        target = snapshot(original)
        current = PersistedSettings.model_validate(dump(original))
        current.update({"agent_settings_diff": {
            "llm": {"litellm_extra_body": {"stale": {"nested": True}}},
            "mcp_config": {"old": {"command": "old"}, "service": {"env": {"STALE": "old"}}},
            "agent_context": {"disabled_skills": ["stale"]}},
            "conversation_settings_diff": {"max_iterations": 12, "security_analyzer": None}})
        backup.validate(target)
        payload = backup.plan(dump(current), target)
        backup.check_patch_fidelity(dump(current)["agent_settings"], target["agent_settings"],
                                    payload["agent_settings_diff"])
        current.update(payload)
        self.assertEqual(snapshot(current), target)

    def test_kind_switches_fail_closed_even_with_default_nulls(self):
        for source, target in [(PersistedSettings(), PersistedSettings(agent_settings=ACPAgentSettings())),
                               (PersistedSettings(agent_settings=ACPAgentSettings()), PersistedSettings())]:
            with self.subTest(kind=target.agent_settings.agent_kind):
                wanted = snapshot(target)
                backup.validate(wanted)
                payload = backup.plan(dump(source), wanted)
                with self.assertRaises(backup.Failure):
                    backup.check_patch_fidelity(dump(source)["agent_settings"],
                                                wanted["agent_settings"], payload["agent_settings_diff"])
                source.update(payload)
                self.assertEqual(snapshot(source), wanted)

    def test_canonical_null_reproductions_and_safe_noops(self):
        changes = [
            {"agent_context": {"current_datetime": None}},
            {"llm": {"litellm_extra_body": {"custom": {"value": None}}}},
            *({"llm": {key: None}} for key in (
                "timeout", "disable_stop_word", "reasoning_effort",
                "prompt_cache_retention", "extended_thinking_budget")),
        ]
        for change in changes:
            for switched in (False, True):
                with self.subTest(change=change, switched=switched):
                    source = PersistedSettings()
                    source.update({"agent_settings_diff": {
                        "llm": {"litellm_extra_body": {"custom": {"value": "old"}}}}})
                    raw = dump(source)
                    for key, value in change.items():
                        raw["agent_settings"][key].update(value)
                    target = PersistedSettings.model_validate(raw)
                    wanted = snapshot(target)
                    backup.validate(wanted)
                    if switched:
                        source = PersistedSettings(agent_settings=ACPAgentSettings())
                    payload = backup.plan(dump(source), wanted)
                    with self.assertRaises(backup.Failure):
                        backup.check_patch_fidelity(dump(source)["agent_settings"],
                                                    wanted["agent_settings"], payload["agent_settings_diff"])
                    source.update(payload)
                    if not switched:
                        self.assertNotEqual(snapshot(source), wanted)

                    same = PersistedSettings.model_validate(dump(target))
                    same.update({"agent_settings_diff": {"enable_sub_agents": False}})
                    payload = backup.plan(dump(same), wanted)
                    backup.check_patch_fidelity(dump(same)["agent_settings"],
                                                wanted["agent_settings"], payload["agent_settings_diff"])
                    same.update(payload)
                    self.assertEqual(snapshot(same), wanted)

    def test_nulls_in_replacement_arrays_are_conservatively_rejected(self):
        source = PersistedSettings()
        raw = dump(source)
        raw["agent_settings"]["llm"]["litellm_extra_body"] = {"custom": [None, {"value": None}]}
        wanted = snapshot(PersistedSettings.model_validate(raw))
        payload = backup.plan(dump(source), wanted)
        with self.assertRaises(backup.Failure):
            backup.check_patch_fidelity(dump(source)["agent_settings"],
                                        wanted["agent_settings"], payload["agent_settings_diff"])
        source.update(payload)
        self.assertEqual(snapshot(source), wanted)
        payload = backup.plan(dump(source), wanted)
        backup.check_patch_fidelity(dump(source)["agent_settings"],
                                    wanted["agent_settings"], payload["agent_settings_diff"])

    def test_invalid_snapshots(self):
        good = snapshot(PersistedSettings())
        for key, value in [("version", True), ("version", 2), ("custom_secrets", [{}]),
                           ("agent_settings", {}), ("conversation_settings", {})]:
            bad = copy.deepcopy(good)
            bad[key] = value
            with self.subTest(key=key), self.assertRaises(backup.Failure):
                backup.validate(bad)
        for raw in [b'{"x":1,"x":2}', b'{"x":NaN}']:
            with self.assertRaises(backup.Failure):
                backup.decode(raw)

    def test_origins(self):
        for value in ["http://localhost:1", "http://example.com", "https://user:pass@example.com",
                      "https://example.com?a", "https://example.com#", "https://example.com/path",
                      "http://127.1", "https://example.com\n"]:
            with self.subTest(value=value), self.assertRaises(backup.Failure):
                backup.api_url(value)
        for value in ["http://127.0.0.1:8000", "http://[::1]:8000", "https://example.com"]:
            self.assertEqual(backup.api_url(value), value)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "backup.json"
        self.key = Path(self.temp.name) / "key"
        self.key.write_text("synthetic-session")
        self.key.chmod(0o600)
        self.settings = PersistedSettings()
        self.settings.update({"agent_settings_diff": {"llm": {"api_key": "synthetic-llm-secret"}}})
        self.secrets = {"TOKEN": {"name": "TOKEN", "value": "synthetic-custom-secret", "description": "synthetic-description"}}
        self.calls = []
        self.mode = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def handle_request(self):
                owner.calls.append((self.command, self.path))
                if self.headers.get("X-Session-API-Key") != "synthetic-session":
                    self.send_error(401)
                    return
                if owner.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", owner.api + "/do-not-follow")
                    self.end_headers()
                    return
                if owner.mode == "error" or (owner.mode == "partial" and self.command == "PUT"):
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(b"synthetic-error-secret https://private.example")
                    return
                if self.command == "GET":
                    if self.path == "/api/settings":
                        if self.headers.get("X-Expose-Secrets") != "plaintext":
                            self.send_error(400)
                            return
                        data = dump(owner.settings)
                    elif self.path == "/api/settings/secrets":
                        data = {"secrets": [{"name": s["name"], "description": s["description"]} for s in owner.secrets.values()]}
                    else:
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(owner.secrets[self.path.rsplit("/", 1)[1]]["value"].encode())
                        return
                else:
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if self.command == "PATCH":
                        owner.settings.update(body)
                        data = dump(owner.settings)
                    else:
                        owner.secrets[body["name"]] = body
                        data = {"name": body["name"]}
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())

            do_GET = do_PATCH = do_PUT = handle_request

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.api = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def cli(self, command, *args, success=True):
        env = dict(os.environ, HTTP_PROXY="http://127.0.0.1:1", HTTPS_PROXY="http://127.0.0.1:1", NO_PROXY="")
        result = subprocess.run([sys.executable, str(SCRIPT), command, str(self.path),
                                 "--api", self.api, "--api-key-file", str(self.key), *args],
                                capture_output=True, text=True, timeout=20, env=env)
        output = result.stdout + result.stderr
        self.assertNotIn("synthetic-", output)
        self.assertNotIn(self.api, output)
        self.assertNotIn("private.example", output)
        self.assertEqual(result.returncode == 0, success, output)
        return output

    def test_backup_restore_opt_in_preserves_unrelated_secrets(self):
        wanted = snapshot(self.settings)
        self.cli("backup", "--include-secrets")
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.settings.update({"agent_settings_diff": {"mcp_config": {"stale": {"command": "old"}}}})
        self.secrets["UNRELATED"] = {"name": "UNRELATED", "value": "other", "description": None}
        self.calls.clear()
        self.cli("restore")
        self.cli("preview")
        self.cli("restore", "--apply", success=False)
        self.assertEqual(self.calls, [])
        self.cli("restore", "--apply", "--include-secrets")
        self.assertEqual(snapshot(self.settings), wanted)
        self.assertIn("UNRELATED", self.secrets)
        self.assertNotIn("DELETE", [method for method, _ in self.calls])

    def test_default_does_not_read_custom_secrets(self):
        self.cli("backup")
        self.assertEqual(self.calls, [("GET", "/api/settings")])
        self.assertIsNone(json.loads(self.path.read_text())["custom_secrets"])
        self.cli("restore", "--apply")
        self.assertFalse(any(method == "PUT" for method, _ in self.calls))

    def test_files_and_invalid_snapshot_do_not_contact_api(self):
        self.path.write_text("invalid")
        self.path.chmod(0o600)
        self.cli("backup", success=False)
        self.cli("restore", "--apply", success=False)
        self.path.unlink()
        self.path.symlink_to(self.key)
        self.cli("backup", success=False)
        self.cli("restore", "--apply", success=False)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.key.read_text(), "synthetic-session")
        self.path.unlink()
        self.path.write_text(json.dumps(snapshot(self.settings)))
        self.path.chmod(0o644)
        self.cli("preview", success=False)

    def test_redirect_and_error_redaction(self):
        for mode in ["redirect", "error"]:
            self.mode = mode
            self.calls.clear()
            self.cli("backup", success=False)
            self.assertEqual(len(self.calls), 1)
            self.assertFalse(self.path.exists())

    def test_invalid_secret_blocks_settings_mutation(self):
        self.cli("backup", "--include-secrets")
        data = json.loads(self.path.read_text())
        data["custom_secrets"][0]["name"] = "../invalid"
        self.path.write_text(json.dumps(data))
        self.calls.clear()
        self.cli("restore", "--apply", "--include-secrets", success=False)
        self.assertEqual(self.calls, [])

    def test_null_preflight_prevents_all_writes(self):
        original = dump(self.settings)
        cases = [("agent_context", {"current_datetime": None}),
                 ("llm", {"litellm_extra_body": {"custom": {"value": None}}})]
        for key, change in cases:
            for switched in (False, True):
                with self.subTest(key=key, switched=switched):
                    raw = copy.deepcopy(original)
                    raw["agent_settings"][key].update(change)
                    self.settings = PersistedSettings.model_validate(raw)
                    self.cli("backup", "--include-secrets")
                    self.settings = (PersistedSettings(agent_settings=ACPAgentSettings()) if switched
                                     else PersistedSettings.model_validate(copy.deepcopy(original)))
                    self.settings.update({"agent_settings_diff": {
                        "llm": {"litellm_extra_body": {"custom": {"value": "old"}}}}})
                    before = dump(self.settings)
                    self.calls.clear()
                    self.cli("restore", "--apply", "--include-secrets", success=False)
                    self.assertEqual(self.calls, [("GET", "/api/settings")])
                    self.assertEqual(dump(self.settings), before)
                    self.path.unlink()

    def test_aggregate_size_cap_removes_output_without_leaking_secrets(self):
        value = "synthetic-" + "x" * (9 * 1024 * 1024)
        self.secrets = {name: {"name": name, "value": value, "description": None}
                        for name in ("FIRST", "SECOND")}
        self.cli("backup", "--include-secrets", success=False)
        self.assertFalse(self.path.exists())
        self.assertEqual(len(self.calls), 4)
        self.secrets.pop("SECOND")
        self.cli("backup", "--include-secrets")
        self.assertLessEqual(self.path.stat().st_size, backup.LIMIT)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.cli("preview")
        self.cli("restore", "--apply", "--include-secrets")

    def test_partial_failure_is_reported(self):
        self.cli("backup", "--include-secrets")
        self.mode = "partial"
        output = self.cli("restore", "--apply", "--include-secrets", success=False)
        self.assertIn("partial", output)
        self.assertIn(("PATCH", "/api/settings"), self.calls)


if __name__ == "__main__":
    unittest.main()
