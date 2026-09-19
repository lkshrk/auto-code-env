#!/usr/bin/env python3
"""Coder-workspace stack/tool resolver.

Resolves which Omni tools a selection of stacks/clients/plugins requires,
and builds a *tools-only* Omni config to install them (no personal dots
groups at all -- that stays entirely dotfiles' job).

Owned by auto-code-env because this is machine/environment composition
policy ("which packages does a Coder workspace need for stack X"), not
personal computing configuration. The Omni tool *provider* catalog (how
to actually install each named tool: apt package, npm package, GitHub
release recipe, ...) intentionally stays in dotfiles and is read live
from the cloned checkout below -- it is the user's own package manifest,
shared with their non-Coder machines via `setup.sh`/`omni bootstrap`,
not something specific to Coder workspaces, so duplicating it here would
recreate the exact drift PR #99 already fixed for the readiness checker.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import shlex
import sys
from urllib.parse import urlsplit

HOST = "coder-components"
CATALOG_KEYS = ("STACK_TOOLS", "ALIASES", "BASE", "CORE_DOTS", "RUNTIMES")


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


def linux_core_providers(shared_dir):
    # Native (non-Omni-provider) install recipes for tools where a
    # plain apt/npm package is unavailable or unsuitable for Coder's
    # Linux workspaces. Pure machine mechanics -- ported verbatim from
    # dotfiles' coder-components.py, which is why coder-neovim.py moved
    # alongside it rather than staying split across two repositories.
    helper = shlex.quote(str(Path(shared_dir) / "coder-neovim.py"))
    install = (
        "set -eu; case \"$(uname -m)\" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac; "
        "tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; "
        "curl -fsSL --proto-redir '=https' https://api.github.com/repos/neovim/neovim/releases/latest -o \"$tmp/release.json\"; "
        "asset=nvim-linux-$arch.tar.gz; "
        "url=$(jq -er --arg name \"$asset\" '.assets[] | select(.name == $name) | .browser_download_url' \"$tmp/release.json\"); "
        "digest=$(jq -er --arg name \"$asset\" '.assets[] | select(.name == $name) | .digest | select(startswith(\"sha256:\")) | ltrimstr(\"sha256:\")' \"$tmp/release.json\"); "
        "curl -fsSL --proto '=https' --proto-redir '=https' \"$url\" -o \"$tmp/nvim.tar.gz\"; "
        f"python3 {helper} \"$tmp/nvim.tar.gz\" \"$digest\""
    )

    def native(owner, repo_name, binary, pattern, arch_map):
        return {"providers": [{"provider": "script", "bin": binary,
            "options": {"arch_map": arch_map},
            "source": {"type": "github", "owner": owner, "repo": repo_name},
            "recipe": {"type": "github_release_asset", "asset_pattern": pattern}}]}

    return {
        "neovim": {"providers": [{"provider": "script", "bin": "nvim", "options": {
            "install": install,
            "check": 'test -x "$HOME/.local/share/coder-neovim/current/bin/nvim" && test -f "$HOME/.local/share/coder-neovim/current/share/nvim/runtime/doc/help.txt" && test -x "$HOME/.local/bin/nvim"',
            "version": '"$HOME/.local/bin/nvim" --version | head -1 | sed "s/^NVIM v//"',
            "latest": "curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest | jq -er '.tag_name | ltrimstr(\"v\")'",
        }}]},
        "git-delta": native("dandavison", "delta", "delta", "delta-{version}-{arch}-unknown-linux-gnu.tar.gz", "aarch64:aarch64,arm64:aarch64,x86_64:x86_64,amd64:x86_64"),
        "lefthook": native("evilmartians", "lefthook", "lefthook", "lefthook_{version}_Linux_{arch}.gz", "aarch64:arm64,arm64:arm64,x86_64:x86_64,amd64:x86_64"),
        "tree-sitter-cli": native("tree-sitter", "tree-sitter", "tree-sitter", "tree-sitter-linux-{arch}.gz", "aarch64:arm64,arm64:arm64,x86_64:x64,amd64:x64"),
    }


def resolve_tools(dotfiles_dir, env, catalog):
    """Build a tools-only Omni config: no dots/personal groups at all."""
    dotfiles_dir = Path(dotfiles_dir)
    selection = contract(env, catalog)
    root = dotfiles_dir / "dotfiles/omni/.config/omni"
    settings = json.loads((root / "settings.json").read_text())
    tools = json.loads((root / "settings.d/tools.json").read_text())["tools"]
    source_groups = json.loads((root / "settings.d/groups.json").read_text())["groups"]
    selected = list(dict.fromkeys(t for s in selection["stacks"] for t in catalog["STACK_TOOLS"][s]))
    if "claude" in selection["clients"]:
        selected.append("claude-code")
    if "codex" in selection["clients"]:
        selected.extend(["nvm", "bun", "@openai/codex"])
    if selection["CODER_AGENT_PLUGINS"] == "1":
        plugins = next(g["tools"] for g in source_groups if g["name"] == "ai-plugins")
        selected.extend(t for t in plugins if t != "herdr-tether"
                        and not (t == "oh-my-codex" and "codex" not in selection["clients"])
                        and not (t == "ccundo" and "claude" not in selection["clients"]))
        selected.extend(["bun", "nvm"])
    if "pyright" in selected:
        selected.append("nvm")
    selected = [t for t in dict.fromkeys(selected) if t not in catalog["BASE"]]
    groups = [{"name": "component-base", "tools": catalog["BASE"]}]
    for runtime in catalog["RUNTIMES"]:
        if runtime in selected:
            groups.append({"name": "runtime-" + runtime, "tools": [runtime]})
    groups.append({"name": "component-tools", "tools": [t for t in selected if t not in catalog["RUNTIMES"]]})
    tools = dict(tools)
    tools.update(linux_core_providers(Path(__file__).parent))
    names = list(dict.fromkeys(t for group in groups for t in group.get("tools", [])))
    missing = set(names) - tools.keys()
    if missing:
        raise ValueError("missing Omni tool definitions: " + ", ".join(sorted(missing)))
    host_settings = copy.deepcopy(settings["host_settings"][HOST])
    host_settings["dots_repo"] = str(dotfiles_dir)
    return {
        "$schema": settings["$schema"],
        "version": settings["version"],
        "host_settings": {HOST: host_settings},
        "hosts": {HOST: [g["name"] for g in groups]},
        "groups": groups + [{"name": HOST, "special": "host"}],
        "tools": {name: tools[name] for name in names},
        "settings": {"fallback_bin_dir": "~/.local/bin", "dots_git": {"auto_commit": False}},
    }


def required_commands(config, provider=None):
    aliases = {
        "nvm": ["node", "npm"], "cargo": ["rustc", "cargo"],
        "python@3.14": [], "ca-certificates": [], "libssl-dev": [],
        "build-essential": ["make", "cc", "c++"], "xz-utils": ["xz"],
        "typescript": ["tsc"], "go-task": ["task"], "kubernetes-cli": ["kubectl"],
        "cilium-cli": ["cilium"], "opentofu": ["tofu"],
        "bats-core": ["bats"], "claude-code": ["claude"],
        "@openai/codex": ["codex"], "oh-my-codex": ["omx"],
        "krew": ["kubectl-krew"], "neovim": ["nvim"], "fd": ["fdfind", "fd"],
        "bat": ["batcat", "bat"], "ripgrep": ["rg"], "oh-my-zsh": [], "tree-sitter-cli": ["tree-sitter"], "git-delta": ["delta"],
    }
    return list(dict.fromkeys(binary for group in config["groups"]
                             for tool in group.get("tools", [])
                             if provider is None or any(p["provider"] == provider for p in config["tools"][tool]["providers"])
                             for binary in aliases.get(tool, [tool])))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dotfiles", type=Path, required=True, help="Cloned dotfiles checkout (personal dots + Omni tool provider catalog)")
    parser.add_argument("--catalog", type=Path, default=None)
    parser.add_argument("--required-commands", type=Path)
    parser.add_argument("--required-provider")
    args = parser.parse_args()
    try:
        catalog = load_catalog(args.catalog)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    if args.required_commands:
        print("\n".join(required_commands(json.loads(args.required_commands.read_text()), args.required_provider)))
        return
    try:
        config = resolve_tools(args.dotfiles.resolve(), os.environ, catalog)
    except (ValueError, OSError, KeyError) as exc:
        parser.error(str(exc))
    json.dump(config, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
