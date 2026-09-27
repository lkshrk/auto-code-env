"""One `opencode serve` per OpenCode control-plane workspace, each in its own git worktree."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request


WORKSPACE_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
REPOSITORY = re.compile(r"(https://github\.com/|git@github\.com:)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?(\.git)?")
BRANCH = re.compile(r"[A-Za-z0-9._/-]{1,200}")
# Only what the control plane passes on create; everything else comes from the workspace itself.
FORWARDED_ENV = {
    "OPENCODE_WORKSPACE_ID", "OPENCODE_AUTH_CONTENT", "OPENCODE_CONFIG_CONTENT", "OPENCODE_EXPERIMENTAL_WORKSPACES",
    "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_RESOURCE_ATTRIBUTES",
}
MAX_BODY = 1 << 20


class Conflict(Exception):
    pass


class Spawner:
    def __init__(self, binary, state, src, environ=None):
        self.binary = binary
        self.state = Path(state)
        self.src = Path(src)
        self.environ = dict(os.environ if environ is None else environ)
        self.lock = threading.Lock()
        self.processes = {}
        self.state.mkdir(parents=True, exist_ok=True)

    def record_path(self, workspace_id):
        return self.state / f"{workspace_id}.json"

    def records(self):
        for path in sorted(self.state.glob("*.json")):
            yield json.loads(path.read_text())

    def checkout(self, repository, workspace_id, branch):
        name = re.sub(r"\.git$", "", repository.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1])
        base = self.src / name
        if not (base / ".git").exists():
            self.src.mkdir(parents=True, exist_ok=True)
            self.git(["clone", "--quiet", repository, str(base)])
        worktree = base / ".worktrees" / workspace_id
        if not worktree.exists():
            self.git(["-C", str(base), "fetch", "--quiet", "origin"])
            start = f"origin/{branch}" if branch else "origin/HEAD"
            self.git(["-C", str(base), "worktree", "add", "--quiet", "-b", f"oc/{workspace_id}", str(worktree), start])
        return worktree

    def git(self, args):
        result = subprocess.run(["git", *args], env=self.environ, capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise RuntimeError(f"git {args[0]} failed: {result.stderr.strip()[-500:]}")

    def create(self, body):
        workspace_id = body.get("id", "")
        if not isinstance(workspace_id, str) or not WORKSPACE_ID.fullmatch(workspace_id):
            raise ValueError("invalid id")
        repository = body.get("repository")
        branch = body.get("branch")
        if not isinstance(repository, str) or not REPOSITORY.fullmatch(repository):
            raise ValueError("repository must be a GitHub URL")
        if branch is not None and (not isinstance(branch, str) or not BRANCH.fullmatch(branch) or ".." in branch):
            raise ValueError("invalid branch")
        env = body.get("env") or {}
        if not isinstance(env, dict) or any(not isinstance(v, str) for v in env.values()):
            raise ValueError("env must map names to strings")
        env = {k: v for k, v in env.items() if k in FORWARDED_ENV}
        with self.lock:
            path = self.record_path(workspace_id)
            if path.exists():
                record = json.loads(path.read_text())
                if record["repository"] != repository:
                    raise Conflict("id already bound to another repository")
                return self.ensure(record)
            worktree = self.checkout(repository, workspace_id, branch)
            record = {"id": workspace_id, "repository": repository, "directory": str(worktree), "env": env, "port": None}
            path.write_text(json.dumps(record))
            path.chmod(0o600)
            return self.ensure(record)

    def ensure(self, record):
        process = self.processes.get(record["id"])
        # A server without a handle survived a spawner restart; adopt it.
        if (process is None or process.poll() is None) and self.healthy(record["port"]):
            return self.public(record)
        record["port"] = free_port()
        env = {**self.environ, **record["env"], "OPENCODE_WORKSPACE_ID": record["id"]}
        with (self.state / f"{record['id']}.log").open("ab") as log:
            self.processes[record["id"]] = subprocess.Popen(
                [self.binary, "serve", "--hostname", "127.0.0.1", "--port", str(record["port"])],
                cwd=record["directory"], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True,
            )
        self.record_path(record["id"]).write_text(json.dumps(record))
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.processes[record["id"]].poll() is not None:
                raise RuntimeError(f"opencode serve for {record['id']} exited; see {record['id']}.log")
            if self.healthy(record["port"]):
                return self.public(record)
            time.sleep(0.25)
        raise RuntimeError(f"opencode serve for {record['id']} did not become healthy")

    def healthy(self, port):
        if not port:
            return False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/global/health", timeout=2) as response:
                return response.status == 200
        except OSError:
            return False

    def get(self, workspace_id):
        path = self.record_path(workspace_id)
        if not WORKSPACE_ID.fullmatch(workspace_id) or not path.exists():
            return None
        with self.lock:
            return self.ensure(json.loads(path.read_text()))

    def remove(self, workspace_id):
        path = self.record_path(workspace_id)
        if not WORKSPACE_ID.fullmatch(workspace_id) or not path.exists():
            return None
        with self.lock:
            record = json.loads(path.read_text())
            process = self.processes.pop(workspace_id, None)
            if process and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            base = Path(record["directory"]).parents[1]
            # Non-forced: a worktree with uncommitted changes is kept rather than lost.
            result = subprocess.run(
                ["git", "-C", str(base), "worktree", "remove", record["directory"]],
                env=self.environ, capture_output=True, text=True, timeout=60,
            )
            path.unlink()
            (self.state / f"{workspace_id}.log").unlink(missing_ok=True)
            return {"id": workspace_id, "worktree_kept": result.returncode != 0}

    def public(self, record):
        return {"id": record["id"], "repository": record["repository"], "directory": record["directory"], "port": record["port"]}


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def handler(spawner, revision):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def run(self, action):
            try:
                result = action()
            except ValueError as error:
                return self.reply(400, {"error": str(error)})
            except Conflict as error:
                return self.reply(409, {"error": str(error)})
            except Exception as error:
                return self.reply(500, {"error": f"{type(error).__name__}: {error}"})
            if result is None:
                return self.reply(404, {"error": "unknown workspace"})
            return self.reply(200, result)

        def workspace_id(self):
            parts = self.path.split("?", 1)[0].strip("/").split("/")
            return parts[1] if len(parts) == 2 and parts[0] == "workspaces" else None

        def do_GET(self):
            if self.path == "/healthz":
                return self.reply(200, {"status": "ok", "revision": revision})
            if self.path == "/workspaces":
                return self.run(lambda: [spawner.public(r) for r in spawner.records()])
            workspace_id = self.workspace_id()
            if workspace_id:
                return self.run(lambda: spawner.get(workspace_id))
            self.reply(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/workspaces":
                return self.reply(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return self.reply(400, {"error": "body required"})
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                return self.reply(400, {"error": "invalid JSON"})
            if not isinstance(body, dict):
                return self.reply(400, {"error": "body must be an object"})
            self.run(lambda: spawner.create(body))

        def do_DELETE(self):
            workspace_id = self.workspace_id()
            if not workspace_id:
                return self.reply(404, {"error": "not found"})
            self.run(lambda: spawner.remove(workspace_id))

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    return Handler


def main(settings):
    spawner = Spawner(settings["binary"], settings["state"], Path.home() / "src")
    server = ThreadingHTTPServer(("127.0.0.1", settings["port"]), handler(spawner, settings["revision"]))
    server.serve_forever()


if __name__ == "__main__":
    main(json.loads(sys.argv[1]))
