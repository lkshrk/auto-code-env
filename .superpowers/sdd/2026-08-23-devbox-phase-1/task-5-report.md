# Task 5 report: Containerfile and bake file

**Status: BLOCKED** — the three Task 5 artifacts are written, committed, and statically
validated, but they cannot be built against the pinned dotfiles commit. Six independent
upstream defects block the build; five are outside Task 5's files. Each is diagnosed to a
specific line and, where I could, verified fixed in a throwaway probe.

## What I implemented

Adopted the previous session's partial work after diffing it against the brief — the
`Containerfile`, `docker-bake.hcl`, and `image/.dockerignore` matched the brief verbatim
(including the `ARG VARIANT=full` preflight ruling), so I kept them.

Commits:

- `a64eb22` feat(image): multi-stage Containerfile and bake matrix for devbox variants
  — `image/Containerfile`, `docker-bake.hcl`, `image/.dockerignore`
- `df5c345` fix(image): sync omni tool groups one at a time and accept a build-time GitHub token
  — `image/scripts/30-tools.sh`

Two deviations from the brief, both forced by defects found while building:

1. **`omni tools sync` takes one group, not many.** `omni tools sync --help` shows
   `omni tools sync [group]` (singular). The original `30-tools.sh` passed `"$@"`, which
   would have synced only the first group and silently skipped the rest. Now it loops.
   The previous session had already made this change; I verified the CLI signature and kept it.
2. **Build-time GitHub token.** Unauthenticated GitHub API is 60 requests/hour and many
   omni `script` providers do a release lookup each. A real build exhausts it partway
   through: `gitleaks (script): github release lookup failed: HTTP 403 ... X-RateLimit-Remaining=0`.
   I added `--mount=type=secret,id=github_token,uid=1000` to every `30-tools.sh` RUN,
   `secret = ["type=env,id=github_token,env=GITHUB_TOKEN"]` to `_common` in the bake file,
   and a guarded read in `30-tools.sh`. Verified that bake does **not** fail when
   `GITHUB_TOKEN` is unset — buildx mounts an empty file, hence the `-s` (non-empty) test
   rather than `-r`, so an empty token is never exported.

## What I tested and results

### Static validation (passing)

- `docker buildx bake --print` resolves all seven targets; `group.default` =
  `full, go, hermes, lua, pilot, python, ts`. Args merge as the brief predicted: each
  target carries `DOTFILES_REF`, `DOTFILES_COMMIT` from `_common` plus its own `VARIANT`.
  Tags render as `ghcr.io/lkshrk/devbox/<variant>:dev` and `:latest`.
- `docker buildx build --check` on the Containerfile: *"Check complete, no warnings found."*
- `stack-${VARIANT}` dynamic FROM resolves; `ARG VARIANT=full` before the first FROM is correct.

### Build attempts

Host: Docker Desktop 29.7.2, builder `desktop-linux`, arm64 Mac building `linux/amd64`
under emulation. Docker has 7.7 GiB / 10 CPU.

Build 1, real Containerfile against pinned commit `9c51997` — **failed at stage `omni`**:

```
#9 3.374 omni version v0.9.37 (fb2d8a9, 2026-08-24)
#9 3.525 error: parsing included config "settings.d/agents.json":
         config field "$.agents" was removed in v24
```

To get past that and validate the rest of my stage graph, I built a throwaway probe
Containerfile (scratchpad only, never committed) identical to the real one except that the
`omni` stage seeds dotfiles from a build context instead of cloning, letting me apply
candidate upstream fixes without touching the user's dotfiles repo. Under that probe the
`base`, `omni`, and `core` stages all completed and the build reached `ai`/`ai-plugins`
before hitting the memory ceiling.

### Size

**Not measured.** No variant image was ever produced, so `docker image ls` /
`docker history` had nothing to report. The brief's under-2 GB check is still open.

### Smoke

**Not run.** `tests/smoke/run.sh` needs an image. Two of its checks are already known to
fail from the group analysis below (`pnpm` for ts/full/hermes/pilot; `lua-language-server`
and `stylua` for lua/full/hermes/pilot).

## Blockers

All six reproduce independently of Task 5's files.

### B1 — dotfiles omni config is schema v22; omni v0.9.37 requires v24 (blocks every variant)

`install-omni-latest.sh` fetches the latest release, currently **v0.9.37**, which rejects
v22 configs. The pinned commit `9c51997` on `feat/omni-devbox-host` carries
`settings.json` at `"version": 22` with an `agents` block.

The user's **local dotfiles working tree already contains this migration, uncommitted**
(`~/Dev/dotfiles`, 5 files, ~328 deletions). It is not on any pushed branch, so the build
cannot see it. I did not commit or push the user's in-flight work.

I reproduced the exact minimal migration in the probe and confirmed the config then loads
(`CONFIG OK`). It needs all three of:

- `settings.json`: `$schema` and `version` → 24
- `settings.d/agents.json` → `{}` (agent packages/MCP servers move to `~/.apm/apm.yml`)
- `settings.d/groups.json`: strip `skills`(4), `mcp_servers`(4), `plugins`(13),
  `marketplaces`(10) from the `ai-plugins` group — v24 rejects these too, with the same
  error shape

**Capability consequence worth a decision:** under v24 the `ai-plugins` group becomes
tools-only. The 13 Claude plugins, 4 skills, 4 MCP servers, and 10 marketplaces that
`ai-plugins` used to install move to APM, which the devbox image does not currently
provision. Unless something installs `~/.apm/apm.yml`, the built image loses all of them.

Once fixed, `DOTFILES_COMMIT` must be re-pinned to the new head.

### B2 — `lua` group has no Linux provider (blocks lua, full, hermes, pilot)

All five lua tools resolve only to `brew`, which is a disabled provider for the devbox host:

```
! provider unavailable: brew (skipping busted)
! provider unavailable: brew (skipping lua-language-server)
! provider unavailable: brew (skipping luacheck)
! provider unavailable: brew (skipping luarocks)
! provider unavailable: brew (skipping stylua)
error: 5 tools unavailable
```

Needs Linux providers in dotfiles `tools.json`, or the `lua` group dropped from the devbox
host and the `lua` variant from the bake matrix. The smoke test checks
`lua-language-server` and `stylua`, so both must be resolvable.

### B3 — `pnpm` is globally ignored, but smoke requires it (affects ts, full, hermes, pilot)

`settings.json` has `ignore.tools: [..., "npm", "pnpm"]`. The `ts` group dry-run installs
only `pm2`. `tests/smoke/run.sh:31` checks `pnpm --version` for those four variants, so it
will fail. Either un-ignore `pnpm` for the devbox host, provision it via corepack in
`50-finalize.sh` (which already symlinks `corepack`), or drop the check.

### B4 — `docker` apt_repo definition poisons apt for the whole stage (blocks every variant) — **fix verified**

dotfiles `tools.json` gives `docker` a `sources_format` in deb822 syntax, but omni writes
it to `/etc/apt/sources.list.d/omni-docker.list` — a `.list` file requires one-line format
(`gh`, right next to it, correctly uses one-line). The unparseable file breaks *all*
subsequent apt operations in the stage, so `skopeo`, `yamllint`, and `git-delta` failed too
with an error that has nothing to do with them:

```
E: Type 'Types:' is not known on line 1 in source list /etc/apt/sources.list.d/omni-docker.list
E: The list of sources could not be read.
```

It also points at Docker's **Ubuntu** repo with a Debian suite
(`https://download.docker.com/linux/ubuntu` + `Suites: trixie`), so it would 404 even in
the right format.

Fix (verified working in the probe — `docker (apt_repo) 5:29.7.2-1~debian.13~trixie`,
`gh 2.98.0`, and `apt-get update` clean afterwards): change docker's `sources_format` to

```
deb [arch={arch} signed-by={signed_by}] https://download.docker.com/linux/debian {suite} stable
```

### B5 — GitHub API rate limit exhausts mid-build

Addressed in this task; see the build-secret work above. Callers must export
`GITHUB_TOKEN` (or CI must provide one) or builds will keep hitting HTTP 403 partway
through. Left unset, the build still runs — it just re-exposes the 60/hour ceiling.

### B6 — `ai-plugins` needs a C toolchain, which the image deliberately does not have

`deepwiki-rs` and `herdr-tether` are Rust tools built from source by cargo and fail with
`error: linker 'cc' not found`. **This is an architecture fork, not a bug, so I did not
decide it.**

I initially added `gcc libc6-dev make` to `10-base.sh` and confirmed it fixes
`herdr-tether`. Then I read the Containerfile I had replaced and found this decision was
already made, deliberately, in the opposite direction:

> Off by default: no tool in the hermes Omni host group needs a compiler — the only
> cargo-provider tool in dotfiles (deepwiki-rs) and the only cmake consumer (topaz host)
> both live outside that group. Verified: dropping build-essential and friends took /usr
> from 435MB to 200MB with zero install failures.

That reasoning was written for the hermes host group, which excludes `ai-plugins`. The
devbox host group **includes** `ai-plugins`, so the premise no longer holds. The two
options are genuinely different:

- **(a)** Add a C toolchain to `10-base.sh`. Costs roughly 235 MB on `/usr` in *every*
  variant, by the old comment's own measurement, against a 2 GB budget that is still
  unverified.
- **(b)** Remove `deepwiki-rs` and `herdr-tether` from the devbox path, or give them
  binary providers. Keeps the image lean and honours the prior decision; loses two tools.

**I reverted my `10-base.sh` change** so the tree does not silently contradict a documented
decision. My recommendation is (b), consistent with the existing rationale, with (a) only
if those two tools are considered essential to devbox.

### B7 (environment, not code) — local emulated builds cannot finish the cargo compiles

With the toolchain present, `deepwiki-rs` ran for ~7 minutes and was then killed:
`script deepwiki-rs install: signal: killed`. That is an OOM kill — cargo compiling a large
Rust crate under amd64 emulation on a 7.7 GiB / 10 CPU Docker VM.

These images are meant to be built for `linux/amd64` and pushed to ghcr.io. **They should be
built on a native amd64 runner**, not emulated on an arm64 Mac. Even setting the six
defects aside, I do not think this host can complete a `full`/`hermes`/`pilot` build.

Related: a single `docker buildx bake` of these variants exceeds the 10-minute foreground
cap available to me. Re-running resumes from BuildKit cache and makes progress each time,
but the full matrix needs an orchestrator-run long build or CI.

## Self-review findings

- Both committed diffs are minimal and comment-free per the repo's comment rules.
- `-s` rather than `-r` on the secret file is deliberate: buildx mounts an empty file when
  `GITHUB_TOKEN` is unset, and exporting an empty `GITHUB_TOKEN` would make omni send an
  empty bearer token and get 401s — worse than sending none. Verified both paths.
- The secret never lands in a layer: it is a `--mount=type=secret`, not a build arg or ENV.
  `tests/smoke/run.sh:47` independently greps the image for token-like strings.
- `40-browser.sh` intentionally gets no secret mount — it drives `bunx playwright`, which
  pulls from the Playwright CDN, not the GitHub API.
- The Containerfile rewrite deleted a long comment header from the old hermes-hq image
  carrying two facts worth preserving in `docs/architecture.md` (Task 10): the
  build-essential size measurement quoted above, and the note that `rbw` is not in trixie's
  apt repos and installs from the upstream signed `.deb`.
- **Untested by me:** every stage from `ai` onward, `40-browser.sh`, `50-finalize.sh`, the
  runtime stage, the entrypoint, and the whole smoke test. The `ARG VARIANT` / dynamic
  `FROM` mechanism is validated only by `--check` and `--print`, not by a completed build.

## Tools that only work with `HOME=/opt/devbox`

The brief asked me to flag these. **I could not determine this** — it requires a built image
and a passing smoke run, specifically the `hermes (foreign HOME)` and `pilot (foreign HOME)`
checks. Still open.

One adjacent finding: omni writes a backup and a `.omni-config.lock` **into the config
directory**, so `/opt/devbox/dotfiles` must be writable by `dev` during build. It is, in the
real Containerfile (the clone is user-owned), but a read-only config tree fails with
`open ...omni-config.lock: read-only file system`. Worth knowing before anyone tries to
harden that path.

## Recommended order to unblock

1. Land B1 (v24 migration) and B4 (docker `sources_format`) on `feat/omni-devbox-host`,
   push, re-pin `DOTFILES_COMMIT`. Both fixes are verified.
2. Decide B6 (toolchain vs. dropping the two cargo tools) and B2/B3 (lua providers, pnpm).
3. Decide whether the v24 APM split needs `~/.apm/apm.yml` provisioning in the image, or
   devbox accepts losing the plugins/skills/MCP servers.
4. Re-run the matrix on a native amd64 runner with `GITHUB_TOKEN` set, then smoke and
   measure sizes.

## Resume — 2026-08-29

The user confirmed that the current Omni release migrates the configuration automatically;
the manual v24 migration blocker is superseded. Applied the remaining rulings without adding
a compiler: `ai-plugins` no longer selects `deepwiki-rs` or `herdr-tether`; Lua now has Linux
providers (`lua-busted`, `lua-check`, `luarocks`, plus verified GitHub-release assets for LuaLS
and StyLua); Docker uses the Debian one-line apt source. `setup-workspace.sh` already contained
the required `DEVBOX_VARIANT` tools-sync guards from `9c51997`.

`50-finalize.sh` enables and globally installs pnpm with Corepack under `/opt/devbox/.corepack`.
The devbox build moved to `image/Containerfile.devbox`, bake selects that file, and
`image/Containerfile` was restored byte-for-byte from `b878408` (the original Hermes control-hub
image).

Commits: dotfiles `9c51997..6bba4e4` (`6bba4e4 fix(omni): support devbox Lua tools`); devbox
`f4742da..b45f48a` (`b45f48a fix(image): keep devbox build separate from hermes image`). The
build was pinned to dotfiles commit `6bba4e4def7b2dc32ac4ddd8024cc8e0265880ae` via a local
read-only git daemon; no remote mutation occurred.

Validation passed: `bash tests/omni-devbox-profile.sh`, `omni-static-tool-providers.sh`,
`omni-script-provider-contract.sh`, `workspace-setup-profiles.sh`, JSON parsing, `bash -n
image/scripts/50-finalize.sh`, `git diff --check`, `docker buildx bake --check`, and bake-print
verification of `Containerfile.devbox`. `omni ... tools sync lua --dry-run` on macOS correctly
selected the two Linux release providers and reported apt unavailable on the macOS host.

All seven targets (`go python ts lua full hermes pilot`) were invoked as a local amd64 bake with
the pinned dotfiles commit. They reached the shared `core` sync and successfully installed bun,
nvm, uv, bat, coreutils, eza, fd, just, neovim, ripgrep, thefuck, tmux, tree, tree-sitter-cli,
yq, glow, and markdownlint-cli before this environment terminated the build at roughly 51
seconds, without a Docker/build failure. No completed runtime image exists, so the seven smoke
tests and image-size measurements are blocked rather than falsely run against the 502-byte
`--check` metadata artifacts (those local artifacts were removed).

Remaining concerns: run the full seven-target bake, smoke matrix, and size measurement on a
native amd64 runner with `GITHUB_TOKEN`; this local runner's command lifetime prevents reaching
the Lua, pnpm, runtime, foreign-HOME, or final image stages. Removing the two cargo tools from
the shared `ai-plugins` group also omits them from other hosts that select that group, although
their tool definitions remain available for explicit installation.

## Fix round 1 — 2026-08-29

Review correction: `DOTFILES_COMMIT` now defaults to the exact final supporting dotfiles
commit `80e4e773eece899ae854445230688a42aca76d4b`. `tests/docker-bake.sh` runs
`docker buildx bake --file "$repo_dir/docker-bake.hcl" --print go` and asserts both that pin
and `Containerfile.devbox`.

The shared `ai-plugins` group again contains `deepwiki-rs` and `herdr-tether`. A new
`devbox-ai-plugins` group keeps its complete agent metadata but omits only those two cargo
tools; the devbox host and its Containerfile stage use that group. This preserves coder and
topaz behavior while excluding both tools from the effective devbox profile.

Commands passed: `jq -e .` for settings and groups, `bash tests/omni-devbox-profile.sh`,
`bash tests/omni-static-tool-providers.sh`, `bash tests/docker-bake.sh`, `bash -n` on the
amended image scripts, bake-print pin assertion, and `git diff --check`.

Files: dotfiles `settings.json`, `settings.d/groups.json`, and
`tests/omni-devbox-profile.sh`; devbox `docker-bake.hcl`, `image/Containerfile.devbox`,
`tests/docker-bake.sh`, and this report. Commits: dotfiles `6bba4e4..80e4e77`; devbox
`021e012..f2c46ec`.
