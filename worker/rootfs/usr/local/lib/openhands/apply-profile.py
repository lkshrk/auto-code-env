#!/usr/bin/env python3
"""Apply layered Agent Canvas settings profiles to a running backend."""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

SECTIONS = ("llm", "agent", "secrets", "skills", "git_sync", "mcp_servers", "agents")
MERGED_OBJECTS = ("llm", "agent", "git_sync", "agents")
MERGED_MAPS = ("secrets", "mcp_servers")
ACP_SERVERS = ("claude-code", "codex", "gemini-cli", "custom")
AGENT_KINDS = ("openhands", "acp")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SECRET_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,63}$")
MCP_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
HEADER_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
REPO_SHORTHAND = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
TARGET_NAME = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
AGENTS_MANIFEST_NAME = "openhands-worker"
LLM_API_KEY = "LLM_API_KEY"
GIT_SYNC_TOKEN = "GIT_SYNC_TOKEN"
STATE_DIRECTORY = "/var/lib/openhands/overlay"
TOKEN_STATE_FILE = "git-sync-token.sha256"
PROGRAM = os.path.basename(sys.argv[0]) or "apply-profile.py"


def fail(message):
    sys.stderr.write("%s: %s\n" % (PROGRAM, message))
    raise SystemExit(1)


def object_keys(name, value, allowed):
    if not isinstance(value, dict):
        fail("%s must be an object" % name)
    for key in value:
        if key not in allowed:
            fail("unknown key %s.%s" % (name, key))


def as_text(name, value):
    if not isinstance(value, str) or not value.strip():
        fail("%s must be a non-empty string" % name)
    return value


def as_item(name, value):
    if not isinstance(value, str) or not UUID.match(value):
        fail("%s must be a lowercase vault item UUID" % name)
    return value


def validate_llm(llm):
    object_keys("llm", llm, ("model", "base_url", "api_key_item"))
    if "model" in llm:
        as_text("llm.model", llm["model"])
    if "base_url" in llm:
        base_url = as_text("llm.base_url", llm["base_url"])
        if not base_url.startswith(("http://", "https://")):
            fail("llm.base_url must be an absolute HTTP URL")
    if "api_key_item" in llm:
        as_item("llm.api_key_item", llm["api_key_item"])


def validate_agent(agent):
    object_keys("agent", agent, ("kind", "acp_server", "acp_command", "acp_model"))
    kind = agent.get("kind")
    if kind is not None and kind not in AGENT_KINDS:
        fail("agent.kind must be one of %s" % ", ".join(AGENT_KINDS))
    if "acp_server" in agent and agent["acp_server"] not in ACP_SERVERS:
        fail("agent.acp_server must be one of %s" % ", ".join(ACP_SERVERS))
    if "acp_command" in agent:
        command = agent["acp_command"]
        if isinstance(command, str):
            command = [command]
        if not isinstance(command, list) or not command:
            fail("agent.acp_command must be a command string or argument array")
        for part in command:
            as_text("agent.acp_command entry", part)
        agent["acp_command"] = command
    if agent.get("acp_model") is not None:
        as_text("agent.acp_model", agent["acp_model"])
    acp_keys = [key for key in agent if key.startswith("acp_")]
    if acp_keys and kind != "acp":
        fail("agent.kind must be 'acp' to set %s" % ", ".join(sorted(acp_keys)))


def validate_secrets(secrets):
    if not isinstance(secrets, dict):
        fail("secrets must be an object")
    for name, spec in secrets.items():
        if not SECRET_NAME.match(name):
            fail("secret name %r must start with a letter and use letters, digits, underscores" % name)
        object_keys("secrets.%s" % name, spec, ("item", "prefix"))
        as_item("secrets.%s.item" % name, spec.get("item"))
        if "prefix" in spec and not isinstance(spec["prefix"], str):
            fail("secrets.%s.prefix must be a string" % name)


def validate_skills(skills):
    if not isinstance(skills, list) or not skills:
        fail("skills must be a non-empty array")
    for index, skill in enumerate(skills):
        label = "skills[%d]" % index
        object_keys(label, skill, ("source", "ref", "repo_path"))
        as_text("%s.source" % label, skill.get("source"))
        for key in ("ref", "repo_path"):
            if key in skill:
                as_text("%s.%s" % (label, key), skill[key])


def validate_mcp_servers(servers):
    if not isinstance(servers, dict):
        fail("mcp_servers must be an object")
    for name in servers:
        label = "mcp_servers.%s" % name
        if not MCP_NAME.match(name):
            fail("mcp_servers key %r must be a server name" % name)
        server = servers[name]
        object_keys(label, server, ("url", "headers", "command", "args"))
        if "url" in server:
            if "command" in server or "args" in server:
                fail("%s must set either url or command, not both" % label)
            url = as_text("%s.url" % label, server["url"])
            if not url.startswith(("http://", "https://")):
                fail("%s.url must be an absolute HTTP URL" % label)
            validate_mcp_headers(label, server.get("headers", {}))
        elif "command" in server:
            as_text("%s.command" % label, server["command"])
            args = server.get("args", [])
            if not isinstance(args, list):
                fail("%s.args must be an array" % label)
            for part in args:
                as_text("%s.args entry" % label, part)
        else:
            fail("%s must set url for a remote server or command for a stdio one" % label)


def validate_mcp_headers(label, headers):
    if not isinstance(headers, dict):
        fail("%s.headers must be an object" % label)
    for name in headers:
        if not HEADER_NAME.match(name):
            fail("%s.headers name %r is not an HTTP header name" % (label, name))
        value = headers[name]
        if isinstance(value, dict):
            object_keys("%s.headers.%s" % (label, name), value, ("secret",))
            reference = value.get("secret")
            if not isinstance(reference, str) or not SECRET_NAME.match(reference):
                fail("%s.headers.%s.secret must be a secret name" % (label, name))
        else:
            as_text("%s.headers.%s" % (label, name), value)


def validate_agents(agents):
    object_keys("agents", agents, ("repo", "ref", "path", "targets"))
    repo = as_text("agents.repo", agents.get("repo"))
    if not REPO_SHORTHAND.match(repo) and not repo.startswith("https://"):
        fail("agents.repo must be owner/name or an absolute HTTPS git URL")
    for key in ("ref", "path"):
        if key in agents:
            as_text("agents.%s" % key, agents[key])
    path = agents.get("path", "")
    if path.startswith("/") or ".." in path.split("/"):
        fail("agents.path must be a relative path inside the repository")
    targets = agents.get("targets")
    if not isinstance(targets, list) or not targets:
        fail("agents.targets must be a non-empty array")
    for target in targets:
        if not isinstance(target, str) or not TARGET_NAME.match(target):
            fail("agents.targets entry %r is not a harness name" % target)


def render_agents(agents):
    lines = [
        "name: %s" % AGENTS_MANIFEST_NAME,
        "version: 1.0.0",
        "dependencies:",
        "  apm:",
        "  - git: %s" % agents["repo"],
    ]
    if "path" in agents:
        lines.append("    path: %s" % agents["path"])
    if "ref" in agents:
        lines.append("    ref: %s" % agents["ref"])
    lines.append("targets:")
    for target in agents["targets"]:
        lines.append("- %s" % target)
    return "\n".join(lines)


def validate_git_sync(git_sync):
    object_keys(
        "git_sync",
        git_sync,
        ("repo_url", "branch", "path", "token_item", "interval_seconds"),
    )
    as_text("git_sync.repo_url", git_sync.get("repo_url"))
    for key in ("branch", "path"):
        if key in git_sync:
            as_text("git_sync.%s" % key, git_sync[key])
    if "token_item" in git_sync:
        as_item("git_sync.token_item", git_sync["token_item"])
    interval = git_sync.get("interval_seconds", 0)
    if not isinstance(interval, int) or isinstance(interval, bool) or interval < 0:
        fail("git_sync.interval_seconds must be a non-negative integer")


def load(path):
    try:
        with open(path) as handle:
            profile = json.load(handle)
    except ValueError as error:
        fail("invalid JSON in %s: %s" % (path, error))
    except OSError as error:
        fail("cannot read %s: %s" % (path, error))
    if not isinstance(profile, dict):
        fail("profile must be a JSON object")
    for key in profile:
        if key not in SECTIONS:
            fail("unknown section %s" % key)
    if "llm" in profile:
        validate_llm(profile["llm"])
    if "agent" in profile:
        validate_agent(profile["agent"])
    if "secrets" in profile:
        validate_secrets(profile["secrets"])
    if "skills" in profile:
        validate_skills(profile["skills"])
    if "git_sync" in profile:
        validate_git_sync(profile["git_sync"])
    if "mcp_servers" in profile:
        validate_mcp_servers(profile["mcp_servers"])
    if "agents" in profile:
        validate_agents(profile["agents"])
    return profile


def skill_key(skill):
    return skill.get("repo_path") or skill["source"]


def merge(profiles):
    merged = {}
    for profile in profiles:
        for key in profile:
            value = profile[key]
            if key == "skills":
                index = {}
                for skill in list(merged.get("skills") or []) + value:
                    index[skill_key(skill)] = skill
                merged["skills"] = list(index.values())
            elif key in MERGED_OBJECTS or key in MERGED_MAPS:
                section = dict(merged.get(key) or {})
                section.update(value)
                merged[key] = section
            else:
                merged[key] = value
    return merged


def load_all(paths, skip):
    profile = merge([load(path) for path in paths])
    dropped = sorted(section for section in skip if section in profile)
    for section in dropped:
        del profile[section]
    secrets = profile.get("secrets") or {}
    for name in profile.get("mcp_servers") or {}:
        headers = (profile["mcp_servers"][name] or {}).get("headers") or {}
        for header in headers:
            value = headers[header]
            if isinstance(value, dict) and value["secret"] not in secrets:
                fail(
                    "mcp_servers.%s.headers.%s references undeclared secret %s"
                    % (name, header, value["secret"])
                )
    return profile, dropped


def wanted_secrets(profile):
    wanted = []
    llm = profile.get("llm") or {}
    if "api_key_item" in llm:
        wanted.append((LLM_API_KEY, llm["api_key_item"]))
    for name in sorted(profile.get("secrets") or {}):
        wanted.append((name, profile["secrets"][name]["item"]))
    git_sync = profile.get("git_sync") or {}
    if "token_item" in git_sync:
        wanted.append((GIT_SYNC_TOKEN, git_sync["token_item"]))
    items = {}
    for name, item in wanted:
        if items.setdefault(name, item) != item:
            fail("secret %s is claimed by two different vault items" % name)
    return [(name, items[name]) for name in sorted(items)]


class Api:
    def __init__(self, base, key_path):
        self.base = base.rstrip("/")
        try:
            with open(key_path) as handle:
                key = handle.read().strip()
        except OSError as error:
            fail("cannot read the API key: %s" % error)
        if not key:
            fail("empty API key in %s" % key_path)
        self.key = key
        # An empty ProxyHandler keeps http_proxy from redirecting the backend call.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, method, path, body=None, headers=None):
        request = urllib.request.Request(self.base + path, method=method)
        request.add_header("X-Session-API-Key", self.key)
        for name in headers or {}:
            request.add_header(name, headers[name])
        if body is not None:
            request.add_header("Content-Type", "application/json")
            request.data = json.dumps(body).encode()
        try:
            with self.opener.open(request) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()
        except OSError as error:
            fail("%s %s failed: %s" % (method, path, error))

    def json_call(self, method, path, body=None, headers=None):
        status, text = self.call(method, path, body, headers)
        if not 200 <= status < 300:
            fail("%s %s returned HTTP %d" % (method, path, status))
        try:
            return json.loads(text) if text else {}
        except ValueError:
            fail("%s %s returned a non-JSON body" % (method, path))


def write_private(path, text):
    previous = os.umask(0o077)
    try:
        with open(path, "w") as handle:
            handle.write(text)
    finally:
        os.umask(previous)


def secret_reader(directory):
    cache = {}

    def read(name):
        if name not in cache:
            path = os.path.join(directory, name)
            try:
                with open(path) as handle:
                    cache[name] = handle.read()
            except OSError:
                fail("missing material for secret %s at %s" % (name, path))
        return cache[name]

    return read


def apply_agent_settings(api, profile, secret, settings):
    llm = profile.get("llm") or {}
    agent = profile.get("agent") or {}
    if not llm and not agent:
        return
    current_llm = settings.get("llm") or {}
    diff = {}
    llm_diff = {}
    for key in ("model", "base_url"):
        if key in llm and current_llm.get(key) != llm[key]:
            llm_diff[key] = llm[key]
    if "api_key_item" in llm:
        value = secret(LLM_API_KEY)
        if current_llm.get("api_key") != value:
            llm_diff["api_key"] = value
    if llm_diff:
        diff["llm"] = llm_diff
    if "kind" in agent and settings.get("agent_kind") != agent["kind"]:
        diff["agent_kind"] = agent["kind"]
    for key in ("acp_server", "acp_command", "acp_model"):
        if key in agent and settings.get(key) != agent[key]:
            diff[key] = agent[key]
    if not diff:
        print("settings unchanged")
        return
    api.json_call("PATCH", "/api/settings", {"agent_settings_diff": diff})
    print("settings applied: %s" % ", ".join(sorted(diff)))


def declared_secret(profile, secret, name):
    spec = (profile.get("secrets") or {}).get(name) or {}
    return spec.get("prefix", "") + secret(name)


def apply_secrets(api, profile, secret):
    wanted = profile.get("secrets") or {}
    if not wanted:
        return
    changed = []
    for name in sorted(wanted):
        value = declared_secret(profile, secret, name)
        status, text = api.call("GET", "/api/settings/secrets/%s" % name)
        if status == 200 and text == value:
            continue
        api.json_call("PUT", "/api/settings/secrets", {"name": name, "value": value})
        changed.append(name)
    print("secrets applied: %s" % (", ".join(changed) if changed else "none changed"))


def mcp_body(server, secret, profile):
    if "url" in server:
        body = {"transport": "http", "url": server["url"]}
        headers = server.get("headers") or {}
        if headers:
            body["headers"] = dict(
                (name, declared_secret(profile, secret, value["secret"]) if isinstance(value, dict) else value)
                for name, value in headers.items()
            )
        return body
    body = {"transport": "stdio", "command": server["command"]}
    if server.get("args"):
        body["args"] = list(server["args"])
    return body


def apply_mcp_servers(api, profile, secret, settings):
    wanted = profile.get("mcp_servers") or {}
    if not wanted:
        return
    installed = settings.get("mcp_config") or {}
    changed = []
    for name in sorted(wanted):
        body = mcp_body(wanted[name], secret, profile)
        current = installed.get(name)
        if not isinstance(current, dict):
            api.json_call("POST", "/api/settings/mcp/%s" % name, body)
            changed.append(name)
            continue
        diff = dict((key, body[key]) for key in body if current.get(key) != body[key])
        if diff:
            api.json_call("PATCH", "/api/settings/mcp/%s" % name, diff)
            changed.append(name)
    print("mcp_servers applied: %s" % (", ".join(changed) if changed else "none changed"))


def apply_skills(api, profile):
    wanted = profile.get("skills") or []
    if not wanted:
        return
    current = api.json_call("GET", "/api/skills/installed")
    installed = {
        (entry.get("source"), entry.get("repo_path"))
        for entry in current.get("skills") or []
    }
    changed = []
    for skill in wanted:
        if (skill["source"], skill.get("repo_path")) in installed:
            continue
        body = {"source": skill["source"], "force": True}
        for key in ("ref", "repo_path"):
            if key in skill:
                body[key] = skill[key]
        info = api.json_call("POST", "/api/skills/install", body)
        changed.append(info.get("name") or skill["source"])
    print("skills applied: %s" % (", ".join(changed) if changed else "none changed"))


def apply_git_sync(api, profile, secret, token_state):
    wanted = profile.get("git_sync")
    if not wanted:
        return
    current = api.json_call("GET", "/api/automation/v1/git-sync/status")
    body = {}
    for key in ("repo_url", "branch", "path", "interval_seconds"):
        if key in wanted and current.get(key) != wanted[key]:
            body[key] = wanted[key]
    digest = None
    if "token_item" in wanted:
        token = secret(GIT_SYNC_TOKEN)
        digest = hashlib.sha256(token.encode()).hexdigest()
        if read_state(token_state) != digest:
            body["token"] = token
    if not body:
        print("git_sync unchanged")
        return
    api.json_call("PUT", "/api/automation/v1/git-sync/config", body)
    if digest is not None:
        write_state(token_state, digest)
    print("git_sync applied: %s" % ", ".join(sorted(body)))


def read_state(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return None


def write_state(path, digest):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    write_private(path, digest + "\n")


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Apply layered Agent Canvas settings profiles to a running backend.",
    )
    parser.add_argument("--api", help="backend base URL, for example http://127.0.0.1:8000")
    parser.add_argument("--api-key-file", help="file holding the X-Session-API-Key value")
    parser.add_argument("--secrets-dir", help="directory holding one file per referenced secret name")
    parser.add_argument("--state-dir", default=STATE_DIRECTORY, help="writable directory for the git-sync token digest")
    parser.add_argument("--skip", action="append", choices=SECTIONS, default=[], help="section to drop from the merged profile, repeatable")
    parser.add_argument("--print", dest="report", choices=("secret-items", "agents-manifest"), help="print a derived value and exit without contacting the backend")
    parser.add_argument("profile", nargs="+", help="profile JSON files, layered left to right")
    return parser.parse_args(argv)


def main(argv):
    options = parse_arguments(argv)
    profile, dropped = load_all(options.profile, options.skip)
    if options.report == "secret-items":
        for name, item in wanted_secrets(profile):
            print("%s %s" % (name, item))
        return
    if options.report == "agents-manifest":
        agents = profile.get("agents")
        if agents:
            print(render_agents(agents))
        return
    for flag in ("api", "api_key_file", "secrets_dir"):
        if not getattr(options, flag):
            fail("--%s is required" % flag.replace("_", "-"))
    for section in dropped:
        print("%s skipped" % section)
    api = Api(options.api, options.api_key_file)
    secret = secret_reader(options.secrets_dir)
    for name, _ in wanted_secrets(profile):
        secret(name)
    settings = {}
    if profile.get("llm") or profile.get("agent") or profile.get("mcp_servers"):
        current = api.json_call("GET", "/api/settings", headers={"X-Expose-Secrets": "plaintext"})
        settings = current.get("agent_settings") or {}
    apply_agent_settings(api, profile, secret, settings)
    apply_secrets(api, profile, secret)
    apply_mcp_servers(api, profile, secret, settings)
    apply_skills(api, profile)
    apply_git_sync(api, profile, secret, os.path.join(options.state_dir, TOKEN_STATE_FILE))


if __name__ == "__main__":
    main(sys.argv[1:])
