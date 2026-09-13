#!/usr/bin/env python3
"""Private snapshots of active agent settings and conversation defaults."""

import argparse
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request


FORMAT = "openhands-settings-snapshot"
LIMIT = 16 * 1024 * 1024
NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,63}\Z")


class Failure(Exception):
    pass


def require(condition):
    if not condition:
        raise Failure("Invalid or unsupported snapshot/settings contract.")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def decode(raw):
    require(len(raw) <= LIMIT)
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda _: require(False))


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o077)
        raw = stream.read(LIMIT + 1)
        require(len(raw) <= LIMIT)
        return raw


def api_url(value):
    try:
        url = urllib.parse.urlsplit(value)
        require(url.scheme in ("http", "https") and bool(url.hostname))
        require("@" not in url.netloc and "?" not in value and "#" not in value)
        require(url.path in ("", "/") and not any(c.isspace() for c in value))
        require(not any(ord(c) < 32 for c in value) and "\\" not in value)
        require(url.port is None or 1 <= url.port <= 65535)
        if url.scheme == "http":
            require(ipaddress.ip_address(url.hostname).is_loopback)
        return value.rstrip("/")
    except (ValueError, Failure):
        raise Failure("API must be an HTTPS origin or literal loopback HTTP origin.") from None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Failure("Invalid command arguments; use --help.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure("API redirect refused.")


class Client:
    def __init__(self, api, key_file):
        self.api = api_url(api)
        self.headers = {"Accept": "application/json"}
        if key_file:
            key = read_private(key_file).decode().strip()
            require(bool(key) and all(32 < ord(c) < 127 for c in key))
            self.headers["X-Session-API-Key"] = key
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, method, path, body=None, plaintext=False, text=False):
        headers = dict(self.headers)
        if plaintext:
            headers["X-Expose-Secrets"] = "plaintext"
        data = None
        if body is not None:
            data = json.dumps(body, allow_nan=False).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.api + path, data=data,
                                         headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=15) as response:
                raw = response.read(LIMIT + 1)
                require(len(raw) <= LIMIT)
                return raw.decode() if text else decode(raw)
        except urllib.error.HTTPError as error:
            raise Failure(f"API request failed (HTTP {error.code}).") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure("API request failed (transport error).") from None


def validate_settings(agent, conversation):
    require(isinstance(agent, dict) and isinstance(conversation, dict))
    require(type(agent.get("schema_version")) is int and agent["schema_version"] == 5)
    require(agent.get("agent_kind") in ("openhands", "acp"))
    common = {"schema_version", "agent_kind", "llm", "mcp_config", "agent_context"}
    variants = {
        "openhands": {"agent", "tools", "enable_sub_agents", "enable_switch_llm_tool",
                      "tool_concurrency_limit", "condenser", "verification"},
        "acp": {"acp_server", "acp_command", "acp_args", "acp_model", "acp_session_mode",
                "acp_prompt_timeout", "acp_startup_timeout", "acp_isolate_data_dir", "acp_file_secrets"},
    }
    require(set(agent) == common | variants[agent["agent_kind"]])
    require(isinstance(agent.get("llm"), dict) and isinstance(agent["llm"].get("model"), str))
    require(isinstance(agent.get("mcp_config"), dict))
    require(set(conversation) == {"schema_version", "max_iterations", "confirmation_mode", "security_analyzer"})
    require(type(conversation["schema_version"]) is int and conversation["schema_version"] == 1)
    require(type(conversation["max_iterations"]) is int and conversation["max_iterations"] > 0)
    require(type(conversation["confirmation_mode"]) is bool)
    require(conversation["security_analyzer"] in (None, "llm"))
    for server in agent["mcp_config"].values():
        require(isinstance(server, dict))
        require(isinstance(server.get("command") or server.get("url"), str))
    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, str):
            require(value != "**********")
        elif isinstance(value, float):
            require(math.isfinite(value))
    walk(agent)


def validate(snapshot):
    require(isinstance(snapshot, dict))
    require(set(snapshot) == {"format", "version", "agent_settings", "conversation_settings", "custom_secrets"})
    require(snapshot["format"] == FORMAT and type(snapshot["version"]) is int and snapshot["version"] == 1)
    validate_settings(snapshot["agent_settings"], snapshot["conversation_settings"])
    secrets = snapshot["custom_secrets"]
    require(secrets is None or isinstance(secrets, list))
    names = set()
    for secret in secrets or []:
        require(isinstance(secret, dict) and set(secret) == {"name", "value", "description"})
        name = secret["name"]
        require(isinstance(name, str) and NAME.fullmatch(name) and name not in names)
        names.add(name)
        require(isinstance(secret["value"], str))
        require(secret["description"] is None or isinstance(secret["description"], str))
    return snapshot


def replacement_patch(current, target):
    result = {key: None for key in current.keys() - target.keys()}
    for key, value in target.items():
        old = current.get(key)
        if isinstance(value, dict) and isinstance(old, dict):
            result[key] = replacement_patch(old, value)
        elif key not in current or old != value:
            result[key] = value
    return result


def plan(current, snapshot):
    agent = snapshot["agent_settings"]
    existing = current["agent_settings"]
    changed_kind = existing["agent_kind"] != agent["agent_kind"]
    patch = agent if changed_kind else replacement_patch(existing, agent)
    return {"agent_settings_diff": patch,
            "conversation_settings_diff": snapshot["conversation_settings"]}


def check_patch_fidelity(current, target, patch):
    base = current if current["agent_kind"] == target["agent_kind"] else {}

    def without_nulls(value):
        require(value is not None)
        if isinstance(value, dict):
            for item in value.values():
                without_nulls(item)
        elif isinstance(value, list):
            for item in value:
                without_nulls(item)

    def check(old, wanted, delta):
        for key, value in wanted.items():
            if key not in delta:
                continue
            if isinstance(value, dict) and isinstance(old.get(key), dict):
                check(old[key], value, delta[key])
            else:
                without_nulls(value)

    check(base, target, patch)


def counts(snapshot):
    print(f"Agent fields: {len(snapshot['agent_settings'])}; conversation fields: "
          f"{len(snapshot['conversation_settings'])}; custom secrets: "
          f"{len(snapshot['custom_secrets'] or [])}.")
    print("Custom secrets: included (upsert only)." if snapshot["custom_secrets"] is not None
          else "Custom secrets: omitted; restore is incomplete if these are required.")


def main(argv=None):
    parser = Parser(description=__doc__)
    parser.add_argument("command", choices=("backup", "restore", "preview"))
    parser.add_argument("file", type=Path)
    parser.add_argument("--api")
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--include-secrets", action="store_true")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    require(not args.apply or args.command == "restore")
    if args.command != "backup":
        snapshot = validate(decode(read_private(args.file)))
        counts(snapshot)
        if args.command == "preview" or not args.apply:
            print("Preview only; no API calls or changes.")
            return
        require(snapshot["custom_secrets"] is None or args.include_secrets)
    require(bool(args.api))
    client = Client(args.api, args.api_key_file)
    if args.command == "backup":
        fd = os.open(args.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as stream:
                current = client.call("GET", "/api/settings", plaintext=True)
                snapshot = {"format": FORMAT, "version": 1,
                            "agent_settings": current["agent_settings"],
                            "conversation_settings": current["conversation_settings"],
                            "custom_secrets": None}
                if args.include_secrets:
                    entries = client.call("GET", "/api/settings/secrets")["secrets"]
                    require(isinstance(entries, list))
                    snapshot["custom_secrets"] = []
                    for entry in entries:
                        name = entry["name"]
                        require(isinstance(name, str) and NAME.fullmatch(name))
                        value = client.call("GET", "/api/settings/secrets/" + name, text=True)
                        snapshot["custom_secrets"].append({"name": name, "description": entry.get("description"), "value": value})
                validate(snapshot)
                raw = (json.dumps(snapshot, indent=2, allow_nan=False) + "\n").encode("utf-8")
                require(len(raw) <= LIMIT)
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
        except Exception:
            args.file.unlink()
            raise
        counts(snapshot)
        print("Private plaintext backup created.")
        print("Restore eligibility is destination-dependent; changed explicit agent nulls are unsupported.")
        return
    current = client.call("GET", "/api/settings", plaintext=True)
    validate_settings(current["agent_settings"], current["conversation_settings"])
    payload = plan(current, snapshot)
    check_patch_fidelity(current["agent_settings"], snapshot["agent_settings"],
                         payload["agent_settings_diff"])
    client.call("PATCH", "/api/settings", payload)
    restored = client.call("GET", "/api/settings", plaintext=True)
    require(restored["agent_settings"] == snapshot["agent_settings"]
            and restored["conversation_settings"] == snapshot["conversation_settings"])
    for secret in snapshot["custom_secrets"] or []:
        client.call("PUT", "/api/settings/secrets", secret)
    print("Restore applied; unrelated custom secrets preserved.")


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print(str(error), file=sys.stderr)
        print("If applying a restore, changes may be partial; no rollback is automatic.", file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Operation failed; no details emitted. Restore may be partially applied.", file=sys.stderr)
        sys.exit(1)
