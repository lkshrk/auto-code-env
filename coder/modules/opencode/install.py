import base64
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

PACKAGE = "@opencode/cli-linux-x64"
REGISTRY = "https://registry.npmjs.org"
# The empty models.dev catalog keeps built-in providers out: without it `opencode acp`
# can snapshot its model list before the config provider loads (anomalyco/opencode#50236).
WORKER = """#!/bin/sh
d=$HOME/.opencode-v2
export XDG_DATA_HOME=$d/data XDG_STATE_HOME=$d/state XDG_CACHE_HOME=$d/cache
export OPENCODE_CONFIG_DIR=$d/config OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_MODELS_PATH=$d/models.json OPENCODE_DISABLE_MODELS_FETCH=1
exec $d/opencode "$@"
"""


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.chmod(mode)
    tmp.replace(path)


def install(root, version):
    marker = root / "version"
    if marker.exists() and marker.read_text().strip() == version and (root / "opencode").exists():
        return False
    with urllib.request.urlopen(f"{REGISTRY}/{PACKAGE.replace('/', '%2f')}/{version}", timeout=30) as response:
        dist = json.load(response)["dist"]
    algorithm, digest = dist["integrity"].split("-", 1)
    if algorithm != "sha512":
        raise RuntimeError(f"{PACKAGE}@{version} has no sha512 integrity")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "package.tgz"
        with urllib.request.urlopen(dist["tarball"], timeout=600) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        if base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() != digest:
            raise RuntimeError(f"{PACKAGE}@{version} failed the registry integrity check")
        with tarfile.open(archive) as tar:
            tar.extractall(tmp, filter="data")
        binary = Path(tmp) / "package/bin/opencode"
        target = root / f"opencode-{version}"
        root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, target)
        target.chmod(0o755)
    link = root / "opencode"
    tmp_link = root / "opencode.tmp"
    tmp_link.unlink(missing_ok=True)
    tmp_link.symlink_to(target.name)
    tmp_link.replace(link)
    for old in root.glob("opencode-*"):
        if old != target:
            old.unlink(missing_ok=True)
    marker.write_text(version + "\n")
    return True


def tool_env():
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(Path.home() / ".local/bin"), env.get("PATH", "")])
    return env


def run(*args, env=None):
    subprocess.run(list(args), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=900, env=env or tool_env())


def install_rtk(tools, version):
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[platform.machine().lower()]
    libc = "musl" if arch == "x86_64" else "gnu"
    name = f"rtk-{arch}-unknown-linux-{libc}.tar.gz"
    with urllib.request.urlopen(f"https://api.github.com/repos/rtk-ai/rtk/releases/tags/v{version}", timeout=30) as response:
        asset = next(a for a in json.load(response)["assets"] if a["name"] == name)
    digest = asset.get("digest") or ""
    if not digest.startswith("sha256:"):
        raise RuntimeError(f"{name} has no sha256 digest")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / name
        with urllib.request.urlopen(asset["browser_download_url"], timeout=300) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest.removeprefix("sha256:"):
            raise RuntimeError(f"{name} failed the release digest check")
        with tarfile.open(archive) as tar:
            tar.extractall(tmp, filter="data")
        binary = next(Path(tmp).rglob("rtk"))
        target = tools / "bin/rtk"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, target)
        target.chmod(0o755)


def install_context_mode(tools, version):
    prefix = tools / "context-mode"
    run("npm", "install", "--silent", "--no-fund", "--no-audit", "--prefix", str(prefix), f"context-mode@{version}")
    link(tools / "bin/context-mode", prefix / "node_modules/.bin/context-mode")


def install_codegraphcontext(tools, version):
    env = tool_env()
    env.update(UV_TOOL_DIR=str(tools / "uv"), UV_TOOL_BIN_DIR=str(tools / "bin"))
    run("uv", "tool", "install", "--force", "--quiet", f"codegraphcontext=={version}", env=env)


def link(path, target):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists():
        path.unlink()
    path.symlink_to(target)


def ignore_globally(pattern):
    path = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "git/ignore"
    lines = path.read_text().splitlines() if path.exists() else []
    if pattern not in lines:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join([*lines, pattern]) + "\n")


def install_tools(root, versions):
    tools = root / "tools"
    results = []
    for name, installer in (("rtk", install_rtk), ("context_mode", install_context_mode), ("codegraphcontext", install_codegraphcontext)):
        marker = tools / f"{name}.version"
        if marker.exists() and marker.read_text().strip() == versions[name]:
            results.append(f"{name} ready")
            continue
        try:
            installer(tools, versions[name])
            marker.write_text(versions[name] + "\n")
            results.append(f"{name} {versions[name]} installed")
        except Exception as error:
            # One tool failing must not keep OpenCode from starting.
            results.append(f"{name} failed: {error}")
    link(Path.home() / ".local/bin/rtk", tools / "bin/rtk")
    # CodeGraphContext writes .cgcignore into every repository it indexes.
    ignore_globally(".cgcignore")
    return results


def git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120)


def sync_shared(root, shared):
    checkout = root / "shared"
    origin = subprocess.run(["git", "remote", "get-url", "origin"], cwd=checkout, capture_output=True, text=True).stdout.strip() if (checkout / ".git").exists() else ""
    if origin == shared["repo"]:
        git("fetch", "--quiet", "--depth", "1", "origin", shared["ref"], cwd=checkout)
        git("reset", "--quiet", "--hard", "FETCH_HEAD", cwd=checkout)
    else:
        shutil.rmtree(checkout, ignore_errors=True)
        git("clone", "--quiet", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", shared["ref"], shared["repo"], str(checkout))
        git("sparse-checkout", "set", shared["path"], cwd=checkout)
    return checkout / shared["path"]


def link_shared(config, source):
    for name in ("agents", "commands", "skills", "plugins", "AGENTS.md"):
        link = config / name
        target = source / name
        if link.is_symlink():
            link.unlink()
        if target.exists() and not link.exists():
            link.symlink_to(target)


def main():
    version, config = sys.argv[1], base64.b64decode(sys.argv[2]).decode()
    shared = json.loads(base64.b64decode(sys.argv[3]))
    versions = json.loads(base64.b64decode(sys.argv[4]))
    root = Path.home() / ".opencode-v2"
    changed = install(root, version)
    # Tools first: a running OpenCode reloads the config at once and connects its MCP servers.
    tools = install_tools(root, versions)
    write(root / "config/opencode.json", config)
    write(root / "models.json", "{}\n")
    write(root / "worker.sh", WORKER, 0o755)
    bin_link = Path.home() / ".local/bin/opencode"
    bin_link.parent.mkdir(parents=True, exist_ok=True)
    if bin_link.is_symlink() or not bin_link.exists():
        bin_link.unlink(missing_ok=True)
        bin_link.symlink_to(root / "worker.sh")
    try:
        source = sync_shared(root, shared)
        link_shared(root / "config", source)
        state = "synced"
    except (subprocess.SubprocessError, OSError) as error:
        # A failed sync keeps the last checkout; OpenCode still starts with it.
        state = f"sync failed ({error}), using last checkout"
        if (root / "shared" / shared["path"]).exists():
            link_shared(root / "config", root / "shared" / shared["path"])
    print(f"OpenCode {version} {'installed' if changed else 'ready'}; shared config {state}; {', '.join(tools)}")


if __name__ == "__main__":
    main()
