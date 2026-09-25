#!/usr/bin/env python3
"""Provision the locked Linux toolchain before the preset starts its agent."""

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def github(url, raw=False):
    token = next((os.environ[k] for k in ("GITHUB_TOKEN", "GH_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN")
                  if os.environ.get(k)), None)
    headers = {"Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        body = response.read().decode()
    return body if raw else json.loads(body)


def resolve(tool):
    follow = tool.get("follow")
    if follow is None:
        return tool
    source = github(f"https://api.github.com/repos/{follow['repo']}/contents/{follow['path']}", raw=True)
    match = re.search(follow["pattern"], source)
    if match is None:
        raise ValueError(f"{tool['name']}: no pin in {follow['repo']}/{follow['path']}")
    version = match.group(1)
    if version == tool["version"]:
        return tool
    bare = version.removeprefix("v")
    release = github(follow["release_api"].format(version=version))
    name = follow["asset"].format(bare=bare)
    asset = next((a for a in release["assets"] if a["name"] == name), None)
    if asset is None or not str(asset.get("digest", "")).startswith("sha256:"):
        raise ValueError(f"{tool['name']}: {version} has no {name} with a published sha256 digest")
    print(f"[tools] {tool['name']}: {follow['repo']} pins {version}, lock has {tool['version']}; "
          "following the repo, update the lock", flush=True)
    return tool | {"version": version, "version_match": bare, "url": asset["browser_download_url"],
                   "sha256": asset["digest"].removeprefix("sha256:"), "binary_sha256": None}


def cached(binary, record, tool):
    if not binary.is_file():
        return False
    if tool["binary_sha256"] is not None:
        return digest(binary) == tool["binary_sha256"]
    if not record.is_file():
        return False
    known = json.loads(record.read_text())
    return known["sha256"] == tool["sha256"] and known["binary_sha256"] == digest(binary)


def install_tool(tool, destination):
    binary = destination / tool["name"]
    record = destination / f".{tool['name']}.json"
    if cached(binary, record, tool):
        print(f"[tools] cached {tool['name']} {tool['version']}", flush=True)
    else:
        print(f"[tools] installing {tool['name']} {tool['version']}", flush=True)
        with tempfile.TemporaryDirectory(dir=destination) as tmp:
            archive = Path(tmp) / "download"
            with urllib.request.urlopen(tool["url"], timeout=120) as response:
                with archive.open("wb") as output:
                    shutil.copyfileobj(response, output)
            if digest(archive) != tool["sha256"]:
                raise ValueError(f"{tool['name']}: download checksum mismatch")
            candidate = Path(tmp) / "binary"
            if tool["member"] is None:
                archive.rename(candidate)
            else:
                with tarfile.open(archive) as bundle:
                    member = bundle.getmember(tool["member"])
                    if not member.isfile():
                        raise ValueError(f"{tool['name']}: archive member is not a regular file")
                    with bundle.extractfile(member) as source, candidate.open("wb") as output:
                        shutil.copyfileobj(source, output)
            if tool["binary_sha256"] is not None and digest(candidate) != tool["binary_sha256"]:
                raise ValueError(f"{tool['name']}: executable checksum mismatch")
            candidate.chmod(0o755)
            verify_version(candidate, tool)
            os.replace(candidate, binary)
            record.write_text(json.dumps({"sha256": tool["sha256"], "binary_sha256": digest(binary)}))
    verify_version(binary, tool)


def verify_version(binary, tool):
    result = subprocess.run(
        [str(binary), *tool["version_args"]], check=True,
        capture_output=True, text=True, timeout=30,
    )
    if tool["version_match"] not in result.stdout + result.stderr:
        raise ValueError(f"{tool['name']}: unexpected version output")


def install(lock_path, home):
    lock = json.loads(lock_path.read_text())
    actual = f"{platform.system().lower()}/{platform.machine()}"
    if actual != lock["platform"]:
        raise ValueError(f"Unsupported platform {actual}; lock requires {lock['platform']}")
    root = home / ".openhands/toolchains/h-cloud-upgrader" / digest(lock_path)
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".install.lock").open("w") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        destination = root / "bin"
        destination.mkdir(exist_ok=True)
        for tool in lock["tools"]:
            install_tool(resolve(tool), destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-only", action="store_true")
    args = parser.parse_args()
    for required in ("git", "curl", "bash"):
        if shutil.which(required) is None:
            raise RuntimeError(f"Base image prerequisite missing: {required}")
    directory = install(Path(__file__).with_name("tools.lock.json"), Path.home())
    os.environ["PATH"] = f"{directory}:{os.environ['PATH']}"
    if not args.tools_only:
        subprocess.run(["bash", "bootstrap/sdk-setup.sh"], check=True)
        subprocess.run([
            ".venv/bin/python", "-c",
            "import yaml; from packaging.version import Version; "
            "assert yaml.safe_load('a: &v 1\\nb: *v')['b'] == 1; "
            "assert Version('1.10') > Version('1.9')",
        ], check=True)
    print(f"[tools] ready: {directory}", flush=True)


if __name__ == "__main__":
    main()
