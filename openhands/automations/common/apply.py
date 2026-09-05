#!/usr/bin/env python3
"""Create or update an OpenHands automation from a spec directory."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import bootstrap


DEFAULT_URL = "http://openhands.ai.svc.cluster.local:8000"
PATCHABLE = ("name", "model", "prompt", "trigger", "timeout", "keep_alive", "enabled")


def request(method, url, key, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Session-API-Key", key)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> {e.code}: {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        sys.exit(f"{method} {url} -> {e.reason}")


def find_automation(base, key, name):
    offset = 0
    while True:
        page = request("GET", f"{base}/api/automation/v1?limit=100&offset={offset}", key)
        items = page.get("automations", [])
        for item in items:
            if item.get("name") == name:
                return item
        offset += len(items)
        if not items or offset >= page.get("total", 0):
            return None


def render(spec_file, prompt_file, overrides=None):
    body = json.loads(Path(spec_file).read_text())
    prompt = Path(prompt_file).read_text()
    variables = body.pop("vars", {}) | (overrides or {})
    for name, value in variables.items():
        prompt = prompt.replace(name, str(value))
    if body.pop("bootstrap", False):
        directory = Path(spec_file).parent / "bootstrap"
        for name in bootstrap.FILES:
            if not (directory / name).is_file():
                raise ValueError(f"Missing bootstrap file: {name}")
        prompt = prompt.replace("BOOTSTRAP_BIN", bootstrap.bin_path(directory))
        body["setup_script_path"] = bootstrap.SETUP
    body["prompt"] = prompt
    return body


def deploy(base, key, body, spec_dir):
    existing = find_automation(base, key, body["name"])
    action = "updated" if existing else "created"
    with_bootstrap = body.get("setup_script_path") == bootstrap.SETUP
    if not existing:
        creation = {k: v for k, v in body.items() if k != "setup_script_path"}
        if with_bootstrap:
            creation["enabled"] = False
        existing = request("POST", f"{base}/api/automation/v1/preset/prompt", key, creation)
        if not with_bootstrap:
            return existing, action
    patch = {k: v for k, v in body.items() if k in PATCHABLE}
    if with_bootstrap:
        patch["tarball_path"] = bootstrap.attach(base, key, existing, spec_dir / "bootstrap")
        patch["setup_script_path"] = bootstrap.SETUP
    result = request("PATCH", f"{base}/api/automation/v1/{existing['id']}", key, patch)
    return result, action


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec_dir", type=Path)
    parser.add_argument("--file", default="automation.json")
    parser.add_argument("--prompt", default="prompt.md")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    body = render(args.spec_dir / args.file, args.spec_dir / args.prompt)

    if args.dry_run:
        print(json.dumps(body, indent=2))
        return

    base = os.environ.get("OPENHANDS_URL", DEFAULT_URL).rstrip("/")
    key = os.environ.get("OPENHANDS_SESSION_API_KEY")
    if not key:
        sys.exit("OPENHANDS_SESSION_API_KEY is not set")

    result, action = deploy(base, key, body, args.spec_dir)

    print(f"{action} {result['name']} id={result['id']} enabled={result['enabled']}")


if __name__ == "__main__":
    main()
