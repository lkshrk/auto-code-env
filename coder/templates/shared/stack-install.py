#!/usr/bin/env python3
"""Coder-workspace stack/tool resolver.

Resolves which Omni tools a selection of stacks/clients/plugins requires
and renders an Omni config for the "coder-components" host that installs
them. Owned by auto-code-env because this is machine/environment
composition policy ("which packages does a Coder workspace need for
stack X"), not personal computing configuration.

Deliberately does NOT read or copy the Omni tool *provider* catalog
(how to actually install each named tool: apt package, npm package,
GitHub release recipe, ...) into the rendered config -- that stays in
dotfiles (the user's own package manifest, shared with their non-Coder
machines via `setup.sh`/`omni bootstrap`, not Coder-specific) and is
merged in natively via Omni's own `$include` mechanism, the same one
dotfiles' settings.json already uses for its own settings.d/*.json
files. Duplicating that catalog here, or hand-merging it in Python,
would both recreate the drift PR #99 already fixed for the readiness
checker AND reimplement (worse) the host-aware provider-priority
resolution Omni's config loader already does correctly (e.g. the
coder-components host already disables "brew" and prioritizes "apt" --
see dotfiles' settings.json host_settings -- so a tool with both brew
and apt providers resolves correctly with zero code here).

linux-tools.json (this directory) is the one deliberate exception: a
small, static set of native Linux install recipes for tools where a
plain package isn't suitable for Coder's workspaces (Neovim built from
a GitHub release tarball, delta/lefthook/tree-sitter-cli as GitHub
release binaries). It $include-overrides dotfiles' definitions for the
same names using Omni's own "later $include wins" merge rule.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit

HOST = "coder-components"
CATALOG_KEYS = ("STACK_TOOLS", "ALIASES", "BASE", "CORE_DOTS", "RUNTIMES")
DOTS_ROOT = "dotfiles/omni/.config/omni"


def load_catalog(path=None):
    path = Path(path) if path else Path(__file__).with_name("catalog.json")
    data = json.loads(path.read_text())
    missing = set(CATALOG_KEYS) - set(data)
    if missing:
        raise ValueError("catalog missing keys: " + ", ".join(sorted(missing)))
    return data


def choices(value, allowed, name):
    result = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if item not in allowed:
            raise ValueError(f"invalid {name}: {item}")
        if item not in result:
            result.append(item)
    return result


def contract(env, catalog):
    stacks = choices(env.get("CODER_OMNI_STACKS", ""), set(catalog["STACK_TOOLS"]) | set(catalog["ALIASES"]), "CODER_OMNI_STACKS")
    stacks = list(dict.fromkeys(s for item in stacks for s in catalog["ALIASES"].get(item, [item])))
    clients = choices(env.get("CODER_AGENT_CLIENTS", ""), {"claude", "codex"}, "CODER_AGENT_CLIENTS")
    result = {"stacks": stacks, "clients": clients}
    for name, default, allowed in [
        ("CODER_AGENT_PLUGINS", "0", {"0", "1"}),
        ("CODER_ENABLE_DIND", "0", {"0", "1"}),
        ("CODER_BACKEND", "kubernetes", {"kubernetes", "docker"}),
    ]:
        value = env.get(name, default)
        if value not in allowed:
            raise ValueError(f"invalid {name}: {value}")
        result[name] = value
    if result["CODER_AGENT_PLUGINS"] == "1" and not clients:
        raise ValueError("CODER_AGENT_PLUGINS=1 requires CODER_AGENT_CLIENTS")
    url = env.get("CODER_MCP_URL", "")
    if url:
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or any(ord(c) < 33 for c in url):
            raise ValueError("CODER_MCP_URL must be an explicit HTTP(S) URL")
    result["CODER_MCP_URL"] = url
    return result


def build_static_groups(catalog):
    """Every group this host could ever need, derived purely from
    catalog.json -- always present regardless of selection. Which of
    these actually get synced for a given workspace is decided by
    select_group_names(), not by which groups exist."""
    groups = [{"name": "component-base", "tools": list(catalog["BASE"])}]
    for runtime in catalog["RUNTIMES"]:
        groups.append({"name": "runtime-" + runtime, "tools": [runtime]})
    for stack in sorted(catalog["STACK_TOOLS"]):
        extra = [t for t in catalog["STACK_TOOLS"][stack] if t not in catalog["RUNTIMES"] and t not in catalog["BASE"]]
        groups.append({"name": "stack-" + stack, "tools": extra})
    groups.append({"name": "client-claude", "tools": ["claude-code"]})
    groups.append({"name": "client-codex", "tools": ["@openai/codex"]})
    return groups


def select_group_names(selection, catalog):
    """Ordered list of group names to actually sync. Runtimes are
    always ordered first so tools that depend on them (npm packages
    needing nvm, pyright needing a managed Python, ...) install
    against a working toolchain."""
    runtimes = []

    def need(runtime):
        if runtime not in runtimes:
            runtimes.append(runtime)

    for stack in selection["stacks"]:
        for tool in catalog["STACK_TOOLS"][stack]:
            if tool in catalog["RUNTIMES"]:
                need(tool)
    if "codex" in selection["clients"]:
        need("nvm")
        need("bun")
    if selection["CODER_AGENT_PLUGINS"] == "1":
        need("nvm")
        need("bun")
    if any("pyright" in catalog["STACK_TOOLS"][s] for s in selection["stacks"]):
        need("nvm")
    names = ["component-base"] + ["runtime-" + r for r in runtimes] + ["stack-" + s for s in selection["stacks"]]
    if "claude" in selection["clients"]:
        names.append("client-claude")
    if "codex" in selection["clients"]:
        names.append("client-codex")
    if selection["CODER_AGENT_PLUGINS"] == "1":
        names.append("ai-plugins")
    return names


def ai_plugins_group(dotfiles_dir, clients):
    # The set of curated AI-agent CLI plugins is dotfiles' own personal
    # opinion (it's read from the same groups.json dotfiles uses for
    # its own, non-Coder bootstrap) -- this only narrows that list to
    # the clients this workspace actually has, it doesn't own it.
    path = Path(dotfiles_dir) / DOTS_ROOT / "settings.d/groups.json"
    source_groups = json.loads(path.read_text())["groups"]
    plugins = next(g["tools"] for g in source_groups if g["name"] == "ai-plugins")
    tools = [t for t in plugins if t != "herdr-tether"
             and not (t == "oh-my-codex" and "codex" not in clients)
             and not (t == "ccundo" and "claude" not in clients)]
    return {"name": "ai-plugins", "tools": tools}


def staged_tools_path(shared_dir):
    # `omni tools sync` writes resolved provider state back into the
    # *first* file that defines a synced tool's provider block -- not
    # just reads it. $include-ing dotfiles' tracked settings.d/tools.json
    # by its live path once made that the user's own git checkout,
    # which a real sync silently truncated to `{}` the moment it had to
    # install (not just check) something, violating dots_repo's "never
    # merge, reset, clean, or otherwise alter their working tree"
    # guarantee (see prepare-dotfiles.sh). $include this disposable copy
    # instead; the suffix matches the live path on purpose so it stays
    # recognizable in `--print-config` output and error messages.
    return Path(shared_dir) / "settings.d/tools.json"


def stage_tool_providers(dotfiles_dir, shared_dir):
    root = Path(dotfiles_dir) / DOTS_ROOT
    staged = staged_tools_path(shared_dir)
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_text((root / "settings.d/tools.json").read_text())


def render_config(dotfiles_dir, env, catalog, shared_dir):
    dotfiles_dir = Path(dotfiles_dir)
    selection = contract(env, catalog)
    root = dotfiles_dir / DOTS_ROOT
    settings = json.loads((root / "settings.json").read_text())
    groups = build_static_groups(catalog)
    if selection["CODER_AGENT_PLUGINS"] == "1":
        groups.append(ai_plugins_group(dotfiles_dir, selection["clients"]))
    names = select_group_names(selection, catalog)
    host_settings = copy.deepcopy(settings["host_settings"][HOST])
    host_settings["dots_repo"] = str(dotfiles_dir)
    config = {
        "$schema": settings["$schema"],
        "version": settings["version"],
        "$include": [
            str(staged_tools_path(shared_dir).resolve()),
            str((Path(shared_dir) / "linux-tools.json").resolve()),
        ],
        "host_settings": {HOST: host_settings},
        "hosts": {HOST: names},
        "groups": groups + [{"name": HOST, "special": "host"}],
        "settings": {"fallback_bin_dir": "~/.local/bin", "dots_git": {"auto_commit": False}},
    }
    return config, names


def load_tool_providers(dotfiles_dir, shared_dir):
    # Narrow, read-only introspection for the shell orchestration's own
    # bookkeeping (does this tool need npm/apt-specific post-install
    # steps) -- NOT part of the install path above, which lets Omni's
    # own $include + host provider-priority resolve this instead. Reads
    # dotfiles' live tracked file directly (not the staged copy): this
    # is read-only, so it's safe, and it must see real content even
    # before stage_tool_providers() has run for this invocation (e.g.
    # `--print-config`, or the equivalence tests, never call it).
    root = Path(dotfiles_dir) / DOTS_ROOT
    tools = json.loads((root / "settings.d/tools.json").read_text())["tools"]
    tools.update(json.loads((Path(shared_dir) / "linux-tools.json").read_text())["tools"])
    return tools


BINARY_ALIASES = {
    "nvm": ["node", "npm"], "cargo": ["rustc", "cargo"],
    "python@3.14": [], "ca-certificates": [], "libssl-dev": [],
    "build-essential": ["make", "cc", "c++"], "xz-utils": ["xz"],
    "typescript": ["tsc"], "go-task": ["task"], "kubernetes-cli": ["kubectl"],
    "cilium-cli": ["cilium"], "opentofu": ["tofu"],
    "bats-core": ["bats"], "claude-code": ["claude"],
    "@openai/codex": ["codex"], "oh-my-codex": ["omx"],
    "krew": ["kubectl-krew"], "neovim": ["nvim"], "fd": ["fdfind", "fd"],
    "bat": ["batcat", "bat"], "ripgrep": ["rg"], "oh-my-zsh": [],
    "tree-sitter-cli": ["tree-sitter"], "git-delta": ["delta"],
}


def required_commands(names, catalog, dotfiles_dir, shared_dir, provider=None):
    groups = {g["name"]: g for g in build_static_groups(catalog)}
    tools = load_tool_providers(dotfiles_dir, shared_dir) if provider else None
    binaries = []
    for name in names:
        for tool in groups.get(name, {}).get("tools", []):
            if provider is not None:
                providers = tools.get(tool, {}).get("providers", [])
                if not any(p.get("provider") == provider for p in providers):
                    continue
            for binary in BINARY_ALIASES.get(tool, [tool]):
                if binary not in binaries:
                    binaries.append(binary)
    return binaries


def required_apt_packages(names, catalog, dotfiles_dir, shared_dir):
    # Apt package *names* (not binaries): used only to decide whether
    # `apt-get update` is needed before a sync, mirroring what an apt
    # provider entry, once Omni's own disabled/priority resolution
    # picks it, would actually install.
    groups = {g["name"]: g for g in build_static_groups(catalog)}
    tools = load_tool_providers(dotfiles_dir, shared_dir)
    packages = []
    for name in names:
        for tool in groups.get(name, {}).get("tools", []):
            providers = [p for p in tools.get(tool, {}).get("providers", []) if p.get("provider") != "brew"]
            if len(providers) == 1 and providers[0].get("provider") == "apt":
                package = providers[0].get("package", tool)
                if package not in packages:
                    packages.append(package)
    return packages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dotfiles", type=Path, required=True, help="Cloned dotfiles checkout (personal dots + Omni tool provider catalog)")
    parser.add_argument("--catalog", type=Path, default=None)
    parser.add_argument("--required-commands", action="store_true")
    parser.add_argument("--required-provider")
    parser.add_argument("--required-apt-packages", action="store_true")
    args = parser.parse_args()
    shared_dir = Path(__file__).parent
    try:
        catalog = load_catalog(args.catalog)
        config, names = render_config(args.dotfiles.resolve(), os.environ, catalog, shared_dir)
    except (ValueError, OSError, KeyError) as exc:
        parser.error(str(exc))
    if args.required_apt_packages:
        print("\n".join(required_apt_packages(names, catalog, args.dotfiles.resolve(), shared_dir)))
        return
    if args.required_commands:
        print("\n".join(required_commands(names, catalog, args.dotfiles.resolve(), shared_dir, args.required_provider)))
        return
    json.dump(config, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
