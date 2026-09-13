#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'Usage: validate-templates.sh PACKAGE_DIR [PACKAGE_DIR ...]\n' >&2
  exit 1
fi

command -v tofu >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for package in "$@"; do
  package=$(cd "$package" && pwd)
  [[ -f "$package/main.tf" && -f "$package/common.tf" && -f "$package/backend" ]]
  export TF_DATA_DIR
  TF_DATA_DIR=$(mktemp -d "$work/tofu.XXXXXX")
  tofu -chdir="$package" fmt -check -diff -recursive
  tofu -chdir="$package" init -backend=false -input=false
  tofu -chdir="$package" validate
done
