import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from openhands.agent_server.persistence import PersistedSettings
from openhands.sdk.mcp.config import MCPServer
from openhands.sdk.settings.api_models import MCPServerPatch


SCRIPT = Path(__file__).resolve().parents[1] / "image/rootfs/usr/local/lib/openhands/apply-profile.py"
SPEC = importlib.util.spec_from_file_location("apply_profile", SCRIPT)
applier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(applier)


def dump(settings):
    return settings.model_dump(mode="json", context={"expose_secrets": "plaintext"})["agent_settings"]


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.settings = PersistedSettings()
        self.calls = []
        self.failure = None
        self.secrets = {"LEGACY": "synthetic-retained"}
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def request(self):
                owner.calls.append((self.command, self.path))
                if self.headers.get("X-Session-API-Key") != "synthetic-key":
                    self.send_error(401)
                    return
                if owner.failure == (self.command, self.path):
                    self.send_error(500)
                    return
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                try:
                    if self.path == "/api/settings":
                        if self.command == "PATCH":
                            owner.settings.update(body)
                        else:
                            assert self.command == "GET"
                    elif self.path.startswith("/api/settings/mcp/"):
                        name = self.path.rsplit("/", 1)[1]
                        if self.command == "PATCH":
                            body = MCPServerPatch.model_validate(body).model_dump(
                                mode="python", exclude_unset=True, context={"expose_secrets": "plaintext"})
                        elif self.command == "DELETE":
                            body = None
                        else:
                            assert self.command == "POST"
                            assert name not in owner.settings.agent_settings.mcp_config
                        owner.settings.update({"agent_settings_diff": {"mcp_config": {name: body}}})
                    else:
                        assert self.command == "DELETE" and self.path.startswith("/api/settings/secrets/")
                        owner.secrets.pop(self.path.rsplit("/", 1)[1], None)
                except Exception as error:
                    owner.errors.append(error)
                    self.send_error(500)
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"agent_settings": dump(owner.settings)}).encode())

            do_GET = do_PATCH = do_POST = do_DELETE = request

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        key = Path(self.directory.name) / "key"
        key.write_text("synthetic-key")
        key.chmod(0o600)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)
        self.arguments = ["--api", f"http://127.0.0.1:{self.server.server_port}",
                          "--api-key-file", str(key), "--secrets-dir", self.directory.name,
                          "--state-dir", self.directory.name]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def apply(self, profile):
        path = Path(self.directory.name) / "profile.json"
        path.write_text(json.dumps(profile))
        self.calls.clear()
        applier.main([*self.arguments, str(path)])
        self.assertEqual(self.errors, [])

    def seed(self, server):
        server = dict(server, transport="http" if "url" in server else "stdio")
        self.settings = PersistedSettings()
        self.settings.update({"agent_settings_diff": {"mcp_config": {
            "target": server, "unmanaged": {"command": "keep"}}}})

    def test_real_mcp_patches_and_normalized_second_apply(self):
        cases = [
            ({"command": "coder", "args": ["old"], "env": {"KEEP": "x", "DROP": "y"}},
             {"command": "coder", "args": [], "env": {"KEEP": "x"}}),
            ({"url": "https://x.test", "headers": {"KEEP": "x", "DROP": "y"}},
             {"url": "https://x.test", "headers": {}}),
            ({"url": "https://x.test", "headers": {"TOKEN": "y"}},
             {"command": "coder", "args": [], "env": {}}),
            ({"command": "coder", "args": ["old"], "env": {"TOKEN": "y"}, "cwd": "/old"},
             {"url": "https://x.test", "headers": {}}),
        ]
        for current, desired in cases:
            with self.subTest(desired=desired):
                self.seed(current)
                self.apply({"mcp_servers": {"target": desired}})
                target = dump(self.settings)["mcp_config"]["target"]
                for field in ("env", "headers", "args"):
                    if field in desired:
                        self.assertEqual(target.get(field) or ({} if field != "args" else []), desired[field])
                incompatible = ("url", "headers", "auth") if "command" in desired else ("command", "args", "env", "cwd")
                MCPServer.model_validate(target)
                for field in incompatible:
                    self.assertIsNone(target.get(field))
                self.assertIn("unmanaged", self.settings.agent_settings.mcp_config)
                self.apply({"mcp_servers": {"target": desired}})
                self.assertEqual(self.calls, [("GET", "/api/settings")])

    def test_sparse_omissions_preserve_ui_fields(self):
        for current, desired in [
            ({"command": "coder", "args": ["ui"], "env": {"UI": "value"}}, {"command": "coder"}),
            ({"url": "https://x.test", "headers": {"UI": "value"}}, {"url": "https://x.test"}),
        ]:
            self.seed(current)
            before = dump(self.settings)
            self.apply({"mcp_servers": {"target": desired}})
            self.assertEqual(dump(self.settings), before)
            self.assertEqual(self.calls, [("GET", "/api/settings")])

    def test_real_kind_switch_refreshes_before_mcp_and_retires_last(self):
        self.seed({"command": "coder"})
        self.apply({"agent": {"kind": "acp"}, "mcp_servers": {"target": {"command": "coder"}},
                    "retired_secrets": ["LEGACY"]})
        self.assertEqual(self.calls, [("GET", "/api/settings"), ("PATCH", "/api/settings"),
                                     ("GET", "/api/settings"), ("POST", "/api/settings/mcp/target"),
                                     ("DELETE", "/api/settings/secrets/LEGACY")])
        self.assertNotIn("unmanaged", self.settings.agent_settings.mcp_config)
        self.assertNotIn("LEGACY", self.secrets)

    def test_failed_mutations_never_retire_secrets(self):
        for failure in [("PATCH", "/api/settings"), ("POST", "/api/settings/mcp/new"),
                        ("PATCH", "/api/settings/mcp/target"), ("DELETE", "/api/settings/mcp/target")]:
            with self.subTest(failure=failure):
                self.seed({"command": "old"})
                self.failure = failure
                profile = {"retired_secrets": ["LEGACY"]}
                if failure[1] == "/api/settings":
                    profile["agent"] = {"kind": "acp"}
                else:
                    profile["mcp_servers"] = {failure[1].rsplit("/", 1)[1]:
                                              None if failure[0] == "DELETE" else {"command": "new"}}
                with self.assertRaises(SystemExit):
                    self.apply(profile)
                self.assertIn("LEGACY", self.secrets)
                self.assertNotIn(("DELETE", "/api/settings/secrets/LEGACY"), self.calls)


if __name__ == "__main__":
    unittest.main()
