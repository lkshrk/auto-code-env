"""Add deterministic tool setup to a generated prompt preset package."""

import hashlib
import io
import json
import tarfile
import urllib.parse
import urllib.request


FILES = ("setup.py", "tools.lock.json")
SETUP = "setup.sh"
WRAPPER = b"#!/bin/sh\nexec python3 bootstrap/setup.py\n"


def bin_path(directory):
    lock = directory / "tools.lock.json"
    identity = hashlib.sha256(lock.read_bytes()).hexdigest()
    return f"$HOME/.openhands/toolchains/h-cloud-upgrader/{identity}/bin"


def package(source, directory):
    replacements = {f"bootstrap/{name}": (directory / name).read_bytes() for name in FILES}
    output = io.BytesIO()
    changed = False
    with tarfile.open(fileobj=io.BytesIO(source), mode="r:*") as old:
        members = old.getmembers()
        names = {member.name.removeprefix("./"): member for member in members}
        if "setup.sh" not in names or "prompt.txt" not in names:
            raise ValueError("Bootstrap requires the standard prompt preset package")
        setup = old.extractfile(names["setup.sh"]).read()
        if "bootstrap/sdk-setup.sh" not in names:
            replacements["bootstrap/sdk-setup.sh"] = setup
        elif setup != WRAPPER:
            raise ValueError("Packaged setup.sh was changed outside the bootstrap wrapper")
        # The dispatcher executes setup.sh regardless of setup_script_path metadata.
        replacements["setup.sh"] = WRAPPER
        with tarfile.open(fileobj=output, mode="w:gz") as new:
            for member in members:
                name = member.name.removeprefix("./")
                if name in replacements:
                    if not member.isfile():
                        raise ValueError(f"Expected regular file: {name}")
                    data = replacements.pop(name)
                    changed |= old.extractfile(member).read() != data
                    member.size = len(data)
                    new.addfile(member, io.BytesIO(data))
                else:
                    new.addfile(member, old.extractfile(member) if member.isfile() else None)
            for name, data in replacements.items():
                changed = True
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                new.addfile(member, io.BytesIO(data))
    return output.getvalue() if changed else None


def attach(base, key, automation, directory):
    if not automation["tarball_path"].startswith("oh-internal://uploads/"):
        raise ValueError("Expected an internally stored prompt preset tarball")
    url = f"{base}/api/automation/v1/{automation['id']}/tarball"
    headers = {"X-Session-API-Key": key}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        if response.url.split("/api/")[0] != base:
            raise ValueError("Expected an internally stored prompt preset tarball")
        source = response.read()
    updated = package(source, directory)
    if updated is None:
        return automation["tarball_path"]
    url = f"{base}/api/automation/v1/uploads?name={urllib.parse.quote(automation['name'] + '-bootstrap')}"
    headers["Content-Type"] = "application/gzip"
    with urllib.request.urlopen(urllib.request.Request(url, data=updated, headers=headers), timeout=60) as response:
        upload = json.load(response)
    if upload["status"] != "COMPLETED":
        raise RuntimeError(f"Bootstrap upload failed: {upload.get('error_message')}")
    return upload["tarball_path"]
