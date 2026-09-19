import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


# Tool readiness is install-stacks.py's own responsibility now: it runs
# earlier in the bootstrap and its final_check() already raises (aborting
# the whole `set -euo pipefail` startup script) on any missing/broken
# component before this module's "check" action ever runs. Re-deriving
# and re-checking the same tool set here would just duplicate that work
# for no benefit -- see install-stacks.py's own final_check().
# docker-engine is a daemon-reachability check, not a package-install state;
# omni has no concept of "is the daemon actually up", so it stays a genuine
# live subprocess check here.
DOCKER_ENGINE_COMMAND = ["docker", "info"]


def selection(value):
    return list(dict.fromkeys(part.strip() for part in value.split(",") if part.strip()))


def boolean(env, name):
    value = env.get(name, "0")
    if value not in {"0", "1"}:
        raise ValueError(f"{name} must be 0 or 1")
    return value == "1"


def configuration(env):
    # Stack and agent-client names are intentionally NOT validated or
    # alias-expanded here. install-stacks.py's own contract() already
    # validates and resolves the real selection before this module's
    # "check" action ever runs; duplicating that catalog here previously
    # caused the same stack/tool list to drift between this file and
    # dotfiles. Raw, unexpanded selection is reported for visibility only.
    stacks = selection(env.get("CODER_OMNI_STACKS", ""))
    agents = selection(env.get("CODER_AGENT_CLIENTS", ""))
    backend = env.get("CODER_BACKEND", "kubernetes")
    if backend not in {"kubernetes", "docker"}:
        raise ValueError("Backend must be kubernetes or docker")
    plugins = boolean(env, "CODER_AGENT_PLUGINS")
    if plugins and not agents:
        raise ValueError("Agent plugins require a selected agent client")
    return {
        "stacks": stacks,
        "agents": agents,
        "backend": backend,
        "plugins": plugins,
        "docker": boolean(env, "CODER_ENABLE_DIND"),
    }


def check_commands(commands, timeout=30):
    results = {}
    for name, command in commands.items():
        try:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
            results[name] = result.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            results[name] = False
    return results


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".readiness-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(report, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def wait_repositories(directory, keys, start_id, timeout=300):
    if not keys:
        return True
    if not re.fullmatch(r"[a-f0-9-]{36}", start_id) or any(not re.fullmatch(r"[a-f0-9]{64}", key) for key in keys):
        raise ValueError("Invalid repository startup identity")
    pending = [directory / start_id / key for key in keys]
    deadline = time.monotonic() + timeout
    while True:
        pending = [path for path in pending if not path.is_file()]
        if not pending:
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(1, remaining))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["validate", "check", "wait-repositories"])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        config = configuration(os.environ)
    except ValueError as error:
        parser.error(str(error))
    if args.action == "wait-repositories":
        try:
            ready = wait_repositories(
                Path.home() / ".local/state/coder-environment/clones",
                selection(os.environ.get("CODER_REPO_KEYS", "")),
                os.environ.get("CODER_START_ID", ""),
            )
        except ValueError as error:
            parser.error(str(error))
        if not ready:
            print("Repository preparation timed out; inspect Coder Git Clone logs", file=sys.stderr)
        return 0 if ready else 1
    report = {
        "ready": False,
        "configuration": config,
        "start_id": os.environ.get("CODER_START_ID", "unknown"),
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "dotfiles_revision": os.environ.get("CODER_DOTFILES_REVISION", "unknown"),
    }
    if args.action == "validate":
        if args.report:
            write_report(args.report, report)
        return 0
    report["checks"] = {}
    if config["docker"]:
        report["checks"].update(check_commands({"docker-engine": DOCKER_ENGINE_COMMAND}))
    report["ready"] = all(report["checks"].values()) if report["checks"] else True
    if args.report:
        write_report(args.report, report)
    failed = [name for name, passed in report["checks"].items() if not passed]
    if failed:
        print("Required component checks failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("Required workspace components are ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
