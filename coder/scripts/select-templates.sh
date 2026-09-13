#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PYTHON'
import json
import re
import subprocess
import sys
from pathlib import Path


def fail(message):
    raise SystemExit(message)


def changed_paths(root, refs):
    try:
        commits = [
            subprocess.check_output(
                ["git", "-C", str(root), "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
                text=True,
            ).strip()
            for ref in refs
        ]
        return subprocess.check_output(
            ["git", "-C", str(root), "diff", "--name-only", "--no-renames", "-z", f"{commits[0]}...{commits[1]}", "--"]
        ).decode("utf-8", errors="surrogateescape").split("\0")
    except subprocess.CalledProcessError as error:
        fail(f"Cannot determine changed templates (git exited {error.returncode})")


def shared_change(path):
    if path in {".github/workflows/coder-templates.yaml", "coder/targets.json"} or path.startswith(("coder/modules/", "coder/scripts/")):
        return True
    parts = path.split("/")
    return path.startswith("coder/templates/") and (len(parts) == 3 or parts[2] in {"backends", "shared", "tests"})


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"Duplicate catalog key: {key}")
        result[key] = value
    return result


def target_catalog(root):
    path = root / "coder/targets.json"
    if path.is_symlink():
        fail("Target catalog must not be a symlink")
    try:
        catalog = json.loads(path.read_text(), object_pairs_hook=unique_object)
    except (OSError, ValueError) as error:
        fail(f"Cannot read target catalog: {error}")
    if not isinstance(catalog, dict) or set(catalog) != {"version", "targets"} or type(catalog["version"]) is not int or catalog["version"] != 1:
        fail("Invalid target catalog schema")
    targets = catalog["targets"]
    if not isinstance(targets, dict) or not targets:
        fail("Target catalog must contain targets")
    for name, target in targets.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name) or name in {"backends", "shared", "tests"}:
            fail(f"Invalid target name: {name!r}")
        if not isinstance(target, dict) or set(target) != {"source", "backend"}:
            fail(f"Invalid target entry: {name}")
        if target["source"] != "dev" or target["backend"] not in ("docker", "kubernetes"):
            fail("Targets must use dev with an explicit Docker or Kubernetes backend")
        if not (root / "coder/templates/dev/main.tf").is_file():
            fail(f"Missing target source: {target['source']}")
    return targets


if len(sys.argv) < 3:
    fail("Usage: select-templates.sh REPO_ROOT targets|targets-changed BASE HEAD")
root = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
counts = {"targets": 3, "targets-changed": 5}
if mode not in counts or len(sys.argv) != counts[mode]:
    fail("Invalid selection mode or arguments")
targets = target_catalog(root)
changed = changed_paths(root, sys.argv[3:5]) if mode == "targets-changed" else []
for name, target in sorted(targets.items()):
    if mode == "targets" or any(shared_change(path) or path.startswith(f"coder/templates/{target['source']}/") for path in changed):
        print(f"{name}\tcoder/templates/{target['source']}\t{target['backend']}")
PYTHON
