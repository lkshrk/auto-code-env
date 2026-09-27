import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request


MODULE = Path(__file__).resolve().parents[2] / "modules" / "opencode"


def load(name):
    spec = importlib.util.spec_from_file_location(f"opencode_{name}", MODULE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


spawner_module = load("spawner")
runtime = load("runtime")

FAKE_SERVE = """#!{python}
import http.server, json, os, sys
port = int(sys.argv[sys.argv.index("--port") + 1])
out = os.environ["FAKE_OUT"]
with open(os.path.join(out, os.environ["OPENCODE_WORKSPACE_ID"] + ".env.json"), "w") as f:
    json.dump({{"env": dict(os.environ), "cwd": os.getcwd(), "argv": sys.argv}}, f)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/global/health" else 404)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"""
REPO = "https://github.com/example/demo.git"


def git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class SpawnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        origin = self.tmp / "origin"
        origin.mkdir()
        git("init", "--quiet", "-b", "main", cwd=origin)
        (origin / "README").write_text("demo\n")
        git("add", "README", cwd=origin)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "init", cwd=origin)
        self.binary = self.tmp / "opencode"
        self.binary.write_text(FAKE_SERVE.format(python=sys.executable))
        self.binary.chmod(0o755)
        self.out = self.tmp / "out"
        self.out.mkdir()
        self.environ = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.tmp),
            "FAKE_OUT": str(self.out),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": f"url.{origin}.insteadOf",
            "GIT_CONFIG_VALUE_0": REPO,
            "GIT_CONFIG_KEY_1": "user.name",
            "GIT_CONFIG_VALUE_1": "t",
            "GIT_CONFIG_KEY_2": "user.email",
            "GIT_CONFIG_VALUE_2": "t@t",
        }
        self.spawner = self.new_spawner()

    def new_spawner(self):
        return spawner_module.Spawner(str(self.binary), self.tmp / "state", self.tmp / "src", self.environ)

    def tearDown(self):
        for spawner in getattr(self, "spawners", []) + [self.spawner]:
            for process in spawner.processes.values():
                if process.poll() is None:
                    os.killpg(process.pid, 9)
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def created_env(self, workspace_id):
        return json.loads((self.out / f"{workspace_id}.env.json").read_text())

    def test_create_starts_serve_in_worktree_with_forwarded_env_only(self):
        result = self.spawner.create({
            "id": "ws1", "repository": REPO,
            "env": {
                "OPENCODE_AUTH_CONTENT": "{}", "OPENCODE_CONFIG_CONTENT": '{"model": "m"}',
                "OPENCODE_EXPERIMENTAL_WORKSPACES": "true", "LD_PRELOAD": "x",
            },
        })
        worktree = self.tmp / "src" / "demo" / ".worktrees" / "ws1"
        self.assertEqual(result["directory"], str(worktree))
        self.assertTrue(self.spawner.healthy(result["port"]))
        seen = self.created_env("ws1")
        self.assertEqual(Path(seen["cwd"]).resolve(), worktree.resolve())
        self.assertEqual(seen["env"]["OPENCODE_WORKSPACE_ID"], "ws1")
        self.assertEqual(seen["env"]["OPENCODE_AUTH_CONTENT"], "{}")
        self.assertEqual(seen["env"]["OPENCODE_CONFIG_CONTENT"], '{"model": "m"}')
        self.assertNotIn("LD_PRELOAD", seen["env"])
        self.assertIn("127.0.0.1", seen["argv"])
        branch = subprocess.run(["git", "-C", str(worktree), "branch", "--show-current"],
                                capture_output=True, text=True, env=self.environ).stdout.strip()
        self.assertEqual(branch, "oc/ws1")

    def test_create_is_idempotent_and_rejects_rebinding(self):
        first = self.spawner.create({"id": "ws1", "repository": REPO})
        second = self.spawner.create({"id": "ws1", "repository": REPO})
        self.assertEqual(first, second)
        with self.assertRaises(spawner_module.Conflict):
            self.spawner.create({"id": "ws1", "repository": "https://github.com/example/other"})

    def test_rejects_invalid_input(self):
        for body in (
            {"id": "../x", "repository": REPO},
            {"id": "ws1", "repository": "file:///etc"},
            {"id": "ws1", "repository": "https://evil.example/a/b"},
            {"id": "ws1", "repository": REPO, "branch": "a..b"},
            {"id": "ws1", "repository": REPO, "env": {"OPENCODE_AUTH_CONTENT": 1}},
        ):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.spawner.create(body)

    def test_restarted_spawner_adopts_running_server(self):
        port = self.spawner.create({"id": "ws1", "repository": REPO})["port"]
        restarted = self.new_spawner()
        self.spawners = [restarted]
        self.assertEqual(restarted.get("ws1")["port"], port)
        self.assertEqual(restarted.processes, {})

    def test_get_restarts_a_dead_server(self):
        self.spawner.create({"id": "ws1", "repository": REPO})
        process = self.spawner.processes["ws1"]
        os.killpg(process.pid, 9)
        process.wait()
        result = self.spawner.get("ws1")
        self.assertTrue(self.spawner.healthy(result["port"]))
        self.assertNotEqual(self.spawner.processes["ws1"].pid, process.pid)

    def test_remove_stops_server_and_keeps_dirty_worktree(self):
        clean = self.spawner.create({"id": "clean", "repository": REPO})
        dirty = self.spawner.create({"id": "dirty", "repository": REPO})
        Path(dirty["directory"], "README").write_text("changed\n")
        self.assertEqual(self.spawner.remove("clean"), {"id": "clean", "worktree_kept": False})
        self.assertEqual(self.spawner.remove("dirty"), {"id": "dirty", "worktree_kept": True})
        self.assertFalse(Path(clean["directory"]).exists())
        self.assertTrue(Path(dirty["directory"]).exists())
        self.assertFalse(self.spawner.healthy(clean["port"]))
        self.assertIsNone(self.spawner.remove("clean"))

    def test_http_api(self):
        server = spawner_module.ThreadingHTTPServer(("127.0.0.1", 0), spawner_module.handler(self.spawner, "rev"))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}"

        def call(method, path, body=None):
            data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
            request = urllib.request.Request(base + path, data=data, method=method)
            try:
                with urllib.request.urlopen(request, timeout=90) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        try:
            self.assertEqual(call("GET", "/healthz"), (200, {"status": "ok", "revision": "rev"}))
            self.assertEqual(call("POST", "/workspaces", b"{nope")[0], 400)
            self.assertEqual(call("POST", "/workspaces", {"id": "x"})[0], 400)
            status, created = call("POST", "/workspaces", {"id": "ws1", "repository": REPO})
            self.assertEqual(status, 200)
            self.assertEqual(call("GET", "/workspaces/ws1"), (200, created))
            self.assertEqual(call("GET", "/workspaces"), (200, [created]))
            self.assertEqual(call("GET", "/workspaces/missing")[0], 404)
            self.assertEqual(call("DELETE", "/workspaces/ws1")[0], 200)
            self.assertEqual(call("GET", "/nope")[0], 404)
        finally:
            server.shutdown()


class RuntimeTest(unittest.TestCase):
    def test_configuration_validation(self):
        good = {"version": "1.18.32", "port": 18002, "spawner_revision": "a" * 64}
        self.assertEqual(runtime.configuration(dict(good)), good)
        for key, value in (("version", "latest"), ("port", 80), ("port", "18002"), ("spawner_revision", "x")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                runtime.configuration({**good, key: value})

    def test_release_asset_requires_sha256_digest(self):
        asset = {"name": "opencode-linux-x64.tar.gz", "browser_download_url": "https://x/a", "digest": "sha256:" + "b" * 64}
        self.assertEqual(runtime.release_asset({"assets": [asset]}, "x64"), ("https://x/a", "b" * 64))
        with self.assertRaises(RuntimeError):
            runtime.release_asset({"assets": [{**asset, "digest": None}]}, "x64")
        with self.assertRaises(RuntimeError):
            runtime.release_asset({"assets": [asset]}, "arm64")

    def test_version_is_tracked_by_renovate(self):
        text = (MODULE / "variables.tf").read_text()
        self.assertIn("# renovate: datasource=npm depName=opencode-ai\n  default  = ", text)


if __name__ == "__main__":
    unittest.main()
