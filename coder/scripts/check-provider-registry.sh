#!/usr/bin/env bash
# Coder's provisioner resolves providers on registry.terraform.io, while CI
# validates with OpenTofu against its own registry; a pin that exists only on
# one of them passes validation and then fails `coder templates push`.
set -euo pipefail

if (( $# == 0 )); then
  printf 'Usage: check-provider-registry.sh FILE.tf [FILE.tf ...]\n' >&2
  exit 1
fi

python3 - "$@" <<'PY'
import json, re, sys, urllib.request

block = re.compile(r'required_providers\s*\{(.*?)\n\s*\}', re.S)
entry = re.compile(r'(\w+)\s*=\s*\{\s*source\s*=\s*"([^"]+)"\s*version\s*=\s*"([^"]+)"', re.S)
status = 0
seen = set()
for path in sys.argv[1:]:
    text = open(path).read()
    for body in block.findall(text):
        for _, source, version in entry.findall(body):
            if (source, version) in seen:
                continue
            seen.add((source, version))
            if not re.fullmatch(r'\d+\.\d+\.\d+', version):
                print(f"{path}: {source} pin {version!r} is a constraint, not an exact version; skipped")
                continue
            url = f"https://registry.terraform.io/v1/providers/{source}/versions"
            with urllib.request.urlopen(url, timeout=30) as resp:
                versions = {v["version"] for v in json.load(resp)["versions"]}
            if version in versions:
                print(f"{path}: {source} {version} available on registry.terraform.io")
            else:
                latest = max((v for v in versions if re.fullmatch(r'\d+\.\d+\.\d+', v)),
                             key=lambda s: tuple(map(int, s.split("."))), default="?")
                print(f"{path}: {source} {version} is NOT on registry.terraform.io (latest there: {latest}); "
                      f"the Coder provisioner cannot install it", file=sys.stderr)
                status = 1
sys.exit(status)
PY
