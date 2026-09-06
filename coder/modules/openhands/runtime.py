import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request


PACKAGES = ("openhands-sdk", "openhands-tools", "openhands-agent-server")


def private_directory(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError("OpenHands private directory must be owned and not a symlink")
    path.chmod(0o700)
    return path


def private_open(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(fd)
        raise RuntimeError("OpenHands state must be an owned regular file without hard links")
    os.fchmod(fd, 0o600)
    return fd


def read_private(path):
    with os.fdopen(private_open(path, os.O_RDONLY)) as stream:
        return stream.read()


def write_private(path, content):
    with os.fdopen(private_open(path, os.O_WRONLY | os.O_CREAT), "w") as stream:
        stream.truncate(0)
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


@contextlib.contextmanager
def startup_lock(path, timeout=120):
    fd = private_open(path, os.O_RDWR | os.O_CREAT)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("OpenHands startup lock timed out") from None
                time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        yield
    finally:
        os.close(fd)


def load_keys(root):
    paths = [root / "session-api-key", root / "encryption-key"]
    present = [path.exists() or path.is_symlink() for path in paths]
    if any(present) and not all(present):
        raise RuntimeError("OpenHands key pair is incomplete; restore both original keys")
    if not any(present):
        if any(path.exists() for path in (root / "server.json", root / "configured.json", root.parent / ".coder-openhands-data")):
            raise RuntimeError("OpenHands keys are missing; restore the original keys")
        for path in paths:
            with os.fdopen(private_open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL), "w") as stream:
                stream.write(secrets.token_hex(32) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
    keys = [read_private(path).strip() for path in paths]
    if any(not re.fullmatch(r"[a-f0-9]{64}", key) for key in keys) or keys[0] == keys[1]:
        raise RuntimeError("OpenHands keys are invalid or not independent")
    return keys


def configuration(raw, home):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", raw["version"]):
        raise ValueError("Invalid OpenHands version")
    if not re.fullmatch(r"3\.(1[2-9]|[2-9][0-9])(\.[0-9]+)?", raw["python_version"]):
        raise ValueError("Python 3.12 or newer must be selected")
    if type(raw["port"]) is not int or not 1024 <= raw["port"] <= 65535:
        raise ValueError("Invalid loopback port")
    if not re.fullmatch(r"[a-f0-9]{64}", raw["runtime_revision"]):
        raise ValueError("Invalid runtime revision")
    names = raw.get("environment_names", [])
    if not isinstance(names, list) or any(
        not isinstance(name, str)
        or not re.fullmatch(r"[A-Z][A-Z0-9_]*", name)
        or re.match(r"^(OH_|OPENHANDS_|PYTHON|LD_|DYLD_|BASH_FUNC_)", name)
        or (name.startswith("CODER_") and name not in {"CODER_URL", "CODER_ACCESS_URL", "CODER_ENVIRONMENT_MODE", "CODER_OMNI_STACKS"})
        or name in {
            "HOME", "PATH", "SESSION_API_KEY", "BASH_ENV", "ENV", "SHELLOPTS",
            "BASHOPTS", "PROMPT_COMMAND", "CDPATH", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
        }
        for name in names
    ):
        raise ValueError("Invalid or reserved inherited environment variable name")
    workspace = Path(raw["working_directory"] or home / "workspace")
    if not workspace.is_absolute() or "\x00" in str(workspace):
        raise ValueError("Working directory must be an absolute path")
    workspace = workspace.resolve()
    for path in (home / ".coder-openhands", home / ".coder-openhands-data"):
        if workspace == path or workspace in path.parents or path in workspace.parents:
            raise ValueError("Working directory must not overlap OpenHands private storage")
    return {**raw, "working_directory": str(workspace), "home": str(home), "host": "127.0.0.1"}


def process_identity(pid):
    try:
        proc = Path("/proc") / str(pid)
        fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return {
            "pid": pid,
            "start": fields[19],
            "boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "uid": proc.stat().st_uid,
            "command": (proc / "cmdline").read_bytes().rstrip(b"\x00").decode().split("\x00"),
        }
    except FileNotFoundError:
        return None


def validate_record(record, config, command):
    identity = process_identity(record["identity"]["pid"])
    if identity is None:
        return False
    if identity != record["identity"] or identity["uid"] != os.getuid() or identity["command"] != command:
        raise RuntimeError("OpenHands PID ownership mismatch; refusing to touch the process")
    if record["config"] != config:
        raise RuntimeError("OpenHands configuration/version changed; stop the owned server explicitly first")
    return True


def require_free_port(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            raise RuntimeError("OpenHands loopback port is already in use; refusing to replace its listener") from None


def owns_listener(pid, port):
    inodes = set()
    try:
        for fd in (Path("/proc") / str(pid) / "fd").iterdir():
            try:
                inodes.add(os.readlink(fd))
            except FileNotFoundError:
                continue
        for line in Path("/proc/net/tcp").read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == f"0100007F:{port:04X}" and fields[3] == "0A":
                return f"socket:[{fields[9]}]" in inodes
    except FileNotFoundError:
        pass
    return False


def clean_environment(home):
    return {
        **{name: os.environ[name] for name in ("SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE") if name in os.environ},
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "PYTHONUNBUFFERED": "1",
    }


def check_environment(python, config, env):
    code = (
        "import importlib.metadata as m,json,sys;"
        f"print(json.dumps([[m.version(p) for p in {PACKAGES!r}],list(sys.version_info[:3])]))"
    )
    result = subprocess.run([str(python), "-I", "-c", code], env=env, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError("OpenHands environment is incomplete; repair it while the server is stopped")
    versions, python_version = json.loads(result.stdout)
    requested_python = [int(part) for part in config["python_version"].split(".")]
    if versions != [config["version"]] * len(PACKAGES) or python_version[:len(requested_python)] != requested_python:
        raise RuntimeError("OpenHands installed package/Python version mismatch")


def environment(root, config, env, active):
    venv = root / f"venv-{config['version']}-py{config['python_version']}"
    python = venv / "bin" / "python"
    if venv.is_symlink():
        raise RuntimeError("OpenHands environment must not be a symlink")
    if not venv.exists():
        if active:
            raise RuntimeError("Running OpenHands environment is missing")
        uv = shutil.which("uv", path=env["PATH"])
        if not uv:
            raise RuntimeError("OpenHands requires uv from the validated Python component")
        subprocess.run([uv, "--no-config", "venv", "--python", config["python_version"], str(venv)], env=env, check=True, timeout=600)
        subprocess.run([
            uv, "--no-config", "pip", "install", "--python", str(python),
            "--index-url", "https://pypi.org/simple",
            *[f"{package}=={config['version']}" for package in PACKAGES],
        ], env=env, check=True, timeout=600)
    check_environment(python, config, env)
    return python


def inherited_environment(config, source):
    return {name: source[name] for name in config.get("environment_names", []) if name in source}


def server_environment(env, root, data, config, keys, inherited=None):
    return {
        **env,
        **(inherited or {}),
        "OH_SESSION_API_KEYS_0": keys[0],
        "OH_SECRET_KEY": keys[1],
        "OH_CONVERSATIONS_PATH": str(data / "conversations"),
        "OH_WORKSPACE_PATH": config["working_directory"],
        "OH_CONVERSATION_WORKTREE_ROOT": str(data / "worktrees"),
        "OH_BASH_EVENTS_DIR": str(data / "bash-events"),
        "OH_ENABLE_VSCODE": "false",
        "OH_ENABLE_VNC": "false",
        "OPENHANDS_AGENT_SERVER_CONFIG_PATH": str(root / "agent-server.json"),
    }


def validate_health(health, ready, count, info, version):
    if health != {"status": "ok"} or ready != {"status": "ready"}:
        raise ValueError("OpenHands is not ready")
    if type(count) is not int or count < 0:
        raise ValueError("OpenHands authenticated conversation count is invalid")
    if any(info.get(field) != version for field in ("version", "sdk_version", "tools_version")):
        raise RuntimeError("OpenHands running package version mismatch")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise RuntimeError("OpenHands readiness endpoint unexpectedly redirected")


def wait_ready(record, command, key, timeout=90):
    config = record["config"]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    deadline = time.monotonic() + timeout
    base = f"http://127.0.0.1:{config['port']}"

    def request(path, authenticated=True):
        headers = {"X-Session-API-Key": key} if authenticated else {}
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        with opener.open(urllib.request.Request(base + path, headers=headers), timeout=min(2, remaining)) as response:
            return json.load(response)

    while time.monotonic() < deadline:
        if not validate_record(record, config, command):
            raise RuntimeError("OpenHands exited before readiness; inspect its private server.log")
        try:
            if not owns_listener(record["identity"]["pid"], config["port"]):
                raise ValueError("Owned listener not ready")
            health = request("/health")
            ready = request("/ready")
            count = request("/api/conversations/count")
            info = request("/server_info")
            validate_health(health, ready, count, info, config["version"])
            try:
                request("/api/conversations/count", authenticated=False)
            except urllib.error.HTTPError as error:
                if error.code != 401:
                    raise
            else:
                raise RuntimeError("OpenHands accepted an unauthenticated API request")
            if not validate_record(record, config, command) or not owns_listener(record["identity"]["pid"], config["port"]):
                raise RuntimeError("OpenHands process changed during readiness")
            return
        except (OSError, ValueError, urllib.error.URLError):
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    raise RuntimeError("OpenHands readiness timed out; process left intact, inspect private server.log")


def start(raw):
    os.umask(0o077)
    home = Path.home().resolve()
    config = configuration(raw, home)
    root = private_directory(home / ".coder-openhands")
    with startup_lock(root / "startup.lock"):
        keys = load_keys(root)
        env = clean_environment(home)
        inherited = inherited_environment(config, os.environ)
        config["environment_fingerprint"] = hashlib.sha256(
            json.dumps({**env, **inherited}, sort_keys=True).encode()
        ).hexdigest()
        config["key_fingerprints"] = [hashlib.sha256(key.encode()).hexdigest() for key in keys]
        python = root / f"venv-{config['version']}-py{config['python_version']}" / "bin" / "python"
        command = [str(python), "-I", "-m", "openhands.agent_server", "--host", "127.0.0.1", "--port", str(config["port"])]
        record_path = root / "server.json"
        if not record_path.exists() and (root / "configured.json").exists():
            raise RuntimeError("OpenHands process record is missing; verify no orphaned server before repairing state")
        record = json.loads(read_private(record_path)) if record_path.exists() else None
        active = record is not None and validate_record(record, config, command)
        if not active:
            require_free_port(config["port"])
        environment(root, config, env, active)
        if not active:
            data = private_directory(home / ".coder-openhands-data")
            for name in ("conversations", "worktrees", "bash-events"):
                private_directory(data / name)
            Path(config["working_directory"]).mkdir(parents=True, exist_ok=True)
            configured_path = root / "configured.json"
            if configured_path.exists():
                previous = json.loads(read_private(configured_path))
                if previous["key_fingerprints"] != config["key_fingerprints"]:
                    raise RuntimeError("OpenHands persisted encryption/auth keys changed; restore original keys")
            write_private(configured_path, json.dumps(config))
            write_private(root / "agent-server.json", "{}\n")
            with os.fdopen(private_open(root / "server.log", os.O_WRONLY | os.O_CREAT | os.O_APPEND), "a") as log:
                child = subprocess.Popen(
                    command, env=server_environment(env, root, data, config, keys, inherited),
                    cwd=config["working_directory"], stdin=subprocess.DEVNULL,
                    stdout=log, stderr=log, start_new_session=True,
                )
            identity = process_identity(child.pid)
            if identity is None or identity["command"] != command:
                raise RuntimeError("OpenHands exited during launch; inspect private server.log")
            record = {"identity": identity, "config": config}
            write_private(record_path, json.dumps(record))
        wait_ready(record, command, keys[0])
        print(f"OpenHands ready on http://127.0.0.1:{config['port']} (SSH forwarding only)")


if __name__ == "__main__":
    try:
        start(json.loads(base64.b64decode(sys.argv[1], validate=True)))
    except Exception as error:
        print(f"OpenHands startup failed: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
