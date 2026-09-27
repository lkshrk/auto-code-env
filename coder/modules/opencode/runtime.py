import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request


RELEASES = "https://api.github.com/repos/anomalyco/opencode/releases/tags/v{version}"
ARCHES = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}


def configuration(raw):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", raw["version"]):
        raise ValueError("Invalid OpenCode version")
    if type(raw["port"]) is not int or not 1024 <= raw["port"] <= 65535:
        raise ValueError("Invalid spawner port")
    if not re.fullmatch(r"[a-f0-9]{64}", raw["spawner_revision"]):
        raise ValueError("Invalid spawner revision")
    return raw


def github_json(url, token=None):
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def release_asset(release, arch):
    name = f"opencode-linux-{arch}.tar.gz"
    for asset in release.get("assets", []):
        if asset.get("name") == name:
            digest = asset.get("digest") or ""
            if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
                raise RuntimeError(f"{name} has no sha256 digest")
            return asset["browser_download_url"], digest.removeprefix("sha256:")
    raise RuntimeError(f"release has no {name}")


def installed_version(binary):
    try:
        result = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=30)
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def install(root, version, token=None, machine=None):
    target = root / version / "opencode"
    if installed_version(target) == version:
        return target
    arch = ARCHES.get(machine or platform.machine())
    if not arch:
        raise RuntimeError(f"unsupported architecture {machine or platform.machine()}")
    url, digest = release_asset(github_json(RELEASES.format(version=version), token), arch)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent) as tmp:
        archive = Path(tmp) / "opencode.tar.gz"
        with urllib.request.urlopen(url, timeout=300) as response, archive.open("wb") as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError("OpenCode archive digest mismatch")
        with tarfile.open(archive) as tar:
            member = tar.getmember("opencode")
            if not member.isfile():
                raise RuntimeError("OpenCode archive has no regular opencode binary")
            source = tar.extractfile(member)
            staged = Path(tmp) / "opencode"
            staged.write_bytes(source.read())
        staged.chmod(0o755)
        if installed_version(staged) != version:
            raise RuntimeError("OpenCode binary reports an unexpected version")
        os.replace(staged, target)
    return target


def link(binary, home):
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    link_path = bin_dir / "opencode"
    tmp = bin_dir / ".opencode.tmp"
    tmp.unlink(missing_ok=True)
    tmp.symlink_to(binary)
    os.replace(tmp, link_path)


def healthy(port, revision, timeout=2):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=timeout) as response:
            return json.load(response).get("revision") == revision
    except (OSError, ValueError):
        return False


def port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        return probe.connect_ex(("127.0.0.1", port)) == 0


def start_spawner(root, config, spawner_source, binary, timeout=30):
    port, revision = config["port"], config["spawner_revision"]
    if healthy(port, revision):
        return False
    if port_in_use(port):
        pid_file = root / "spawner.pid"
        pid = int(pid_file.read_text()) if pid_file.exists() else None
        if pid is None or not stop_process(pid, "coder-opencode/spawner-"):
            raise RuntimeError(f"port {port} is held by a process that is not the spawner")
    script = root / f"spawner-{revision[:12]}.py"
    script.write_bytes(spawner_source)
    settings = {"port": port, "binary": str(binary), "state": str(root / "state"), "revision": revision}
    with (root / "spawner.log").open("ab") as log:
        child = subprocess.Popen(
            [sys.executable, "-I", str(script), json.dumps(settings)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
        )
    (root / "spawner.pid").write_text(str(child.pid))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError("OpenCode spawner exited; see spawner.log")
        if healthy(port, revision):
            return True
        time.sleep(0.25)
    raise RuntimeError("OpenCode spawner did not become healthy; see spawner.log")


def stop_process(pid, marker):
    try:
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
    except FileNotFoundError:
        return False
    if marker.encode() not in cmdline:
        return False
    os.killpg(pid, 15)
    for _ in range(40):
        if not Path(f"/proc/{pid}").exists():
            break
        time.sleep(0.25)
    return True


def main(raw, spawner_source):
    config = configuration(raw)
    home = Path.home()
    root = home / ".local" / "share" / "coder-opencode"
    root.mkdir(parents=True, exist_ok=True)
    binary = install(root, config["version"], os.environ.get("GH_TOKEN"))
    link(binary, home)
    restarted = start_spawner(root, config, spawner_source, binary)
    print(f"OpenCode {config['version']} ready; spawner on 127.0.0.1:{config['port']}" + (" (restarted)" if restarted else ""))


if __name__ == "__main__":
    try:
        main(
            json.loads(base64.b64decode(sys.argv[1], validate=True)),
            gzip.decompress(base64.b64decode(sys.argv[2], validate=True)),
        )
    except Exception as error:
        print(f"OpenCode startup failed: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
