#!/usr/bin/env bash
# Exercises pilot-entrypoint with a fake git and a fake pilot binary.
set -euo pipefail

BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

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
for path in tmp repos .pilot/data .cache .local/share; do
  [[ -d "$work/entry-home/$path" ]] || fail "writable-home path missing: $path"
done

echo "entrypoint_test: ok"
