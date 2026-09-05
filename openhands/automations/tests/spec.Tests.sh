#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
automations="$repo_root/openhands/automations"
apply="$automations/common/apply.py"
workflow="$repo_root/.github/workflows/openhands-automations-validate.yaml"
max_timeout=7200

test -f "$apply"
grep -F 'openhands/automations/tests/spec.Tests.sh' "$workflow" >/dev/null
python3 -m py_compile "$apply"

fail=0
check() {
  if "$@"; then return; fi
  echo "FAIL ${spec#"$automations"/}: $*" >&2
  fail=1
}

while IFS= read -r spec; do
  spec=$(dirname "$spec")
  check test -f "$spec/prompt.md"
  check test -f "$spec/README.md"
  check test ! -e "$spec/apply.py"
  check grep -F 'common/apply.py' "$spec/README.md" >/dev/null

  for file in "$spec"/automation*.json; do
    check python3 - "$file" "$spec/prompt.md" "$max_timeout" <<'EOF'
import json, re, sys
from zoneinfo import ZoneInfo

spec_file, prompt_file, max_timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
spec = json.load(open(spec_file))
prompt = open(prompt_file).read()
errors = []

def expect(cond, msg):
    if not cond:
        errors.append(msg)

for key in ("name", "model", "timeout", "keep_alive", "enabled", "trigger"):
    expect(key in spec, f"missing {key}")
expect(re.fullmatch(r"[a-z0-9-]+", str(spec.get("name", ""))), "name must be kebab-case")
expect(isinstance(spec.get("model"), str) and spec["model"], "model must be a non-empty string")
expect(isinstance(spec.get("timeout"), int) and 0 < spec["timeout"] <= max_timeout, f"timeout must be in 1..{max_timeout}")
expect(isinstance(spec.get("keep_alive"), bool), "keep_alive must be bool")
expect(isinstance(spec.get("enabled"), bool), "enabled must be bool")
expect("prompt" not in spec, "prompt belongs in prompt.md")

trigger = spec.get("trigger") or {}
if trigger.get("type") == "cron":
    expect(len(str(trigger.get("schedule", "")).split()) == 5, "cron schedule needs 5 fields")
    try:
        ZoneInfo(trigger.get("timezone", "UTC"))
    except Exception:
        errors.append(f"unknown timezone {trigger.get('timezone')}")
elif trigger.get("type") == "event":
    expect(bool(trigger.get("source")), "event trigger needs source")
    expect(bool(trigger.get("on")), "event trigger needs on")
else:
    errors.append(f"trigger.type must be cron or event, got {trigger.get('type')}")

variables = spec.get("vars", {})
expect(isinstance(variables, dict), "vars must be an object")
rendered = prompt
for name, value in variables.items():
    expect(re.fullmatch(r"[A-Z][A-Z0-9_]*", name), f"var {name} must be UPPER_SNAKE")
    expect(name in prompt, f"var {name} is never used in prompt.md")
    rendered = rendered.replace(name, str(value))
expect("REPLACE_ME" not in rendered, "rendered prompt still contains REPLACE_ME")

for error in errors:
    print(f"{spec_file}: {error}", file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
    check python3 "$apply" "$spec" --file "$(basename "$file")" --dry-run >/dev/null
  done
done < <(find "$automations" -mindepth 3 -maxdepth 3 -name automation.json | sort)

exit "$fail"
