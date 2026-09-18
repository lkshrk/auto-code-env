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


# Stack/tool composition and per-tool install-state verification are
# delegated to dotfiles' own coder-components.py resolver plus native
# `omni tools list` (see resolved_omni_config/omni_required_tools/
# check_omni_tools below); no separate stack/tool/version catalog is
# maintained in this repository.
# docker-engine is a daemon-reachability check, not a package-install state;
# omni has no concept of "is the daemon actually up", so it stays a genuine
# live subprocess check rather than something delegated to omni tools list.
DOCKER_ENGINE_COMMAND = ["docker", "info"]
OMNI_HOSTNAME = "coder-components"


def selection(value):
    return list(dict.fromkeys(part.strip() for part in value.split(",") if part.strip()))


def boolean(env, name):
    value = env.get(name, "0")
    if value not in {"0", "1"}:
        raise ValueError(f"{name} must be 0 or 1")
    return value == "1"


def configuration(env):
    # Stack and agent-client names are intentionally NOT validated or
    # alias-expanded here. dotfiles' coder-components.py --contract already
    # validates and resolves the real selection before this module ever
    # runs (see dotfiles-contract.py in the startup sequence); duplicating
    # that catalog here previously caused the same stack/tool list to drift
    # between the two repositories. Raw, unexpanded selection is reported
    # for visibility only.
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


def resolved_omni_config(dotfiles_dir, env, timeout=60):
    # The exact same resolver dotfiles' own setup-coder-components.sh calls
    # to build its Omni config for this workspace's real CODER_* selection.
    # Reusing it here (rather than re-deriving stack -> tool composition)
    # is the single source of truth for "what tools does this selection
    # require", eliminating the separate STACK_COMMANDS catalog that
    # previously had to be hand-kept in sync with dotfiles and already
    # caused real drift (e.g. omni_version defaults) between the two.
    result = subprocess.run(
        ["python3", str(Path(dotfiles_dir) / "scripts/coder-components.py")],
        env=env, capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise ValueError("dotfiles component resolution failed: " + result.stderr.strip())
    return json.loads(result.stdout)


def omni_required_tools(omni_config):
    return list(dict.fromkeys(
        tool for group in omni_config["groups"] for tool in group.get("tools", [])
    ))


def check_omni_tools(omni_config, tool_names, omni_binary="omni", timeout=60):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(omni_config, handle)
        config_path = handle.name
    try:
        result = subprocess.run(
            [omni_binary, "--config", config_path, "tools", "list", "--format", "json"],
            env={**os.environ, "OMNI_HOSTNAME": OMNI_HOSTNAME},
            capture_output=True, text=True, timeout=timeout,
        )
        if result.returncode != 0:
            raise ValueError("omni tools list failed: " + result.stderr.strip())
        reported = {entry["name"]: entry for entry in json.loads(result.stdout)}
    finally:
        os.unlink(config_path)
    # A tool absent from omni's own report (e.g. a transient omni bug, or a
    # tool name that exists in the config but omni silently skipped) counts
    # as not installed rather than silently passing.
    return {name: bool(reported.get(name, {}).get("installed", False)) for name in tool_names}


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
    dotfiles_dir = os.environ.get("CODER_DOTFILES_SOURCE_DIR", "")
    if not dotfiles_dir:
        parser.error("CODER_DOTFILES_SOURCE_DIR is required for the check action")
    try:
        omni_config = resolved_omni_config(dotfiles_dir, os.environ)
        tool_names = omni_required_tools(omni_config)
        report["checks"] = check_omni_tools(omni_config, tool_names)
    except ValueError as error:
        parser.error(str(error))
    if config["docker"]:
        report["checks"].update(check_commands({"docker-engine": DOCKER_ENGINE_COMMAND}))
    report["ready"] = all(report["checks"].values())
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
