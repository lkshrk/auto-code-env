#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PYTHON'
import json
import re
import shutil
import sys
from pathlib import Path


def fail(message):
    raise SystemExit(message)


if len(sys.argv) not in {3, 5}:
    fail("Usage: package-template.sh TEMPLATE_DIR NEW_OUTPUT_DIR [--backend docker|kubernetes]")
override = None
if len(sys.argv) == 5:
    if sys.argv[3] != "--backend" or sys.argv[4] not in {"docker", "kubernetes"}:
        fail("Invalid backend override")
    override = sys.argv[4]

source = Path(sys.argv[1]).absolute()
output = Path(sys.argv[2]).absolute()
templates = source.parent
coder = templates.parent
if override is not None and source.name != "dev":
    fail("Backend overrides are restricted to the dev definition")
generated = "environment.auto.tfvars.json"
if source.name == "dev" and ((source / generated).exists() or (source / generated).is_symlink()):
    fail(f"Source collides with generated configuration: {generated}")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", source.name):
    fail("Invalid template name")
if source.name in {"backends", "shared", "tests"} or not (source / "main.tf").is_file():
    fail("Template must contain main.tf")
if output.exists() or output.is_symlink():
    fail("Output path must not exist")
if not output.parent.is_dir():
    fail("Output parent directory must exist")
if output.resolve().is_relative_to(coder.resolve()):
    fail("Output must be outside the Coder source tree")

marker = source / "backend"
backend = override if override is not None else (marker.read_text().strip() if marker.exists() else "kubernetes")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", backend):
    fail("Invalid backend marker")

files = [templates / "common.tf", templates / "backends" / f"{backend}.tf"]
files.extend(sorted(source.glob("*.tf")))
trees = [templates / "shared"]
if (coder / "modules").exists() or (coder / "modules").is_symlink():
    trees.append(coder / "modules")
if len({path.name for path in files}) != len(files):
    fail("Template Terraform files collide with common or backend files")
for path in [source, templates, coder, templates / "backends", marker, *files, *trees]:
    if path.is_symlink():
        fail(f"Symlinks are not supported: {path}")
for path in files:
    if not path.is_file():
        fail(f"Missing Terraform file: {path}")
for path in trees:
    if not path.is_dir():
        fail(f"Missing source directory: {path}")
    for child in path.rglob("*"):
        if child.is_symlink() or not (child.is_file() or child.is_dir()):
            fail(f"Unsupported source entry: {child}")

output.mkdir()
try:
    for path in files:
        shutil.copy2(path, output / path.name)
    for path in trees:
        shutil.copytree(path, output / path.name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".git", ".terraform"))
    if marker.exists() and override is None:
        shutil.copy2(marker, output / "backend")
    else:
        (output / "backend").write_text(f"{backend}\n")
    if source.name == "dev":
        (output / generated).write_text(json.dumps({"environment_mode_default": "composable"}, sort_keys=True) + "\n")
except BaseException:
    shutil.rmtree(output)
    raise
PYTHON
