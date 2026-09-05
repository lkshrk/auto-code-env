#!/usr/bin/env python3
"""Dispatch a dry run of an automation spec and assert on the agent's final report."""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply import DEFAULT_URL, find_automation, render, request  # noqa: E402

TERMINAL = {"COMPLETED", "FAILED", "CANCELLED", "TIMEOUT"}


def wait_for_run(base, key, automation_id, run_id, timeout):
    deadline = time.monotonic() + timeout
    phase = None
    while time.monotonic() < deadline:
        runs = request("GET", f"{base}/api/automation/v1/{automation_id}/runs?limit=20", key)["runs"]
        run = next(r for r in runs if r["id"] == run_id)
        if run.get("current_phase") != phase:
            phase = run.get("current_phase")
            print(f"  phase: {phase}")
        if run["status"] in TERMINAL:
            return run
        time.sleep(15)
    sys.exit(f"run {run_id} did not finish within {timeout}s")


def final_message(base, key, conversation_id):
    page = None
    message = None
    while True:
        url = f"{base}/api/conversations/{conversation_id}/events/search?limit=100"
        if page:
            url += f"&page_id={urllib.parse.quote(page)}"
        data = request("GET", url, key)
        for event in data["items"]:
            if event.get("kind") == "ActionEvent" and event.get("tool_name") == "finish":
                message = event["action"].get("message", "")
        page = data.get("next_page_id")
        if not page:
            return message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec_dir", type=Path)
    parser.add_argument("--file", default="automation.json")
    parser.add_argument("--prompt", default="prompt.md")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    body = render(args.spec_dir / args.file, args.spec_dir / args.prompt)
    smoke = json.loads((args.spec_dir / "smoke.json").read_text())
    for name, value in smoke["vars"].items():
        body["prompt"] = body["prompt"].replace(name, str(value))
    body["name"] = f"{body['name']}-smoke"
    body["enabled"] = True
    body["timeout"] = min(args.timeout, body["timeout"])

    base = os.environ.get("OPENHANDS_URL", DEFAULT_URL).rstrip("/")
    key = os.environ.get("OPENHANDS_SESSION_API_KEY")
    if not key:
        sys.exit("OPENHANDS_SESSION_API_KEY is not set")

    existing = find_automation(base, key, body["name"])
    if existing:
        request("DELETE", f"{base}/api/automation/v1/{existing['id']}", key)
    automation = request("POST", f"{base}/api/automation/v1/preset/prompt", key, body)
    automation_id = automation["id"]
    print(f"created {body['name']} id={automation_id}")

    failures = []
    try:
        run = request("POST", f"{base}/api/automation/v1/{automation_id}/dispatch", key)
        print(f"dispatched run {run['id']}")
        run = wait_for_run(base, key, automation_id, run["id"], args.timeout)
        print(f"run {run['status']} cost={run.get('cost')}")
        if run["status"] != "COMPLETED":
            failures.append(f"run status {run['status']}: {run.get('error_detail')}")
        message = final_message(base, key, run["conversation_id"]) if run.get("conversation_id") else None
        if message is None:
            failures.append("agent never called finish")
            message = ""
        print("--- final report ---")
        print(message)
        print("--------------------")
        for pattern in smoke.get("expect", []):
            if not re.search(pattern, message, re.MULTILINE):
                failures.append(f"report lacks /{pattern}/")
        for pattern in smoke.get("forbid", []):
            if re.search(pattern, message, re.MULTILINE):
                failures.append(f"report contains forbidden /{pattern}/")
    finally:
        if not args.keep:
            request("DELETE", f"{base}/api/automation/v1/{automation_id}", key)
            print(f"deleted {body['name']}")

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
