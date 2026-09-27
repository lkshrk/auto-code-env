import base64
import hashlib
import json
import os
import shutil
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


def main():
    version, config = sys.argv[1], base64.b64decode(sys.argv[2]).decode()
    root = Path.home() / ".opencode-v2"
    changed = install(root, version)
    write(root / "config/opencode.json", config)
    write(root / "models.json", "{}\n")
    write(root / "worker.sh", WORKER, 0o755)
    print(f"OpenCode worker {version} {'installed' if changed else 'ready'}")


if __name__ == "__main__":
    main()
