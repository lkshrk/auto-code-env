#!/usr/bin/env python3
"""Stand-in Agent Canvas backend for the overlay and applier suites."""

import argparse
import http.server
import json
import threading

LOCK = threading.Lock()


def merge(destination, source):
    for key, value in source.items():
        if isinstance(value, dict) and isinstance(destination.get(key), dict):
            merge(destination[key], value)
        else:
            destination[key] = value


def settings_response(state, expose):
    agent = json.loads(json.dumps(state["agent_settings"]))
    if expose != "plaintext" and "llm" in agent and "api_key" in agent["llm"]:
        agent["llm"]["api_key"] = "**********"
    return {"agent_settings": agent, "llm_api_key_is_set": True}


def route(state, method, path, body, expose):
    if method == "GET" and path == "/api/settings":
        return 200, json.dumps(settings_response(state, expose))
    if method == "PATCH" and path == "/api/settings":
        merge(state["agent_settings"], body["agent_settings_diff"])
        return 200, json.dumps(settings_response(state, None))
    if method == "GET" and path.startswith("/api/settings/secrets/"):
        name = path.rsplit("/", 1)[1]
        if name in state["secrets"]:
            return 200, state["secrets"][name]
        return 404, json.dumps({"detail": "Secret not found"})
    if method == "PUT" and path == "/api/settings/secrets":
        state["secrets"][body["name"]] = body["value"]
        return 200, json.dumps({"name": body["name"]})
    if method == "POST" and path.startswith("/api/settings/mcp/"):
        name = path.rsplit("/", 1)[1]
        servers = state["agent_settings"].setdefault("mcp_config", {})
        if name in servers:
            return 409, json.dumps({"detail": "MCP server '%s' already exists" % name})
        entry = dict(body)
        entry.setdefault("enabled", True)
        servers[name] = entry
        return 201, json.dumps(settings_response(state, None))
    if method == "PATCH" and path.startswith("/api/settings/mcp/"):
        name = path.rsplit("/", 1)[1]
        servers = state["agent_settings"].setdefault("mcp_config", {})
        if name not in servers:
            return 404, json.dumps({"detail": "MCP server '%s' was not found" % name})
        merge(servers[name], body)
        return 200, json.dumps(settings_response(state, None))
    if method == "GET" and path == "/api/skills/installed":
        return 200, json.dumps({"skills": state["skills"]})
    if method == "POST" and path == "/api/skills/install":
        entry = {
            "name": (body.get("repo_path") or body["source"]).rsplit("/", 1)[-1],
            "source": body["source"],
            "repo_path": body.get("repo_path"),
            "ref": body.get("ref"),
        }
        state["skills"].append(entry)
        return 200, json.dumps(entry)
    if method == "GET" and path == "/api/automation/v1/git-sync/status":
        return 200, json.dumps(state["git_sync"])
    if method == "PUT" and path == "/api/automation/v1/git-sync/config":
        if "token" in body:
            state["git_sync_token"] = body["token"]
        merge(state["git_sync"], dict((k, v) for k, v in body.items() if k != "token"))
        return 200, json.dumps(state["git_sync"])
    return 501, json.dumps({"detail": "unexpected request %s %s" % (method, path)})


def handler_class(options):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, code, payload):
            encoded = payload.encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def dispatch(self, method):
            with open(options.api_key_file) as handle:
                expected = handle.read().strip()
            if self.headers.get("X-Session-API-Key") != expected:
                self.reply(403, json.dumps({"detail": "bad session API key"}))
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            with LOCK:
                with open(options.log, "a") as handle:
                    handle.write("%s %s\n" % (method, self.path))
                if body is not None:
                    with open(options.bodies, "a") as handle:
                        handle.write("%s %s %s\n" % (method, self.path, json.dumps(body, sort_keys=True)))
                with open(options.state) as handle:
                    state = json.load(handle)
                code, payload = route(state, method, self.path, body, self.headers.get("X-Expose-Secrets"))
                with open(options.state, "w") as handle:
                    json.dump(state, handle)
            self.reply(code, payload)

        def do_GET(self):
            self.dispatch("GET")

        def do_POST(self):
            self.dispatch("POST")

        def do_PUT(self):
            self.dispatch("PUT")

        def do_PATCH(self):
            self.dispatch("PATCH")

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--state", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--bodies", required=True)
    parser.add_argument("--api-key-file", required=True)
    options = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", options.port), handler_class(options))
    server.serve_forever()


if __name__ == "__main__":
    main()
