#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PYTHON'
import re
import subprocess
import sys
from pathlib import Path


def fail(message):
    raise SystemExit(message)


if len(sys.argv) not in {3, 5}:
    fail("Usage: select-templates.sh REPO_ROOT all | REPO_ROOT changed BASE HEAD")
root = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
if (mode == "all" and len(sys.argv) != 3) or (mode == "changed" and len(sys.argv) != 5):
    fail("Invalid arguments for selection mode")
if mode not in {"all", "changed"}:
    fail("Invalid selection mode")
templates = root / "coder/templates"
if not templates.is_dir():
    fail("Missing coder/templates directory")

candidates = set()
for main in templates.glob("*/main.tf"):
    name = main.parent.name
    if name in {"backends", "shared", "tests"}:
        continue
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
        fail(f"Invalid template name: {name!r}")
    if main.is_file():
        candidates.add(name)

selected = candidates.copy() if mode == "all" else set()
if mode == "changed":
    try:
        commits = [
            subprocess.check_output(
                ["git", "-C", str(root), "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
                text=True,
            ).strip()
            for ref in sys.argv[3:5]
        ]
        changed = subprocess.check_output(
            ["git", "-C", str(root), "diff", "--name-only", "--no-renames", "-z", f"{commits[0]}...{commits[1]}", "--"]
        ).decode("utf-8", errors="surrogateescape").split("\0")
    except subprocess.CalledProcessError as error:
        fail(f"Cannot determine changed templates (git exited {error.returncode})")
    for path in changed:
        if path == ".github/workflows/coder-templates.yaml" or path.startswith(("coder/modules/", "coder/scripts/")):
            selected = candidates.copy()
            break
        if not path.startswith("coder/templates/"):
            continue
        parts = path.split("/")
        if len(parts) == 3 or parts[2] in {"backends", "shared", "tests"}:
            selected = candidates.copy()
            break
        if parts[2] in candidates:
            selected.add(parts[2])

for name in sorted(selected):
    print(f"coder/templates/{name}")
PYTHON
