#!/usr/bin/env python3
"""Coder-workspace stack installer orchestration.

Single Python entrypoint. Previously split across install-stacks.sh +
install-omni.sh, inherited from dotfiles' own Python/Bash split -- but
omni invocation, binary symlinking, and PATH/env management don't need
a second language just because that's how the ported version worked.
Collapsing them removes the CLI-flag boundary between the two files
(--required-commands, --required-apt-packages, --required-provider)
that had to be kept in sync by hand and was a real source of drift risk
during the split (a stale call site nearly shipped once already).

The one place this still shells out on purpose is nvm resolution
(`bash -c 'source nvm.sh && nvm use ...'`): that borrows nvm's own
authoritative version-alias resolution (lts/*, semver ranges, ...)
rather than reimplementing it, no different in kind from shelling out
to omni/apt-get/dpkg-query themselves.

stack-install.py (imported below) stays a separate, pure module: it
has no side effects and is the thing that's actually unit-tested for
equivalence against dotfiles' resolver. Keeping it side-effect-free
means those tests never need to mock subprocess/filesystem calls.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SHARED_DIR = Path(__file__).resolve().parent


def link_state_dir():
    return Path.home() / ".local/state/coder-components/links"


def _load_stack_install():
    spec = importlib.util.spec_from_file_location("stack_install", SHARED_DIR / "stack-install.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stack_install = _load_stack_install()


def omni_release_base():
    version = os.environ.get("OMNI_VERSION", "").strip()
    if not version:
        return "https://github.com/lkshrk/omni/releases/latest/download"
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", version):
        raise SystemExit("OMNI_VERSION must be an exact release version (for example 0.10.14)")
    return f"https://github.com/lkshrk/omni/releases/download/v{version.lstrip('v')}"


def install_omni_release():
    base = omni_release_base()
    bin_dir = Path(os.environ.get("DIR", str(Path.home() / ".local/bin")))
    machine = os.uname().machine
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    if not arch:
        raise SystemExit(f"unsupported architecture for omni install: {machine}")
    osname = os.uname().sysname.lower()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        archive = tmp / "omni.tar.gz"
        subprocess.run(["curl", "-fsSL", f"{base}/omni_{osname}_{arch}.tar.gz", "-o", str(archive)], check=True)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(tmp), "omni"], check=True)
        bin_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(["install", "-Dm", "755", str(tmp / "omni"), str(bin_dir / "omni")], check=True)


def omni_compatible(config_path, binary="omni"):
    if not shutil.which(binary):
        return False
    omni_version = os.environ.get("OMNI_VERSION", "").strip()
    if omni_version:
        result = subprocess.run([binary, "--version"], capture_output=True, text=True)
        if result.returncode != 0:
            return False
        match = re.match(r"omni version v?(\d+\.\d+\.\d+)(\s|$)", result.stdout)
        if not match or match.group(1) != omni_version.lstrip("v"):
            return False
    result = subprocess.run([binary, "--config", config_path, "settings", "show", "--format", "json"], capture_output=True)
    return result.returncode == 0


def link_local_bin(source, name):
    source = str(source)
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._+-]*", name):
        raise SystemExit(f"invalid executable name: {name}")
    state_dir = link_state_dir()
    if state_dir.is_symlink() or state_dir.parent.is_symlink():
        raise SystemExit(f"refusing symlinked link receipt directory: {state_dir}")
    state_dir.mkdir(parents=True, exist_ok=True)
    receipt = state_dir / name
    if receipt.is_symlink():
        raise SystemExit(f"refusing symlinked link receipt: {receipt}")
    target = Path.home() / ".local/bin" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() and os.readlink(target) == source:
        receipt.write_text(source + "\n")
        return
    if target.exists() or target.is_symlink():
        if not (target.is_symlink() and receipt.is_file()):
            raise SystemExit(f"refusing to replace existing executable path: {target} (wanted {source})")
        previous = receipt.read_text().strip()
        if os.readlink(target) != previous:
            raise SystemExit(f"refusing to replace modified executable path: {target}")
        target.unlink()
    target.symlink_to(source)
    receipt.write_text(source + "\n")


def link_node_commands(node_bin):
    node_bin = Path(node_bin)
    if not node_bin.is_absolute() or not os.access(node_bin / "node", os.X_OK):
        raise SystemExit(f"required Node executable missing: {node_bin}/node")
    for binary in ("node", "npm", "npx", "corepack"):
        candidate = node_bin / binary
        if os.access(candidate, os.X_OK):
            link_local_bin(candidate, binary)


def nvm_bin_dir(nvm_dir):
    script = f'source "{nvm_dir}/nvm.sh" --no-use >/dev/null 2>&1 && nvm use --silent default >/dev/null && printf %s "$NVM_BIN"'
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def refresh_path(names):
    nvm_dir = os.environ.setdefault("NVM_DIR", str(Path.home() / ".nvm"))
    nvm_sh = Path(nvm_dir) / "nvm.sh"
    nvm_bin = None
    if "runtime-nvm" in names and nvm_sh.is_file() and nvm_sh.stat().st_size > 0:
        nvm_bin = nvm_bin_dir(nvm_dir)
        if nvm_bin:
            link_node_commands(nvm_bin)
    home = str(Path.home())
    parts = ([nvm_bin] if nvm_bin else []) + [
        f"{home}/.local/bin", f"{home}/.bun/bin", f"{home}/.cargo/bin",
        f"{home}/.krew/bin", f"{home}/.local/share/pnpm", f"{home}/.local/share/pnpm/bin",
    ]
    os.environ["PATH"] = ":".join(parts) + ":" + os.environ.get("PATH", "")


def active_has_tool(catalog, names, tool):
    groups = {g["name"]: g["tools"] for g in stack_install.build_static_groups(catalog)}
    return any(tool in groups.get(name, []) for name in names)


def link_npm_commands(catalog, names, dotfiles_dir, shared_dir):
    required = stack_install.required_commands(names, catalog, dotfiles_dir, shared_dir, provider="npm")
    if not required:
        return
    prefix = subprocess.run(["npm", "prefix", "-g"], capture_output=True, text=True, check=True).stdout.strip()
    if not prefix.startswith("/"):
        raise SystemExit(f"npm global prefix must be absolute: {prefix}")
    stable_path = f"{Path.home()}/.local/bin:{Path.home()}/.bun/bin:{Path.home()}/.cargo/bin:{Path.home()}/.krew/bin:{Path.home()}/.local/share/pnpm:/bin"
    for binary in required:
        candidate = Path(prefix) / "bin" / binary
        if not os.access(candidate, os.X_OK):
            raise SystemExit(f"required npm executable missing: {candidate}")
        link_local_bin(candidate, binary)
        env = {k: v for k, v in os.environ.items() if k != "NVM_BIN"}
        env["PATH"] = stable_path
        if subprocess.run([binary, "--version"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            raise SystemExit(f"required npm executable failed on stable PATH: {binary}")


def link_bun_commands(catalog, names, dotfiles_dir, shared_dir):
    # bun's global install bin dir is *not* ~/.bun/bin (that's only
    # where the bun/bunx binaries themselves land from the installer
    # script) -- once XDG_CACHE_HOME is set (it always is in this
    # workspace image), bun resolves its own package-manager global
    # root under it instead, e.g. ~/.cache/.bun/bin. Verified live:
    # ~/.bun/bin never contained a bun-provider tool's binary, causing
    # final_check() to correctly, but fatally, report it missing.
    # Mirrors link_npm_commands below; ask bun itself rather than
    # hardcoding its XDG-dependent path.
    required = stack_install.required_commands(names, catalog, dotfiles_dir, shared_dir, provider="bun")
    if not required:
        return
    prefix = subprocess.run(["bun", "pm", "bin", "-g"], capture_output=True, text=True, check=True).stdout.strip()
    if not prefix.startswith("/"):
        raise SystemExit(f"bun global bin directory must be absolute: {prefix}")
    stable_path = f"{Path.home()}/.local/bin:{Path.home()}/.bun/bin:{Path.home()}/.cargo/bin:{Path.home()}/.krew/bin:{Path.home()}/.local/share/pnpm:/bin"
    for binary in required:
        candidate = Path(prefix) / binary
        if not os.access(candidate, os.X_OK):
            raise SystemExit(f"required bun executable missing: {candidate}")
        link_local_bin(candidate, binary)
        env = {k: v for k, v in os.environ.items() if k != "NVM_BIN"}
        env["PATH"] = stable_path
        if subprocess.run([binary, "--version"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            raise SystemExit(f"required bun executable failed on stable PATH: {binary}")


def link_lsp_commands(catalog, names):
    if not active_has_tool(catalog, names, "pyright"):
        return
    prefix = subprocess.run(["npm", "prefix", "-g"], capture_output=True, text=True, check=True).stdout.strip()
    candidate = Path(prefix) / "bin/pyright-langserver"
    if not prefix.startswith("/") or not os.access(candidate, os.X_OK):
        raise SystemExit("required Pyright language server missing")
    link_local_bin(candidate, "pyright-langserver")
    subprocess.run(["node", "--check", str(candidate)], check=True)


def refresh_apt(catalog, names, dotfiles_dir, shared_dir):
    for package in stack_install.required_apt_packages(names, catalog, dotfiles_dir, shared_dir):
        status = subprocess.run(["dpkg-query", "-W", "-f=${Status}", package], capture_output=True, text=True).stdout.strip()
        if status != "install ok installed":
            if not shutil.which("apt-get"):
                raise SystemExit("required component packages need Debian/Ubuntu apt")
            if os.geteuid() == 0:
                subprocess.run(["apt-get", "update", "-qq"], check=True)
            elif shutil.which("sudo"):
                subprocess.run(["sudo", "-n", "apt-get", "update", "-qq"], check=True)
            else:
                raise SystemExit("missing required apt packages need root or passwordless sudo")
            return


def final_check(catalog, names, dotfiles_dir, shared_dir):
    for binary in stack_install.required_commands(names, catalog, dotfiles_dir, shared_dir):
        if not shutil.which(binary):
            raise SystemExit(f"required component binary missing: {binary}")
    if not (Path.home() / ".oh-my-zsh/oh-my-zsh.sh").is_file():
        raise SystemExit("required Oh My Zsh configuration missing")
    version_out = subprocess.run(["tree-sitter", "--version"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", version_out)
    if not match or tuple(map(int, match.groups())) < (0, 26, 1):
        raise SystemExit("tree-sitter >=0.26.1 required")
    lua = '+lua if vim.fn.filereadable(vim.env.VIMRUNTIME .. "/doc/help.txt") ~= 1 then vim.cmd("cquit") end'
    if subprocess.run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", lua, "+qa"]).returncode != 0:
        raise SystemExit("required Neovim runtime is incomplete")
    if active_has_tool(catalog, names, "python@3.14"):
        subprocess.run(["uv", "python", "find", "3.14"], check=True, stdout=subprocess.DEVNULL)


def run(dotfiles_dir):
    catalog = stack_install.load_catalog()
    stack_install.stage_tool_providers(dotfiles_dir, SHARED_DIR)
    config, names = stack_install.render_config(dotfiles_dir, os.environ, catalog, SHARED_DIR)

    if os.uname().sysname != "Linux":
        raise SystemExit("stack install is Linux-only")
    for binary in ("curl", "tar", "git", "jq"):
        if not shutil.which(binary):
            raise SystemExit(f"stack install requires {binary}")

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(config, handle)
        config_path = handle.name
    try:
        os.environ["PATH"] = f"{Path.home()}/.local/bin:" + os.environ.get("PATH", "")
        os.environ["OMNI_HOSTNAME"] = "coder-components"
        os.environ["CODER_ENVIRONMENT_MODE"] = "composable"
        ca_path = os.environ.get("OMNI_OTEL_CA_PATH", "")
        if ca_path and os.access(ca_path, os.R_OK):
            os.environ.setdefault("NODE_EXTRA_CA_CERTS", ca_path)

        if omni_compatible(config_path):
            version = subprocess.run(["omni", "--version"], capture_output=True, text=True).stdout.strip()
            print(f"OK reusing compatible {version}")
        else:
            install_omni_release()

        subprocess.run(["omni", "--config", config_path, "settings", "show", "--format", "json"], check=True, stdout=subprocess.DEVNULL)
        refresh_apt(catalog, names, dotfiles_dir, SHARED_DIR)
        for group in names:
            print(f"==> required component tools: {group}")
            subprocess.run(["omni", "--config", config_path, "--yes", "tools", "sync", group], check=True)
            refresh_path(names)
        batcat = shutil.which("batcat")
        if batcat:
            link_local_bin(batcat, "bat")
        fdfind = shutil.which("fdfind")
        if fdfind:
            link_local_bin(fdfind, "fd")
        link_npm_commands(catalog, names, dotfiles_dir, SHARED_DIR)
        link_bun_commands(catalog, names, dotfiles_dir, SHARED_DIR)
        link_lsp_commands(catalog, names)
        final_check(catalog, names, dotfiles_dir, SHARED_DIR)
        backend = os.environ.get("CODER_BACKEND", "kubernetes")
        dind = os.environ.get("CODER_ENABLE_DIND", "0")
        print(f"OK required stacks ready; backend={backend}, DinD={dind} (daemon owned by parent)")
    finally:
        os.unlink(config_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--print-config", action="store_true")
    args = parser.parse_args()

    dotfiles_dir = os.environ.get("CODER_DOTFILES_SOURCE_DIR")
    if not dotfiles_dir:
        raise SystemExit("CODER_DOTFILES_SOURCE_DIR is required")
    dotfiles_dir = Path(dotfiles_dir).resolve()

    if args.print_config:
        catalog = stack_install.load_catalog()
        config, _ = stack_install.render_config(dotfiles_dir, os.environ, catalog, SHARED_DIR)
        json.dump(config, sys.stdout, indent=2)
        print()
        return

    try:
        run(dotfiles_dir)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"command failed ({exc.returncode}): {' '.join(exc.cmd)}") from exc


if __name__ == "__main__":
    main()
