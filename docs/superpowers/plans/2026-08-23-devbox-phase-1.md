# devbox Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the `ghcr.io/lkshrk/devbox/<variant>` image family, a new `devbox` Coder template and a local `devbox` launcher, next to everything that exists today, without touching h-cloud.

**Architecture:** One multi-stage `image/Containerfile` whose tool stages run omni with `HOME=/opt/devbox`, so every dotfiles-defined tool lands under `/opt/devbox` and survives a PVC mounted over `/home/dev`. `docker-bake.hcl` fans the file out into seven variants. A single `devbox-init` script is the runtime entrypoint for Docker, Kubernetes and the Coder startup script. Secrets only via env at start.

**Tech Stack:** Debian trixie, omni (lkshrk/omni), lkshrk/dotfiles, Docker BuildKit + bake, GitHub Actions, Coder Terraform provider, bats-core + shellcheck for tests.

**Spec:** `docs/superpowers/specs/2026-08-23-devbox-image-design.md`

## Global Constraints

- Base image `docker.io/library/debian:trixie-slim`; user `dev`, uid/gid `1000`, sudo NOPASSWD.
- Build-time `HOME=/opt/devbox`; runtime `HOME=/home/dev`. `/opt/devbox` owned by root, mode `755`, never written at runtime.
- Runtime `PATH`: `$HOME/.local/bin:$HOME/.bun/bin:$HOME/go/bin:$HOME/.cargo/bin:/opt/devbox/.local/bin:/opt/devbox/.bun/bin:/opt/devbox/go/bin:/opt/devbox/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- Variants and their stages: `go`, `python`, `ts` (+browser), `lua`, `full` (all + browser + infra), `hermes` (full + agent hermes), `pilot` (full + agent pilot).
- Registry layout `ghcr.io/lkshrk/devbox/<variant>:<calver>` and `:latest`; every image carries `org.opencontainers.image.source=https://github.com/lkshrk/auto-code-env`.
- Image contains no secrets; build uses no secrets. `devbox-init` materialises only `CODEX_AUTH_JSON` -> `~/.codex/auth.json` (0600).
- Containerfile: one `RUN` per stage calling a script in `image/scripts/`, no prose comments; rationale lives in `docs/architecture.md`.
- Comments in shell/Terraform: none unless a one-line non-obvious fact. No task/PR references in code.
- Nothing in `lkshrk/h-cloud` is modified or deleted in this phase. The existing `hermes-hq` image job, `coder/templates/hermes-worker-*` and their push workflow keep working unchanged.
- Coder template name `devbox`; Coder URL `https://coder.h-cloud.io`; secret `CODER_SESSION_TOKEN` already exists in this repo.

---

## File structure

```
image/
  Containerfile                 stages base..runtime, one RUN each
  scripts/
    10-base.sh                  apt prereqs, user, sudo, dpkg path-excludes
    20-omni.sh                  omni binary + dotfiles clone to /opt/devbox/dotfiles
    30-tools.sh                 omni tools sync "$@" with HOME=/opt/devbox
    40-browser.sh               playwright install-deps chromium firefox
    50-finalize.sh              node symlinks, chown root, strip caches
    devbox-init                 runtime entrypoint (copied to /usr/local/bin)
    devbox.sh                   /etc/profile.d/devbox.sh (PATH, cache env)
docker-bake.hcl                 variant matrix
tests/
  smoke/run.sh                  runs inside a built variant; arg = variant
  devbox.bats                   tests for scripts/devbox with a fake docker
  devbox-init.bats              tests for devbox-init with a fake omni/git
scripts/
  devbox                        local launcher
  devbox.env.example            env file template
coder/devbox/
  main.tf                       providers, params, agent, pod, pvc
  presets.tf                    coder_workspace_preset blocks
.github/workflows/
  validate.yaml                 lint + bake all variants + smoke
  release.yaml                  adds bake --push job next to the hermes-hq job
  coder-templates.yaml          adds devbox push
docs/architecture.md            layer/install-layout rationale
README.md                       devbox section
```

External: `lkshrk/dotfiles` gets the `devbox` host, `agent-hermes`, `agent-pilot` groups and the `pilot` tool (Task 1).

---

### Task 1: dotfiles - `devbox` omni host, agent groups, pilot tool

**Files:**
- Modify: `~/Dev/dotfiles/dotfiles/omni/.config/omni/settings.json` (`host_settings`, `hosts`)
- Modify: `~/Dev/dotfiles/dotfiles/omni/.config/omni/settings.d/groups.json`
- Modify: `~/Dev/dotfiles/dotfiles/omni/.config/omni/settings.d/tools.json`
- Test: `~/Dev/dotfiles/tests/omni-devbox-profile.sh`

**Interfaces:**
- Produces: omni host `devbox` with groups `ai ai-plugins core dev dev-tooling go infra lua prereqs python shell test-tooling ts`; groups `agent-hermes` = `camofox-browser hermes`, `agent-pilot` = `pilot`; tool `pilot` (script provider, GitHub release tarball from `lkshrk/pilot`). Consumed by every `30-tools.sh` call in Task 4.

- [ ] **Step 1: Write the failing profile test**

`~/Dev/dotfiles/tests/omni-devbox-profile.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dotfiles/omni/.config/omni/settings.json"

want_groups="ai ai-plugins core dev dev-tooling go infra lua prereqs python shell test-tooling ts"
got_groups=$(OMNI_HOSTNAME=devbox omni --config "$cfg" settings show --format json | jq -r '.hosts.devbox | sort | join(" ")')
[ "$got_groups" = "$want_groups" ] || { echo "devbox host groups: got '$got_groups'"; exit 1; }

for bad in desk gaming mac priv utils omni; do
  if OMNI_HOSTNAME=devbox omni --config "$cfg" settings show --format json | jq -e --arg g "$bad" '.hosts.devbox | index($g)' >/dev/null; then
    echo "devbox host must not include group $bad"; exit 1
  fi
done

groups_json="$(dirname "$cfg")/settings.d/groups.json"
[ "$(jq -r '.groups[] | select(.name=="agent-hermes") | .tools | join(" ")' "$groups_json")" = "camofox-browser hermes" ] || { echo "agent-hermes group wrong"; exit 1; }
[ "$(jq -r '.groups[] | select(.name=="agent-pilot") | .tools | join(" ")' "$groups_json")" = "pilot" ] || { echo "agent-pilot group wrong"; exit 1; }

tools_json="$(dirname "$cfg")/settings.d/tools.json"
jq -e '.tools.pilot.providers[0].provider == "script"' "$tools_json" >/dev/null || { echo "pilot tool missing"; exit 1; }
echo ok
```

- [ ] **Step 2: Run it, expect failure**

Run: `cd ~/Dev/dotfiles && chmod +x tests/omni-devbox-profile.sh && tests/omni-devbox-profile.sh`
Expected: `devbox host groups: got ''` (or jq null) - exit 1.

- [ ] **Step 3: Add the host**

In `settings.json`, under `host_settings` add (copy of `hermes`, same provider priority):

```json
"devbox": {
  "dots_repo": "~/dotfiles",
  "dots_disabled": false,
  "disabled_providers": ["brew"],
  "provider_priority": ["bun", "uv", "script", "apt", "npm", "pnpm", "pip"]
}
```

Under `hosts` add:

```json
"devbox": [
  "ai", "ai-plugins", "core", "dev", "dev-tooling", "go", "infra", "lua",
  "prereqs", "python", "shell", "test-tooling", "ts"
]
```

- [ ] **Step 4: Add the groups**

In `groups.json` `groups` array append:

```json
{ "name": "agent-hermes", "special": "host", "tools": ["camofox-browser", "hermes"] },
{ "name": "agent-pilot",  "special": "host", "tools": ["pilot"] }
```

`"special": "host"` mirrors the existing `hermes` group: the group is only synced when named explicitly, never as part of a host's default set.

- [ ] **Step 5: Add the pilot tool**

In `tools.json` under `tools` add:

```json
"pilot": {
  "providers": [
    {
      "provider": "script",
      "bin": "pilot",
      "options": {
        "check": "command -v pilot || test -x \"$HOME/.local/bin/pilot\"",
        "install": "set -eu; arch=$(uname -m); case \"$arch\" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo \"unsupported arch $arch\" >&2; exit 1 ;; esac; os=$(uname -s | tr '[:upper:]' '[:lower:]'); tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; curl -fsSL --proto-redir '=https' \"https://github.com/lkshrk/pilot/releases/latest/download/pilot-${os}-${arch}.tar.gz\" | tar -xz -C \"$tmp\"; install -Dm755 \"$tmp/pilot\" \"$HOME/.local/bin/pilot\"",
        "latest": "release=$(curl -fsSLI --proto-redir '=https' -o /dev/null -w '%{url_effective}' https://github.com/lkshrk/pilot/releases/latest); echo \"${release#*releases/tag/}\"",
        "version": "pilot version 2>/dev/null | head -1",
        "uninstall": "rm -f \"$HOME/.local/bin/pilot\""
      }
    }
  ],
  "git": "https://github.com/lkshrk/pilot"
}
```

Check the archive layout first: `curl -fsSL https://github.com/lkshrk/pilot/releases/latest/download/pilot-linux-amd64.tar.gz | tar -tz`. If the binary sits in a subdirectory, adjust the `install -Dm755` source path.

- [ ] **Step 6: Run the test, expect pass**

Run: `cd ~/Dev/dotfiles && tests/omni-devbox-profile.sh && tests/omni-hermes-profile.sh`
Expected: `ok` from both (the hermes profile test must still pass - host `hermes` unchanged).

- [ ] **Step 7: Commit and open PR in dotfiles**

```bash
cd ~/Dev/dotfiles
git checkout -b feat/omni-devbox-host
git add dotfiles/omni/.config/omni/settings.json dotfiles/omni/.config/omni/settings.d/groups.json dotfiles/omni/.config/omni/settings.d/tools.json tests/omni-devbox-profile.sh
git commit -m "feat(omni): devbox host, agent-hermes/agent-pilot groups, pilot tool"
git push -u origin feat/omni-devbox-host
gh pr create --fill
```

Record the branch name: Tasks 4 and 7 build against `DOTFILES_REF=feat/omni-devbox-host` until the PR is merged, then `main`.

---

### Task 2: `devbox-init` runtime entrypoint (with bats tests)

**Files:**
- Create: `image/scripts/devbox-init`
- Create: `image/scripts/devbox.sh`
- Create: `tests/devbox-init.bats`
- Create: `tests/helpers/fake-bin/omni`, `tests/helpers/fake-bin/git`

**Interfaces:**
- Produces: `/usr/local/bin/devbox-init [cmd...]` - env `DEVBOX_DOTFILES_URL` (default `https://github.com/lkshrk/dotfiles.git`), `DEVBOX_DOTS` (`1`|`0`, default `1`), `CODEX_AUTH_JSON` (optional), `OMNI_HOSTNAME` (set in image to `devbox`). Exec's the given command, default `sleep infinity`. Consumed by Task 5 (Containerfile), Task 8 (Coder), Task 9 (local launcher).
- Produces: `/etc/profile.d/devbox.sh` exporting PATH and cache env.

- [ ] **Step 1: Install bats locally if missing**

Run: `command -v bats || omni tools install bats-core`

- [ ] **Step 2: Write fake binaries for tests**

`tests/helpers/fake-bin/git`:

```bash
#!/usr/bin/env bash
echo "git $*" >> "$FAKE_LOG"
case "$1" in
  clone) mkdir -p "${@: -1}/.git" ;;
esac
exit 0
```

`tests/helpers/fake-bin/omni`:

```bash
#!/usr/bin/env bash
echo "omni $*" >> "$FAKE_LOG"
exit 0
```

Run: `chmod +x tests/helpers/fake-bin/*`

- [ ] **Step 3: Write the failing tests**

`tests/devbox-init.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export FAKE_LOG="$BATS_TEST_TMPDIR/log"
  : > "$FAKE_LOG"
  export PATH="$BATS_TEST_DIRNAME/helpers/fake-bin:$PATH"
  export DEVBOX_INIT="$BATS_TEST_DIRNAME/../image/scripts/devbox-init"
  unset DEVBOX_DOTS CODEX_AUTH_JSON
}

@test "clones dotfiles when missing and syncs dots" {
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  grep -q "git clone --quiet https://github.com/lkshrk/dotfiles.git $HOME/dotfiles" "$FAKE_LOG"
  grep -q "omni --yes dots sync --use-repo" "$FAKE_LOG"
}

@test "fetches but never resets an existing checkout" {
  mkdir -p "$HOME/dotfiles/.git"
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  grep -q "git -C $HOME/dotfiles fetch --quiet origin" "$FAKE_LOG"
  ! grep -qE "git .*(reset|clean|checkout|pull)" "$FAKE_LOG"
}

@test "refuses a non-git dotfiles dir" {
  mkdir -p "$HOME/dotfiles"
  run "$DEVBOX_INIT" true
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git checkout"* ]]
}

@test "DEVBOX_DOTS=0 skips dots sync" {
  DEVBOX_DOTS=0 run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  ! grep -q "dots sync" "$FAKE_LOG"
}

@test "writes codex auth from env with mode 0600" {
  CODEX_AUTH_JSON='{"k":"v"}' run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.codex/auth.json")" = '{"k":"v"}' ]
  [ "$(stat -f %Lp "$HOME/.codex/auth.json" 2>/dev/null || stat -c %a "$HOME/.codex/auth.json")" = "600" ]
}

@test "creates tmp and ssh dirs with strict modes" {
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  [ "$(stat -f %Lp "$HOME/.tmp" 2>/dev/null || stat -c %a "$HOME/.tmp")" = "700" ]
  [ "$(stat -f %Lp "$HOME/.ssh" 2>/dev/null || stat -c %a "$HOME/.ssh")" = "700" ]
}

@test "execs the given command and propagates its exit code" {
  run "$DEVBOX_INIT" sh -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "never echoes env values" {
  CODEX_AUTH_JSON='SECRETVALUE' run "$DEVBOX_INIT" true
  [[ "$output" != *SECRETVALUE* ]]
}
```

- [ ] **Step 4: Run, expect failure**

Run: `bats tests/devbox-init.bats`
Expected: all fail (`devbox-init: No such file`).

- [ ] **Step 5: Write `devbox-init`**

`image/scripts/devbox-init`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${DEVBOX_DOTFILES_URL:=https://github.com/lkshrk/dotfiles.git}"
: "${DEVBOX_DOTS:=1}"
dotfiles="$HOME/dotfiles"

umask 077
mkdir -p "$HOME/.tmp" "$HOME/.ssh"
chmod 700 "$HOME/.tmp" "$HOME/.ssh"
umask 022

if ! grep -qs '^github.com ' "$HOME/.ssh/known_hosts" 2>/dev/null; then
  ssh-keyscan -t ed25519,rsa github.com codeberg.org 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
fi

if [ -n "${CODEX_AUTH_JSON:-}" ]; then
  mkdir -p "$HOME/.codex"
  (umask 077; printf '%s' "$CODEX_AUTH_JSON" > "$HOME/.codex/auth.json")
fi

if [ -d "$dotfiles/.git" ]; then
  git -C "$dotfiles" remote set-url origin "$DEVBOX_DOTFILES_URL" || true
  git -C "$dotfiles" fetch --quiet origin || echo "devbox-init: dotfiles fetch failed, continuing" >&2
elif [ -e "$dotfiles" ]; then
  echo "devbox-init: $dotfiles exists but is not a git checkout" >&2
  exit 1
else
  git clone --quiet "$DEVBOX_DOTFILES_URL" "$dotfiles"
fi

if [ "$DEVBOX_DOTS" = "1" ]; then
  omni --yes dots sync --use-repo
fi

for d in "$HOME/.local/bin" "$HOME/.bun/bin"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] || continue
    img="/opt/devbox/${d#"$HOME"/}/$(basename "$f")"
    [ -x "$img" ] && echo "devbox-init: $(basename "$f") from $d shadows image copy $img" >&2
  done
done

if [ $# -eq 0 ]; then
  set -- sleep infinity
fi
exec "$@"
```

- [ ] **Step 6: Write `devbox.sh` (profile.d)**

`image/scripts/devbox.sh`:

```bash
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/go/bin:$HOME/.cargo/bin:/opt/devbox/.local/bin:/opt/devbox/.bun/bin:/opt/devbox/go/bin:/opt/devbox/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TMPDIR="$HOME/.tmp"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export UV_CACHE_DIR="$HOME/.cache/uv"
export npm_config_store_dir="$HOME/.local/share/pnpm/store"
export pnpm_config_store_dir="$HOME/.local/share/pnpm/store"
export BUN_INSTALL_CACHE_DIR="$HOME/.cache/bun"
export GOPATH="$HOME/go"
export GOCACHE="$HOME/.cache/go-build"
export GOMODCACHE="$HOME/go/pkg/mod"
export OMNI_HOSTNAME="${OMNI_HOSTNAME:-devbox}"
```

- [ ] **Step 7: Run tests, expect pass; shellcheck**

Run: `chmod +x image/scripts/devbox-init && bats tests/devbox-init.bats && shellcheck image/scripts/devbox-init image/scripts/devbox.sh`
Expected: 8 tests pass, shellcheck clean. (`shellcheck` via `omni tools install shellcheck` if missing.)

- [ ] **Step 8: Commit**

```bash
git add image/scripts/devbox-init image/scripts/devbox.sh tests/devbox-init.bats tests/helpers
git commit -m "feat(image): devbox-init runtime entrypoint and profile env"
```

---

### Task 3: Build-stage scripts

**Files:**
- Create: `image/scripts/10-base.sh`, `20-omni.sh`, `30-tools.sh`, `40-browser.sh`, `50-finalize.sh`

**Interfaces:**
- Consumes: dotfiles scripts `scripts/install-omni-latest.sh` (Task 1 branch), omni host `devbox`.
- Produces: scripts invoked by Task 5's Containerfile with these contracts:
  - `10-base.sh` - runs as root, args none, env `DEVBOX_USER DEVBOX_UID DEVBOX_GID`.
  - `20-omni.sh` - runs as root, env `DOTFILES_REPO DOTFILES_REF DOTFILES_COMMIT`; leaves `/opt/devbox/.local/bin/omni` and `/opt/devbox/dotfiles`.
  - `30-tools.sh GROUP...` - runs as `dev` with `HOME=/opt/devbox`.
  - `40-browser.sh` - runs as `dev`, needs bun from `prereqs`.
  - `50-finalize.sh` - runs as root; node symlinks, ownership, cache strip.

- [ ] **Step 1: `10-base.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cat > /etc/dpkg/dpkg.cfg.d/01-devbox-nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
EOF

apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg jq less locales ncurses-bin openssh-client openssl \
  pkg-config procps stow sudo unzip xz-utils zsh libssl-dev
rm -rf /var/lib/apt/lists/*

groupadd --gid "$DEVBOX_GID" "$DEVBOX_USER"
useradd --uid "$DEVBOX_UID" --gid "$DEVBOX_GID" --create-home --shell /bin/zsh "$DEVBOX_USER"
echo "$DEVBOX_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEVBOX_USER"
chmod 0440 "/etc/sudoers.d/90-$DEVBOX_USER"

install -d -o "$DEVBOX_USER" -g "$DEVBOX_GID" -m 755 /opt/devbox
```

The apt list is dotfiles' `install_apt_packages` minus `build-essential` plus `sudo openssh-client procps gnupg less locales` (coder agent, git over ssh, `coder stat`, apt-repo providers).

- [ ] **Step 2: `20-omni.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

export HOME=/opt/devbox
cd "$HOME"

echo "dotfiles ${DOTFILES_REF} @ ${DOTFILES_COMMIT}"
git clone --depth 1 --branch "$DOTFILES_REF" "$DOTFILES_REPO" "$HOME/dotfiles"

bash "$HOME/dotfiles/scripts/install-omni-latest.sh"
"$HOME/.local/bin/omni" --version
OMNI_HOSTNAME=devbox "$HOME/.local/bin/omni" --config "$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json" settings show --format json >/dev/null
```

Check `install-omni-latest.sh` installs to `$HOME/.local/bin/omni` (it does today, see `image/Containerfile` layer 3 which mirrors it). If it needs root or writes elsewhere, inline the current Containerfile's curl/tar block instead.

- [ ] **Step 3: `30-tools.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: 30-tools.sh GROUP..." >&2; exit 2; }

export HOME=/opt/devbox
export OMNI_HOSTNAME=devbox
export OMNI_CONFIG="$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/go/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

sudo apt-get update -qq
omni --config "$OMNI_CONFIG" --yes tools sync "$@"
sudo rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 4: `40-browser.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
export HOME=/opt/devbox
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

sudo apt-get update -qq
bunx --bun playwright install-deps chromium firefox
sudo rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 5: `50-finalize.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
opt=/opt/devbox

node_bin=$(ls -d "$opt"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$node_bin" ]; then
  for b in node npm npx corepack; do
    [ -x "$node_bin/$b" ] && ln -sf "$node_bin/$b" "$opt/.local/bin/$b"
  done
fi

rm -rf "$opt"/.cache "$opt"/.npm "$opt"/.bun/install/cache "$opt"/go/pkg/mod/cache "$opt"/.tmp
find "$opt" -name '*.pyc' -delete

chown -R root:root "$opt"
chmod -R u=rwX,go=rX "$opt"
```

- [ ] **Step 6: shellcheck and commit**

Run: `chmod +x image/scripts/*.sh && shellcheck image/scripts/*.sh`
Expected: clean.

```bash
git add image/scripts
git commit -m "feat(image): build stage scripts"
```

---

### Task 4: Smoke test

**Files:**
- Create: `tests/smoke/run.sh`
- Delete: `tests/smoke/.gitkeep`

**Interfaces:**
- Produces: `tests/smoke/run.sh VARIANT` - executed *inside* a container of that variant (`docker run --rm -v $PWD/tests/smoke:/smoke:ro IMAGE /smoke/run.sh VARIANT`). Exit 0 = pass. Consumed by Task 7's `validate.yaml`.

- [ ] **Step 1: Write it**

```bash
#!/usr/bin/env bash
set -euo pipefail
variant="${1:?variant}"
fail=0
check() { printf '%-28s' "$1"; if out=$(bash -lc "$2" 2>&1); then echo "ok  ${out%%$'\n'*}"; else echo "FAIL"; echo "$out" | sed 's/^/    /'; fail=1; fi; }

[ "$(id -u)" = 1000 ] || { echo "uid is $(id -u), want 1000"; fail=1; }
[ "$HOME" = /home/dev ] || { echo "HOME is $HOME"; fail=1; }
[ "$(stat -c %U /opt/devbox)" = root ] || { echo "/opt/devbox not root-owned"; fail=1; }
touch /opt/devbox/x 2>/dev/null && { echo "/opt/devbox writable"; fail=1; }

check "omni"        "omni --version"
check "claude"      "claude --version"
check "codex"       "codex --version"
check "gh"          "gh --version"
check "bun"         "bun --version"
check "node"        "node --version"
check "uv"          "uv --version"
check "nvim"        "nvim --version | head -1"
check "tmux"        "tmux -V"
check "zsh"         "zsh --version"

case "$variant" in
  go|full|hermes|pilot)      check "go" "go version"; check "golangci-lint" "golangci-lint --version" ;;
esac
case "$variant" in
  python|full|hermes|pilot)  check "python" "python3 --version"; check "pyright" "pyright --version" ;;
esac
case "$variant" in
  ts|full|hermes|pilot)      check "pnpm" "pnpm --version"; check "playwright deps" "ldconfig -p | grep -q libnss3" ;;
esac
case "$variant" in
  lua|full|hermes|pilot)     check "lua-language-server" "lua-language-server --version"; check "stylua" "stylua --version" ;;
esac
case "$variant" in
  full|hermes|pilot)         check "kubectl" "kubectl version --client"; check "flux" "flux --version"; check "helm" "helm version --short" ;;
esac
case "$variant" in
  hermes) check "hermes" "hermes --version"; check "hermes (foreign HOME)" "HOME=/tmp/h$$ hermes --version" ;;
  pilot)  check "pilot"  "pilot version";    check "pilot (foreign HOME)"  "HOME=/tmp/p$$ pilot version" ;;
esac

check "devbox-init dots"  "DEVBOX_DOTS=1 HOME=/tmp/init$$ devbox-init true"
check "devbox-init nodots" "DEVBOX_DOTS=0 devbox-init true"

if grep -rEIl 'ghp_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY' /opt/devbox /etc 2>/dev/null | head -1 | grep -q .; then
  echo "token-like string found in image"; fail=1
fi

exit $fail
```

The `devbox-init dots` check needs network (clones dotfiles). CI runners have it; locally skip with `DEVBOX_SMOKE_OFFLINE=1` - add at top: `[ "${DEVBOX_SMOKE_OFFLINE:-0}" = 1 ] && check() { :; }` is too coarse; instead guard only that one line with `[ "${DEVBOX_SMOKE_OFFLINE:-0}" = 1 ] || check "devbox-init dots" ...`.

- [ ] **Step 2: Run against any image to see the harness itself works**

Run: `docker run --rm -v "$PWD/tests/smoke:/smoke:ro" debian:trixie-slim bash /smoke/run.sh go; echo "exit $?"`
Expected: many `FAIL` lines, exit 1 - proves the script reports failure.

- [ ] **Step 3: Commit**

```bash
chmod +x tests/smoke/run.sh
git rm -q tests/smoke/.gitkeep
git add tests/smoke/run.sh
git commit -m "test: per-variant image smoke test"
```

---

### Task 5: Containerfile and bake file

**Files:**
- Rewrite: `image/Containerfile`
- Create: `docker-bake.hcl`
- Modify: `image/.dockerignore` (create if missing)

**Interfaces:**
- Consumes: Task 2 scripts, Task 3 scripts, Task 1 dotfiles branch.
- Produces: bake targets `go python ts lua full hermes pilot` and group `default` (all). Args `DOTFILES_REF`, `DOTFILES_COMMIT`, `REGISTRY` (default `ghcr.io/lkshrk/devbox`), `VERSION` (default `dev`). Tags `${REGISTRY}/<variant>:${VERSION}` and `:latest`.

- [ ] **Step 1: Write the Containerfile**

```dockerfile
FROM docker.io/library/debian:trixie-slim AS base
ARG DEVBOX_USER=dev
ARG DEVBOX_UID=1000
ARG DEVBOX_GID=1000
ENV DEVBOX_USER=${DEVBOX_USER} DEVBOX_UID=${DEVBOX_UID} DEVBOX_GID=${DEVBOX_GID}
COPY scripts/10-base.sh /tmp/
RUN bash /tmp/10-base.sh && rm /tmp/10-base.sh

FROM base AS omni
ARG DOTFILES_REPO=https://github.com/lkshrk/dotfiles.git
ARG DOTFILES_REF=main
ARG DOTFILES_COMMIT=unknown
ENV DOTFILES_REPO=${DOTFILES_REPO} DOTFILES_REF=${DOTFILES_REF} DOTFILES_COMMIT=${DOTFILES_COMMIT}
USER ${DEVBOX_USER}
COPY --chmod=755 scripts/20-omni.sh scripts/30-tools.sh scripts/40-browser.sh /opt/devbox-build/
RUN /opt/devbox-build/20-omni.sh

FROM omni AS core
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh prereqs core shell dev dev-tooling test-tooling

FROM core AS ai
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh ai ai-plugins

FROM ai AS stack-go
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh go

FROM ai AS stack-python
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh python

FROM ai AS stack-ts
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh ts
RUN /opt/devbox-build/40-browser.sh

FROM ai AS stack-lua
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh lua

FROM ai AS stack-full
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh go
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh python
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh ts
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh lua
RUN /opt/devbox-build/40-browser.sh
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh infra

FROM stack-full AS stack-hermes
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh agent-hermes

FROM stack-full AS stack-pilot
RUN --mount=type=cache,target=/opt/devbox/.cache,uid=1000,gid=1000 \
    /opt/devbox-build/30-tools.sh agent-pilot

FROM stack-${VARIANT} AS runtime
ARG VARIANT
USER root
COPY --chmod=755 scripts/50-finalize.sh /tmp/
RUN /tmp/50-finalize.sh && rm -rf /tmp/50-finalize.sh /opt/devbox-build
COPY --chmod=755 scripts/devbox-init /usr/local/bin/devbox-init
COPY --chmod=644 scripts/devbox.sh /etc/profile.d/devbox.sh
ENV HOME=/home/dev \
    OMNI_HOSTNAME=devbox \
    DEVBOX_VARIANT=${VARIANT} \
    PATH=/home/dev/.local/bin:/home/dev/.bun/bin:/home/dev/go/bin:/home/dev/.cargo/bin:/opt/devbox/.local/bin:/opt/devbox/.bun/bin:/opt/devbox/go/bin:/opt/devbox/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER dev
WORKDIR /home/dev
ENTRYPOINT ["/usr/local/bin/devbox-init"]
CMD ["sleep", "infinity"]
```

`ARG VARIANT` must be declared once before the first `FROM` that uses it - add `ARG VARIANT=full` as the very first line of the file.

- [ ] **Step 2: Write `docker-bake.hcl`**

```hcl
variable "REGISTRY" { default = "ghcr.io/lkshrk/devbox" }
variable "VERSION" { default = "dev" }
variable "DOTFILES_REF" { default = "main" }
variable "DOTFILES_COMMIT" { default = "unknown" }

group "default" {
  targets = ["go", "python", "ts", "lua", "full", "hermes", "pilot"]
}

target "_common" {
  context    = "image"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  args = {
    DOTFILES_REF    = DOTFILES_REF
    DOTFILES_COMMIT = DOTFILES_COMMIT
  }
  labels = {
    "org.opencontainers.image.source"   = "https://github.com/lkshrk/auto-code-env"
    "org.opencontainers.image.revision" = VERSION
    "io.lkshrk.devbox.dotfiles-commit"  = DOTFILES_COMMIT
  }
  output = ["type=image,compression=zstd,force-compression=true"]
}

target "go"     { inherits = ["_common"]; args = { VARIANT = "go" };     tags = ["${REGISTRY}/go:${VERSION}", "${REGISTRY}/go:latest"] }
target "python" { inherits = ["_common"]; args = { VARIANT = "python" }; tags = ["${REGISTRY}/python:${VERSION}", "${REGISTRY}/python:latest"] }
target "ts"     { inherits = ["_common"]; args = { VARIANT = "ts" };     tags = ["${REGISTRY}/ts:${VERSION}", "${REGISTRY}/ts:latest"] }
target "lua"    { inherits = ["_common"]; args = { VARIANT = "lua" };    tags = ["${REGISTRY}/lua:${VERSION}", "${REGISTRY}/lua:latest"] }
target "full"   { inherits = ["_common"]; args = { VARIANT = "full" };   tags = ["${REGISTRY}/full:${VERSION}", "${REGISTRY}/full:latest"] }
target "hermes" { inherits = ["_common"]; args = { VARIANT = "hermes" }; tags = ["${REGISTRY}/hermes:${VERSION}", "${REGISTRY}/hermes:latest"] }
target "pilot"  { inherits = ["_common"]; args = { VARIANT = "pilot" };  tags = ["${REGISTRY}/pilot:${VERSION}", "${REGISTRY}/pilot:latest"] }
```

Bake merges `args` maps from `_common` and the child, so `DOTFILES_*` survive. `target.args` override per target only the `VARIANT` key.

- [ ] **Step 3: `image/.dockerignore`**

```
*
!scripts/
```

- [ ] **Step 4: Build one small variant locally**

Run: `docker buildx bake go --set '*.output=type=docker' --set "*.args.DOTFILES_REF=feat/omni-devbox-host" --set "*.args.DOTFILES_COMMIT=$(git -C ~/Dev/dotfiles rev-parse --short HEAD)" 2>&1 | tail -30`
Expected: image `ghcr.io/lkshrk/devbox/go:dev` loaded. On failure read the failing stage's script output; typical first-build issues: a tool's `check`/`install` assuming `$HOME/.bashrc`, apt-repo providers needing `gnupg`, `nvm` needing `.nvm` sourced (all handled by `30-tools.sh` PATH/HOME).

- [ ] **Step 5: Smoke it**

Run: `docker run --rm -v "$PWD/tests/smoke:/smoke:ro" -e DEVBOX_SMOKE_OFFLINE=1 ghcr.io/lkshrk/devbox/go:dev /smoke/run.sh go`
Expected: all `ok`, exit 0. Fix scripts until it passes; for any tool that only works with `HOME=/opt/devbox`, note it in `docs/architecture.md` (Task 10) and decide: symlink fix in `50-finalize.sh`, or drop from `devbox` host.

- [ ] **Step 6: Measure**

Run: `docker image ls ghcr.io/lkshrk/devbox/go:dev --format '{{.Size}}' && docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' ghcr.io/lkshrk/devbox/go:dev | sort -h | tail -8`
Expected: under 2 GB. If a layer is surprisingly large, add its cache path to `50-finalize.sh` or to the cache mount.

- [ ] **Step 7: Build and smoke `full`, `hermes`, `pilot`**

Run: `docker buildx bake full hermes pilot --set '*.output=type=docker' --set "*.args.DOTFILES_REF=feat/omni-devbox-host"` then `for v in full hermes pilot; do docker run --rm -v "$PWD/tests/smoke:/smoke:ro" -e DEVBOX_SMOKE_OFFLINE=1 ghcr.io/lkshrk/devbox/$v:dev /smoke/run.sh $v || echo "FAILED $v"; done`
Expected: all pass; `hermes (foreign HOME)` is the check most likely to fail - if hermes resolves its venv via `$HOME`, add to `50-finalize.sh`: `ln -sfn /opt/devbox/.hermes /etc/skel/.hermes` is wrong (state dir); instead wrap: write `/opt/devbox/.local/bin/hermes` as `exec /opt/devbox/.hermes/<venv>/bin/hermes "$@"` after inspecting the installed launcher.

- [ ] **Step 8: Commit**

```bash
git add image/Containerfile image/.dockerignore docker-bake.hcl
git commit -m "feat(image): multi-stage Containerfile and bake matrix for devbox variants"
```

---

### Task 6: Local launcher `scripts/devbox`

**Files:**
- Create: `scripts/devbox`
- Create: `scripts/devbox.env.example`
- Create: `tests/devbox.bats`
- Create: `tests/helpers/fake-bin/docker`
- Modify: `.gitignore` (add `scripts/devbox.env`)

**Interfaces:**
- Produces CLI:
  - `devbox up NAME [--image VARIANT] [-v HOST:CTR]... [-w DIR]` - `docker run -d --name devbox-NAME`, volume `devbox-NAME-home:/home/dev`, env file, ssh-agent socket, image `ghcr.io/lkshrk/devbox/VARIANT:latest` (default `full`).
  - `devbox sh NAME` - `docker exec -it devbox-NAME zsh -l`.
  - `devbox run [--image VARIANT] [-v ...] -- CMD...` - `docker run --rm -it`, same env/socket, ephemeral home.
  - `devbox stop NAME`, `devbox rm NAME` (rm also deletes the home volume after a y/N prompt), `devbox ls`.
  - Env: `DEVBOX_ENV_FILE` (default `~/.config/devbox/env`), `DEVBOX_REGISTRY` (default `ghcr.io/lkshrk/devbox`), `DEVBOX_RUNTIME` (`docker`|`podman`, default `docker`).

- [ ] **Step 1: Fake docker**

`tests/helpers/fake-bin/docker`:

```bash
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
exit 0
```

- [ ] **Step 2: Failing tests**

`tests/devbox.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export FAKE_LOG="$BATS_TEST_TMPDIR/log"; : > "$FAKE_LOG"
  export PATH="$BATS_TEST_DIRNAME/helpers/fake-bin:$PATH"
  export DEVBOX="$BATS_TEST_DIRNAME/../scripts/devbox"
  export DEVBOX_ENV_FILE="$BATS_TEST_TMPDIR/env"; : > "$DEVBOX_ENV_FILE"; chmod 600 "$DEVBOX_ENV_FILE"
  export SSH_AUTH_SOCK="$BATS_TEST_TMPDIR/agent.sock"; : > "$SSH_AUTH_SOCK"
  unset DEVBOX_REGISTRY DEVBOX_RUNTIME
}

@test "up runs detached with named home volume and default full image" {
  run "$DEVBOX" up api
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"-d"* ]]
  [[ "$line" == *"--name devbox-api"* ]]
  [[ "$line" == *"-v devbox-api-home:/home/dev"* ]]
  [[ "$line" == *"--env-file $DEVBOX_ENV_FILE"* ]]
  [[ "$line" == *"ghcr.io/lkshrk/devbox/full:latest"* ]]
}

@test "up honours --image and extra -v" {
  run "$DEVBOX" up api --image go -v /tmp/x:/work
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"ghcr.io/lkshrk/devbox/go:latest"* ]]
  [[ "$line" == *"-v /tmp/x:/work"* ]]
}

@test "up refuses a world-readable env file" {
  chmod 644 "$DEVBOX_ENV_FILE"
  run "$DEVBOX" up api
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 600"* ]]
}

@test "sh execs zsh login shell" {
  run "$DEVBOX" sh api
  grep -q '^docker exec -it devbox-api zsh -l' "$FAKE_LOG"
}

@test "run is ephemeral and passes the command" {
  run "$DEVBOX" run --image ts -- claude -p hi
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"--rm"* ]]
  [[ "$line" == *"devbox/ts:latest claude -p hi"* ]]
  [[ "$line" != *"-home:/home/dev"* ]]
}

@test "rm deletes container and volume after confirmation" {
  run bash -c "echo y | '$DEVBOX' rm api"
  grep -q '^docker rm -f devbox-api' "$FAKE_LOG"
  grep -q '^docker volume rm devbox-api-home' "$FAKE_LOG"
}

@test "DEVBOX_RUNTIME=podman uses podman" {
  cp "$BATS_TEST_DIRNAME/helpers/fake-bin/docker" "$BATS_TEST_DIRNAME/helpers/fake-bin/podman"
  DEVBOX_RUNTIME=podman run "$DEVBOX" stop api
  rm "$BATS_TEST_DIRNAME/helpers/fake-bin/podman"
  grep -q '^docker stop devbox-api' "$FAKE_LOG"
}
```

(The podman fake logs as `docker` because it is a copy; the assertion is that the script invoked *something* for `stop`. Acceptable.)

- [ ] **Step 3: Run, expect failure**

Run: `bats tests/devbox.bats`
Expected: fails, script missing.

- [ ] **Step 4: Write `scripts/devbox`**

```bash
#!/usr/bin/env bash
set -euo pipefail

registry="${DEVBOX_REGISTRY:-ghcr.io/lkshrk/devbox}"
runtime="${DEVBOX_RUNTIME:-docker}"
env_file="${DEVBOX_ENV_FILE:-$HOME/.config/devbox/env}"

usage() {
  cat <<'EOF'
usage: devbox up NAME [--image VARIANT] [-v HOST:CTR]... [-w DIR]
       devbox sh NAME
       devbox run [--image VARIANT] [-v HOST:CTR]... [-w DIR] -- CMD...
       devbox stop NAME | rm NAME | ls
EOF
  exit 2
}

check_env_file() {
  [ -f "$env_file" ] || { echo "devbox: env file $env_file missing (see scripts/devbox.env.example)" >&2; exit 1; }
  mode=$(stat -f %Lp "$env_file" 2>/dev/null || stat -c %a "$env_file")
  [ "$mode" = "600" ] || { echo "devbox: $env_file must be mode 600 (is $mode)" >&2; exit 1; }
}

common_args() {
  printf '%s\n' --env-file "$env_file"
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "$SSH_AUTH_SOCK" ]; then
    case "$(uname -s)" in
      Darwin) printf '%s\n' -v /run/host-services/ssh-auth.sock:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent ;;
      *)      printf '%s\n' -v "$SSH_AUTH_SOCK:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent ;;
    esac
  fi
}

parse_opts() {
  image=full; vols=(); workdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      -v) vols+=(-v "$2"); shift 2 ;;
      -w) workdir="$2"; shift 2 ;;
      --) shift; break ;;
      -*) usage ;;
      *) break ;;
    esac
  done
  rest=("$@")
}

cmd="${1:-}"; shift || usage
case "$cmd" in
  up)
    name="${1:?NAME}"; shift
    parse_opts "$@"
    check_env_file
    mapfile -t common < <(common_args)
    "$runtime" run -d --name "devbox-$name" -v "devbox-$name-home:/home/dev" \
      "${common[@]}" "${vols[@]}" ${workdir:+-w "$workdir"} \
      "$registry/$image:latest"
    ;;
  sh)
    name="${1:?NAME}"
    "$runtime" exec -it "devbox-$name" zsh -l
    ;;
  run)
    parse_opts "$@"
    [ ${#rest[@]} -gt 0 ] || usage
    check_env_file
    mapfile -t common < <(common_args)
    "$runtime" run --rm -it "${common[@]}" "${vols[@]}" ${workdir:+-w "$workdir"} \
      "$registry/$image:latest" "${rest[@]}"
    ;;
  stop)
    "$runtime" stop "devbox-${1:?NAME}"
    ;;
  rm)
    name="${1:?NAME}"
    read -r -p "delete container devbox-$name and its home volume? [y/N] " ans
    [ "$ans" = y ] || exit 0
    "$runtime" rm -f "devbox-$name"
    "$runtime" volume rm "devbox-$name-home"
    ;;
  ls)
    "$runtime" ps -a --filter name=^devbox- --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  *) usage ;;
esac
```

- [ ] **Step 5: `scripts/devbox.env.example`**

```
# copy to ~/.config/devbox/env, chmod 600. Never commit a filled-in copy.
GH_TOKEN=
GITHUB_TOKEN=
GITHUB_PERSONAL_ACCESS_TOKEN=
CLAUDE_CODE_OAUTH_TOKEN=
CODEX_AUTH_JSON=
LITELLM_API=
```

- [ ] **Step 6: gitignore, run tests, shellcheck**

Append to `.gitignore`: `scripts/devbox.env`.

Run: `chmod +x scripts/devbox tests/helpers/fake-bin/docker && bats tests/devbox.bats && shellcheck scripts/devbox`
Expected: 7 pass, shellcheck clean (SC2086 on `${workdir:+-w "$workdir"}` may need `# shellcheck disable=SC2086` on that line - the only permitted comment).

- [ ] **Step 7: Real run**

Run: `cp scripts/devbox.env.example ~/.config/devbox/env 2>/dev/null || (mkdir -p ~/.config/devbox && cp scripts/devbox.env.example ~/.config/devbox/env); chmod 600 ~/.config/devbox/env; DEVBOX_REGISTRY=ghcr.io/lkshrk/devbox scripts/devbox run --image go -- go version`
(uses the `:latest` tag - retag local build first: `docker tag ghcr.io/lkshrk/devbox/go:dev ghcr.io/lkshrk/devbox/go:latest`.)
Expected: `go version go1.xx linux/amd64`.

- [ ] **Step 8: Commit**

```bash
git add scripts/devbox scripts/devbox.env.example tests/devbox.bats tests/helpers/fake-bin/docker .gitignore
git commit -m "feat: local devbox launcher"
```

---

### Task 7: CI - validate and release

**Files:**
- Rewrite: `.github/workflows/validate.yaml`
- Modify: `.github/workflows/release.yaml` (add job, keep `tag`, `build-and-push`, `trigger-deploy` untouched)

**Interfaces:**
- Consumes: bake targets (Task 5), `tests/smoke/run.sh` (Task 4), bats tests (Tasks 2, 6).
- Produces: on PR, every variant builds and passes smoke; on main, `release.yaml` publishes `ghcr.io/lkshrk/devbox/<variant>:<calver>` + `:latest`.

- [ ] **Step 1: `validate.yaml`**

```yaml
---
name: validate

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

env:
  DOTFILES_REF: feat/omni-devbox-host

jobs:
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: shellcheck
        run: shellcheck image/scripts/*.sh image/scripts/devbox-init scripts/devbox tests/smoke/run.sh
      - name: yamllint
        run: |
          pipx install yamllint
          yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}}}" .github/workflows
      - name: gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - name: bats
        run: |
          sudo apt-get install -y bats
          bats tests/devbox-init.bats tests/devbox.bats

  coder-template:
    name: Coder template
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.15.5
      - run: |
          terraform -chdir=coder/devbox fmt -check -diff
          terraform -chdir=coder/devbox init -backend=false -input=false
          terraform -chdir=coder/devbox validate

  image:
    name: Image ${{ matrix.variant }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        variant: [go, python, ts, lua, full, hermes, pilot]
    steps:
      - uses: actions/checkout@v5
      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4
      - name: Resolve dotfiles commit
        id: dotfiles
        run: echo "commit=$(git ls-remote https://github.com/lkshrk/dotfiles.git "refs/heads/${DOTFILES_REF}" | cut -f1)" >> "$GITHUB_OUTPUT"
      - name: Build
        uses: docker/bake-action@v6
        with:
          targets: ${{ matrix.variant }}
          load: true
          set: |
            *.args.DOTFILES_REF=${{ env.DOTFILES_REF }}
            *.args.DOTFILES_COMMIT=${{ steps.dotfiles.outputs.commit }}
            *.cache-from=type=gha,scope=${{ matrix.variant }}
            *.cache-to=type=gha,scope=${{ matrix.variant }},mode=max
      - name: Smoke
        run: docker run --rm -v "$PWD/tests/smoke:/smoke:ro" "ghcr.io/lkshrk/devbox/${{ matrix.variant }}:dev" /smoke/run.sh "${{ matrix.variant }}"
      - name: Size
        run: docker image ls "ghcr.io/lkshrk/devbox/${{ matrix.variant }}:dev" --format '{{.Repository}} {{.Size}}'
```

The `coder-template` job replaces the old `coder-templates` loop. The existing `hermes-worker-*` templates are still validated by `coder-templates.yaml` on PRs (unchanged), so coverage is not lost. Drop the old `containerfile` and `verify-script` jobs (the `scripts/verify.sh` job only checked the old layout; delete `scripts/verify.sh` too).

Once the dotfiles PR merges, change `DOTFILES_REF` to `main` here and in `release.yaml`.

- [ ] **Step 2: Add the bake job to `release.yaml`**

After `build-and-push`, before `trigger-deploy`, insert:

```yaml
  devbox:
    name: Build & push devbox variants
    needs: tag
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4
      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Resolve dotfiles commit
        id: dotfiles
        env:
          DOTFILES_REF: feat/omni-devbox-host
        run: |
          echo "commit=$(git ls-remote https://github.com/lkshrk/dotfiles.git "refs/heads/${DOTFILES_REF}" | cut -f1)" >> "$GITHUB_OUTPUT"
          echo "ref=$DOTFILES_REF" >> "$GITHUB_OUTPUT"
      - uses: docker/bake-action@v6
        with:
          push: true
          set: |
            *.args.VERSION=${{ needs.tag.outputs.tag }}
            *.args.DOTFILES_REF=${{ steps.dotfiles.outputs.ref }}
            *.args.DOTFILES_COMMIT=${{ steps.dotfiles.outputs.commit }}
            *.cache-from=type=gha
            *.cache-to=type=gha,mode=max
        env:
          VERSION: ${{ needs.tag.outputs.tag }}
```

`VERSION` is a bake *variable*, not a build arg, so it is passed through `env` (bake reads variables from the environment); the `*.args.VERSION` line is harmless but unused - remove it.

- [ ] **Step 3: Validate workflows locally**

Run: `actionlint .github/workflows/*.yaml && yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}}}" .github/workflows`
Expected: clean.

- [ ] **Step 4: Commit, push branch, watch CI**

```bash
git rm -q scripts/verify.sh
git add .github/workflows/validate.yaml .github/workflows/release.yaml
git commit -m "ci: build, smoke and publish devbox variants"
git push -u origin HEAD
gh pr create --fill
gh run watch
```

Expected: all 7 image jobs green. Iterate on Task 3/5 scripts until they are.

---

### Task 8: Coder template `devbox`

**Files:**
- Create: `coder/devbox/main.tf`
- Create: `coder/devbox/presets.tf`
- Modify: `.github/workflows/coder-templates.yaml`

**Interfaces:**
- Consumes: published images `ghcr.io/lkshrk/devbox/<variant>:<calver>` (Task 7), `devbox-init` (Task 2).
- Produces: Coder template `devbox` with parameters `variant`, `access`, `repos`, `deployment_url`, `enable_dind`, `enable_playwright`, `cpu`, `memory`, `disk_size`, `dotfiles_url`; presets for every project that has an h-cloud template today.

- [ ] **Step 1: `main.tf`**

Derived from h-cloud's `common.tf`; differences are marked in prose after the block, not as comments in code.

```hcl
terraform {
  required_providers {
    coder      = { source = "coder/coder" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

provider "coder" {}
provider "kubernetes" { config_path = null }

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  image_version = "2026.8.0" # renovate: datasource=github-releases depName=lkshrk/auto-code-env
}

data "coder_parameter" "variant" {
  name         = "variant"
  display_name = "Image variant"
  default      = "full"
  mutable      = true
  option { name = "full (all languages)"; value = "full" }
  option { name = "go";                   value = "go" }
  option { name = "python";               value = "python" }
  option { name = "ts";                   value = "ts" }
  option { name = "lua";                  value = "lua" }
}

data "coder_parameter" "access" {
  name         = "access"
  display_name = "Cluster access profile"
  default      = "base"
  mutable      = false
  option { name = "base (coder namespace)"; value = "base" }
  option { name = "civora";                 value = "civora" }
  option { name = "routivo";                value = "routivo" }
  option { name = "pub";                    value = "pub" }
}

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start."
  default      = ""
  mutable      = true
}

data "coder_parameter" "deployment_url" {
  name         = "deployment_url"
  display_name = "Deployment URL"
  default      = ""
  mutable      = true
}

data "coder_parameter" "enable_dind" {
  name         = "enable_dind"
  display_name = "Docker-in-Docker"
  type         = "bool"
  default      = "false"
  mutable      = false
}

data "coder_parameter" "enable_playwright" {
  name         = "enable_playwright"
  display_name = "Playwright (shiplight)"
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU (cores)"
  default      = "4"
  mutable      = true
  option { name = "2"; value = "2" }
  option { name = "4"; value = "4" }
  option { name = "6"; value = "6" }
  option { name = "8"; value = "8" }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  default      = "8"
  mutable      = true
  option { name = "4";  value = "4" }
  option { name = "8";  value = "8" }
  option { name = "16"; value = "16" }
  option { name = "32"; value = "32" }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Home disk (GiB)"
  default      = "30"
  mutable      = false
  option { name = "30"; value = "30" }
  option { name = "50"; value = "50" }
}

data "coder_parameter" "dotfiles_url" {
  name         = "dotfiles_url"
  display_name = "Dotfiles repo"
  default      = "https://github.com/lkshrk/dotfiles.git"
  mutable      = true
}

locals {
  owner_slug   = trim(substr(trim(lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-")), "-"), 0, 18), "-")
  ws_slug      = trim(substr(trim(lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-")), "-"), 0, 18), "-")
  ws_hash      = substr(sha1("${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"), 0, 8)
  k8s_name     = "coder-${local.owner_slug != "" ? local.owner_slug : "user"}-${local.ws_slug != "" ? local.ws_slug : "workspace"}-${local.ws_hash}"
  pvc_name     = "${local.k8s_name}-home"
  access       = data.coder_parameter.access.value
  sa_name      = local.access == "base" ? "coder-workspace" : "coder-workspace-${local.access}"
  kube_ns      = local.access == "base" ? "coder" : local.access
  enable_dind  = tobool(data.coder_parameter.enable_dind.value)
  image        = "ghcr.io/lkshrk/devbox/${data.coder_parameter.variant.value}:${local.image_version}"
  repos_set    = data.coder_workspace.me.start_count > 0 ? toset([for r in split(",", data.coder_parameter.repos.value) : trimspace(r) if trimspace(r) != ""]) : toset([])
  repo_dirs    = join(",", [for r in local.repos_set : trimsuffix(basename(r), ".git")])
  deployment   = trimspace(data.coder_parameter.deployment_url.value)
  deployment_env = local.deployment != "" ? { DEPLOYMENT_URL = local.deployment, PLAYWRIGHT_LIVE_BASE_URL = local.deployment } : {}

  startup = <<-SCRIPT
    set -eu
    umask 077
    mkdir -p "$HOME/.kube"
    cat > "$HOME/.kube/h-cloud" <<'KUBECONFIG'
    apiVersion: v1
    kind: Config
    clusters:
      - name: h-cloud
        cluster:
          certificate-authority: /var/run/secrets/coder-workspace/ca.crt
          server: https://kubernetes.default.svc
    contexts:
      - name: h-cloud
        context:
          cluster: h-cloud
          namespace: ${local.kube_ns}
          user: ${local.sa_name}
    current-context: h-cloud
    users:
      - name: ${local.sa_name}
        user:
          tokenFile: /var/run/secrets/coder-workspace/token
    KUBECONFIG
    umask 022
    export DEVBOX_DOTFILES_URL="${data.coder_parameter.dotfiles_url.value}"
    devbox-init true
    bash "$HOME/dotfiles/setup-coder.sh"
  SCRIPT
}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = local.startup

  env = merge({
    GIT_AUTHOR_NAME         = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL        = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME      = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL     = data.coder_workspace_owner.me.email
    CODER_REPO_DIRS         = local.repo_dirs
    CODER_ENABLE_PLAYWRIGHT = data.coder_parameter.enable_playwright.value ? "1" : "0"
    KUBECONFIG              = "/home/dev/.kube/h-cloud"
    OMNI_OTEL_CA_PATH       = "/etc/ssl/lan/lan-ca.pem"
  }, local.deployment_env)

  metadata { display_name = "CPU";  key = "cpu";  script = "coder stat cpu";  interval = 10; timeout = 1 }
  metadata { display_name = "RAM";  key = "mem";  script = "coder stat mem";  interval = 10; timeout = 1 }
  metadata { display_name = "Disk"; key = "disk"; script = "coder stat disk --path /home/dev"; interval = 60; timeout = 1 }
}

module "git-commit-signing" {
  source   = "registry.coder.com/coder/git-commit-signing/coder"
  version  = "1.0.32"
  agent_id = coder_agent.main.id
}

module "git-clone" {
  for_each         = local.repos_set
  source           = "registry.coder.com/coder/git-clone/coder"
  version          = "2.0.3"
  agent_id         = coder_agent.main.id
  url              = each.value
  pre_clone_script = "mkdir -p $HOME/.ssh; chmod 700 $HOME/.ssh; ssh-keyscan -t ed25519,rsa github.com codeberg.org 2>/dev/null >> $HOME/.ssh/known_hosts; sort -u $HOME/.ssh/known_hosts -o $HOME/.ssh/known_hosts"
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata { name = local.pvc_name; namespace = "coder" }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources { requests = { storage = "${data.coder_parameter.disk_size.value}Gi" } }
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = local.k8s_name
    namespace = "coder"
    labels = merge(
      { "app.kubernetes.io/name" = "coder-workspace", "app.kubernetes.io/instance" = local.k8s_name, "app.kubernetes.io/managed-by" = "coder" },
      local.enable_dind ? { "coder.h-cloud.io/docker-dind" = "true" } : {},
    )
  }
  spec {
    service_account_name            = local.sa_name
    automount_service_account_token = false
    security_context { fs_group = 1000 }

    container {
      name              = "dev"
      image             = local.image
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", coder_agent.main.init_script]
      security_context { run_as_user = 1000 }

      env_from { secret_ref { name = "coder-workspace-secrets"; optional = true } }
      env_from { secret_ref { name = "${local.access}-workspace-env"; optional = true } }
      env { name = "CODER_AGENT_TOKEN"; value = coder_agent.main.token }
      env { name = "DEVBOX_DOTS"; value = "1" }

      dynamic "env" {
        for_each = ["GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"]
        content {
          name = env.value
          value_from { secret_key_ref { name = "coder-workspace-secrets"; key = "GH_TOKEN"; optional = true } }
        }
      }
      dynamic "env" {
        for_each = local.enable_dind ? { DOCKER_HOST = "tcp://localhost:2375", DOCKER_TLS_CERTDIR = "" } : {}
        content { name = env.key; value = env.value }
      }

      resources {
        requests = { cpu = "500m", memory = "${floor(tonumber(data.coder_parameter.memory.value) / 2)}Gi" }
        limits   = { cpu = data.coder_parameter.cpu.value, memory = "${data.coder_parameter.memory.value}Gi" }
      }

      volume_mount { mount_path = "/home/dev"; name = "home" }
      volume_mount { mount_path = "/etc/ssl/lan"; name = "lan-ca"; read_only = true }
      volume_mount { mount_path = "/var/run/secrets/coder-workspace"; name = "kube-api-access"; read_only = true }
    }

    dynamic "container" {
      for_each = local.enable_dind ? [1] : []
      content {
        name              = "dind"
        image             = "docker:27-dind"
        image_pull_policy = "IfNotPresent"
        security_context { privileged = true; run_as_user = 0 }
        env { name = "DOCKER_TLS_CERTDIR"; value = "" }
        resources {
          requests = { cpu = "250m", memory = "256Mi" }
          limits   = { cpu = "2", memory = "2Gi" }
        }
        volume_mount { mount_path = "/var/lib/docker"; name = "dind-storage" }
      }
    }

    volume { name = "home"; persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name } }
    volume { name = "lan-ca"; config_map { name = "lan-root-ca"; items { key = "lan-root-ca.crt"; path = "lan-ca.pem" } } }
    volume {
      name = "kube-api-access"
      projected {
        default_mode = "0444"
        sources { service_account_token { path = "token"; expiration_seconds = 3600 } }
        sources { config_map { name = "kube-root-ca.crt"; items { key = "ca.crt"; path = "ca.crt" } } }
      }
    }
    dynamic "volume" {
      for_each = local.enable_dind ? [1] : []
      content { name = "dind-storage"; empty_dir {} }
    }
  }
}
```

Differences from h-cloud `common.tf`, on purpose: no apt, no `omni tools sync`, no playwright `install-deps` (all in image); `CODER_OMNI_*` env gone; `access` is a parameter, not derived from template name; home is `/home/dev`; `coder-workspace-secrets` via `env_from` instead of per-key (GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, CODEX_AUTH_JSON, LITELLM_API all land as env); `CODEX_AUTH_JSON` becomes a file through `devbox-init`. `setup-coder.sh` still runs after `devbox-init` for lefthook activation, workspace notes and `CODER_ENABLE_PLAYWRIGHT` handling - verify in dotfiles that `setup-coder.sh` tolerates `OMNI_HOSTNAME=devbox` and a pre-populated toolchain (it calls `omni tools sync` via `setup-workspace.sh`; if so, guard it with `DEVBOX_VARIANT` set -> skip tools sync. That guard is a dotfiles change: add `[ -n "${DEVBOX_VARIANT:-}" ] && return 0` at the top of the tools-sync function in `setup-workspace.sh`, in the same dotfiles PR as Task 1).

`terraform fmt` will reflow the one-line blocks; run it before committing.

- [ ] **Step 2: `presets.tf`**

One preset per existing h-cloud template/preset (names verbatim so users recognise them):

```hcl
data "coder_workspace_preset" "routivo" {
  name        = "routivo"
  description = "Routivo monorepo"
  parameters  = { variant = "full", access = "routivo", repos = "git@github.com:routivo/routivo-monorepo.git", deployment_url = "https://routivo.h-cloud.io", enable_dind = "true", enable_playwright = "true", cpu = "6", memory = "32" }
}

data "coder_workspace_preset" "civora" {
  name        = "civora"
  description = "Civora monorepo"
  parameters  = { variant = "full", access = "civora", repos = "git@github.com:loc-news/civora-monorepo.git", deployment_url = "https://neustadt.civora.news", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "omni" {
  name       = "omni"
  parameters = { variant = "go", repos = "git@github.com:lkshrk/omni.git" }
}

data "coder_workspace_preset" "easy_web_gpg" {
  name       = "easy-web-gpg"
  parameters = { variant = "go", repos = "git@github.com:lkshrk/Easy-Web-GPG.git", deployment_url = "https://gpg.h-cloud.lan" }
}

data "coder_workspace_preset" "sonarr_season_reminder" {
  name       = "sonarr-season-reminder"
  parameters = { variant = "python", repos = "git@github.com:lkshrk/sonarr-season-reminder.git" }
}

data "coder_workspace_preset" "signal_cli_seerr_plugin" {
  name       = "signal-cli-seerr-plugin"
  parameters = { variant = "lua", repos = "git@github.com:lkshrk/signal-cli-seerr-plugin.git" }
}

data "coder_workspace_preset" "skeletoni" {
  name       = "skeletoni"
  parameters = { variant = "ts", repos = "git@github.com:lkshrk/skeletoni.git", enable_playwright = "true" }
}

data "coder_workspace_preset" "directus_reply_to_mail" {
  name       = "directus-extension-reply-to-mail"
  parameters = { variant = "ts", repos = "git@github.com:lkshrk/directus-extension-reply-to-mail.git" }
}

data "coder_workspace_preset" "rybbit_oidc" {
  name       = "rybbit-oidc"
  parameters = { variant = "ts", repos = "git@github.com:lkshrk/rybbit-oidc.git", enable_playwright = "true" }
}

data "coder_workspace_preset" "pfalz_herz" {
  name       = "pfalz-herz"
  parameters = { variant = "ts", access = "pub", repos = "git@github.com:webdev-harke/pfalz-herz.git", deployment_url = "https://pfalz-herz.pub.h-cloud.io", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "pizzeria_riva" {
  name       = "pizzeria-riva"
  parameters = { variant = "ts", access = "pub", repos = "git@github.com:webdev-harke/pizzeria-riva.git", deployment_url = "https://pizzeria-riva.pub.h-cloud.io", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "isc" {
  name       = "isc"
  parameters = { variant = "ts", access = "pub", repos = "git@github.com:webdev-harke/ISC.git", deployment_url = "https://isc.pub.h-cloud.io", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "quintessenz" {
  name       = "quintessenz"
  parameters = { variant = "ts", access = "pub", repos = "git@github.com:webdev-harke/quintessenz-horst.git", deployment_url = "https://quintessenz-horst.de", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "portfolio" {
  name       = "portfolio"
  parameters = { variant = "ts", access = "pub", repos = "git@github.com:webdev-harke/portfolio.git", deployment_url = "https://portfolio.harke.me", enable_dind = "true", enable_playwright = "true" }
}

data "coder_workspace_preset" "gitops" {
  name       = "gitops"
  parameters = { variant = "full", repos = "git@github.com:lkshrk/h-cloud.git" }
}
```

Cross-check each against its h-cloud `main.tf` before committing (`~/Dev/h-cloud/kubernetes/apps/coder/coder/templates/<name>/main.tf`); the sveltekit ones are listed above from that file, the others were read at plan time.

- [ ] **Step 3: Validate**

Run: `terraform -chdir=coder/devbox fmt && terraform -chdir=coder/devbox init -backend=false -input=false && terraform -chdir=coder/devbox validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Add push step to `coder-templates.yaml`**

Append to the `on.push.paths` and `on.pull_request.paths` lists: `- coder/devbox/**`. Add a final step to the `push-templates` job (after the existing "Push templates to Coder" step):

```yaml
      - name: Push devbox template
        if: github.event_name != 'pull_request'
        env:
          CODER_URL: https://coder.h-cloud.io
          CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
        run: |
          set -euo pipefail
          coder templates push devbox \
            --directory coder/devbox \
            --name "$(git rev-parse --short HEAD)" \
            --message "$(git log -1 --pretty=%s)" \
            --yes
```

The "Install Coder CLI" step is conditioned on `steps.changed.outputs.dirs != ''`; change that step's `if:` to `github.event_name != 'pull_request'` so the CLI is present for the devbox push even when no old template changed.

- [ ] **Step 5: Commit and push; create a workspace**

```bash
git add coder/devbox .github/workflows/coder-templates.yaml
git commit -m "feat(coder): devbox template with per-project presets"
git push
```

After CI pushes the template: in Coder UI create workspace from `devbox`, preset `omni`. Expected: pod starts with `ghcr.io/lkshrk/devbox/go:<calver>`, startup script completes, `~/dotfiles` present, `~/omni` cloned, `go version` works in the terminal, `claude --version` works. Repeat with preset `routivo` (full + dind + playwright).

If the workspace fails before the agent connects, `kubectl -n coder logs <pod>`; if the startup script fails, the Coder UI shows its log.

---

### Task 9: Docs

**Files:**
- Rewrite: `docs/architecture.md`
- Modify: `README.md` (add "devbox" section, leave the hermes-hq text)

- [ ] **Step 1: `docs/architecture.md`**

Write, in this order, each as a short section: image family table (from spec), stage order and why (change frequency), `HOME=/opt/devbox` build trick and the runtime PATH/shadowing rule, `devbox-init` contract (env vars, steps), launchers (Coder / k8s / local) with the exact commands, secrets contract table, image-size levers, known tool quirks found in Task 5 Step 5/7. Copy from the spec; do not link to the spec as the primary doc.

- [ ] **Step 2: README section**

Insert after the "Scope" section:

```markdown
## devbox (preview)

Reproducible dev images: `ghcr.io/lkshrk/devbox/{go,python,ts,lua,full,hermes,pilot}:<calver>`.
Tools are baked into `/opt/devbox`; dotfiles sync at every start.

- Coder: template `devbox`, pick a preset.
- Local: `scripts/devbox up NAME --image go`, then `scripts/devbox sh NAME`.
  Needs `~/.config/devbox/env` (copy `scripts/devbox.env.example`, chmod 600).
- k8s one-shot: `kubectl run x --image=ghcr.io/lkshrk/devbox/full:latest --rm -it -- devbox-init claude -p "..."`

Design: `docs/architecture.md`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md README.md
git commit -m "docs: devbox architecture and usage"
```

---

### Task 10: Phase-1 acceptance

- [ ] **Step 1: Checklist from the spec's "Done when"**

Run and record results in the PR description:

1. `gh run list --workflow validate.yaml --limit 1` - green, all 7 variants.
2. `gh run list --workflow release.yaml --limit 1` - green; `crane ls ghcr.io/lkshrk/devbox/go` shows the calver + `latest`.
3. GHCR packages `devbox/*` are public: `curl -s https://ghcr.io/token?scope=repository:lkshrk/devbox/go:pull | jq -r .token | xargs -I{} curl -s -H "Authorization: Bearer {}" https://ghcr.io/v2/lkshrk/devbox/go/tags/list` returns tags (not 401/denied). If private, set visibility public in GitHub package settings once.
4. Coder: one workspace per variant created from a preset, starts, `claude --version`, language toolchain works, `omni dots sync` applied (zsh prompt from dotfiles).
5. `scripts/devbox run --image full -- hermes --version` on macOS.
6. `docker run --rm ghcr.io/lkshrk/devbox/pilot:latest pilot version`.

- [ ] **Step 2: Merge**

Merge the PR. Merge the dotfiles PR first, then flip `DOTFILES_REF` to `main` in both workflows in a follow-up commit.

---

## Self-review

- Spec coverage: image family/stages (T5), `/opt/devbox` layout (T3, T5), `devbox-init` (T2), Coder template + presets + push (T8), agent variants (T1, T5), local launcher (T6), secrets contract (T2, T6, T8), size levers (T3 dpkg excludes, T5 cache mounts + zstd), CI (T7), docs (T9), phase-1 done-criteria (T10). Phase 2 intentionally absent.
- Placeholders: none; every file's content is in the plan. The only "inspect then decide" points are flagged as such (pilot archive layout, hermes launcher, `install-omni-latest.sh` target path, `setup-coder.sh` tools-sync guard).
- Name consistency: `devbox-init`, `DEVBOX_DOTS`, `DEVBOX_DOTFILES_URL`, `DEVBOX_VARIANT`, `/opt/devbox`, `OMNI_HOSTNAME=devbox`, bake targets, `tests/smoke/run.sh VARIANT`, `scripts/devbox` subcommands - identical across tasks.
