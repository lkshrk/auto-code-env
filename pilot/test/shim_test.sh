#!/usr/bin/env bash
# Guards the gh shim's two contracts: output stays parseable and PR identity is safe.
set -euo pipefail

BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/fake-gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create")
    echo "Creating pull request for feature/x into main in lkshrk/omni"
    echo ""
    echo "https://github.com/lkshrk/omni/pull/42"
    ;;
  "pr view") echo '{}' ;;
  "api user") echo "${LOGIN:-agent-npa}" ;;
  *) echo "fake-gh $*" ;;
esac
FAKE
chmod +x "$work/fake-gh"

export HOME="$work"
export REAL_GH="$work/fake-gh"
export GH_TOKEN=ghp_faketoken
mkdir -p "$work/.pilot"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expected=$(LOGIN=agent-npa "$work/fake-gh" pr create --title x)
actual=$(PILOT_GH_LOGIN=agent-npa LOGIN=agent-npa "$BIN/gh" pr create --title x 2>/dev/null)
[[ "$actual" == "$expected" ]] || fail "pr create stdout is not byte-identical to gh's"
grep -q 'https://github.com/lkshrk/omni/pull/42' <<<"$actual" || fail "PR URL missing from stdout"

passthrough=$("$BIN/gh" --version)
[[ "$passthrough" == "fake-gh --version" ]] || fail "non-pr-create invocation did not passthrough"

if (unset GH_TOKEN GITHUB_TOKEN; "$BIN/gh" --version >/dev/null 2>&1); then
  fail "shim ran unauthenticated instead of failing"
fi

if PILOT_GH_LOGIN=agent-npa LOGIN=lkshrk "$BIN/gh" pr create --title x >/dev/null 2>&1; then
  fail "shim opened a PR while authenticated as the wrong account"
fi

if PILOT_GH_LOGIN=agent-npa LOGIN=lkshrk "$BIN/gh" pr --repo lkshrk/omni create --title x >/dev/null 2>&1; then
  fail "shim bypassed identity guard when pr flags preceded create"
fi

PILOT_GH_LOGIN=agent-npa LOGIN=lkshrk "$BIN/gh" --version >/dev/null ||
  fail "identity guard wrongly blocked a non-pr-create invocation"

mkdir -p "$work/fake-bin"
cat >"$work/fake-bin/git" <<'FAKEGIT'
#!/usr/bin/env bash
dest="${@: -1}"
mkdir -p "$dest/.git"
FAKEGIT
cat >"$work/fake-pilot" <<'FAKEPILOT'
#!/usr/bin/env bash
exit 0
FAKEPILOT
chmod +x "$work/fake-bin/git" "$work/fake-pilot"
sed "s|exec /usr/local/bin/pilot|exec \"$work/fake-pilot\"|" \
  "$BIN/pilot-entrypoint" >"$work/pilot-entrypoint"
chmod +x "$work/pilot-entrypoint"

HOME="$work/entry-home" PATH="$work/fake-bin:$PATH" \
  PILOT_CLONE_REPOS='org-a/api,org-b/api' GITHUB_TOKEN=token \
  "$work/pilot-entrypoint" >/dev/null
[[ -d "$work/entry-home/repos/org-a/api/.git" ]] || fail "first owner checkout missing"
[[ -d "$work/entry-home/repos/org-b/api/.git" ]] || fail "same-name second owner checkout collided"

missing_db="$work/missing-pilot.db"
if LINEAR_API_KEY=fake PILOT_DB="$missing_db" "$BIN/pilot-retry" ROU-1 >/dev/null 2>&1; then
  fail "pilot-retry accepted a missing Pilot database"
fi
[[ ! -e "$missing_db" ]] || fail "pilot-retry created an empty database"

echo "shim_test: ok"
