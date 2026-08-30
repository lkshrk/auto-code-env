#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE:?}" "${OCI_REPOSITORY:?}" "${VERSION:?}" "${RELEASE_TAG:?}" "${GITHUB_SHA:?}" "${TITLE:?}" "${NOTES_FILE:?}"

die() { printf '%s\n' "$*" >&2; exit 1; }

is_not_found() {
  [[ $1 =~ ^Error:.*(:\ not\ found|manifest\ unknown).*$ ]] || [[ $1 =~ ^release\ not\ found.*$ ]]
}

pull_and_compare() (
  local directory output package rc
  directory=$(mktemp -d)
  trap 'rm -rf -- "$directory"' EXIT
  if output=$(helm pull "$OCI_REPOSITORY" --version "$VERSION" --destination "$directory" 2>&1); then
    package=$(find "$directory" -maxdepth 1 -type f -name '*.tgz' -print -quit)
    test -n "$package" || die "OCI pull returned no chart package"
    cmp -s "$PACKAGE" "$package" || die "OCI chart $OCI_REPOSITORY:$VERSION differs from local package"
    return 0
  else
    rc=$?
  fi
  if is_not_found "$output"; then return 10; fi
  printf '%s\n' "$output" >&2
  return "$rc"
)

ensure_tag() {
  local remote
  if remote=$(git ls-remote --exit-code --tags origin "refs/tags/$RELEASE_TAG" 2>/dev/null); then
    test "${remote%%$'\t'*}" = "$GITHUB_SHA" || die "existing tag $RELEASE_TAG does not target $GITHUB_SHA"
  else
    git tag "$RELEASE_TAG" "$GITHUB_SHA"
    git push origin "refs/tags/$RELEASE_TAG"
  fi
}

release_state() {
  local output rc
  if output=$(gh release view "$RELEASE_TAG" --json isDraft,tagName 2>&1); then
    jq -e --arg tag "$RELEASE_TAG" '.tagName == $tag and (.isDraft | type == "boolean")' <<<"$output" >/dev/null || die "existing release $RELEASE_TAG is invalid"
    jq -r 'if .isDraft then "draft" else "published" end' <<<"$output"
    return
  else
    rc=$?
  fi
  if is_not_found "$output"; then
    gh release create "$RELEASE_TAG" --verify-tag --draft --title "$TITLE" --notes-file "$NOTES_FILE" >/dev/null
    printf 'draft\n'
    return
  fi
  printf '%s\n' "$output" >&2
  return "$rc"
}

if pull_and_compare; then
  chart_state=present
else
  rc=$?
  test "$rc" = 10 || exit "$rc"
  chart_state=absent
fi

ensure_tag
state=$(release_state)
if test "$chart_state" = absent; then
  if ! helm push "$PACKAGE" oci://ghcr.io/lkshrk/charts; then
    pull_and_compare || die "helm push failed and OCI chart is unavailable"
  fi
  pull_and_compare || die "OCI chart was not available after push"
fi

if test "$state" = draft; then gh release edit "$RELEASE_TAG" --draft=false; fi
