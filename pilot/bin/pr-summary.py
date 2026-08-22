"""Formats a `gh pr view --json …` blob (stdin) into the Telegram PR announcement."""

import json
import re
import sys

url = sys.argv[1] if len(sys.argv) > 1 else ""
d = json.load(sys.stdin)

title = d.get("title") or "(no title)"
body = d.get("body") or ""
files = d.get("files") or []

prose = ""
for block in re.split(r"\n\s*\n", re.sub(r"<!--.*?-->", "", body, flags=re.S)):
    line = block.strip()
    if not line or line.startswith(("#", "-", "*", "|", "```", ">")):
        continue
    if re.match(r"^\s*(fix(e[sd])?|close[sd]?|resolve[sd]?|implement(s|ed)?|complete[sd]?|"
                r"refs?|part of|contributes to|towards?)\s+[A-Z]{2,5}-\d+\s*$", line, re.I):
        continue
    prose = " ".join(line.split())
    break
if len(prose) > 320:
    prose = prose[:317].rstrip() + "…"

GENERIC = {"src", "app", "lib", "components", "routes", "internal", "pkg"}
areas = {}
for f in files:
    parts = [p for p in f.get("path", "").split("/")[:-1]]
    if not parts:
        continue
    meaningful = [p for p in parts[1:] if p not in GENERIC]
    key = f"{parts[0]}/{meaningful[0]}" if meaningful else parts[0]
    areas[key] = areas.get(key, 0) + 1
top = ", ".join(f"{k} ({v})" for k, v in sorted(areas.items(), key=lambda kv: -kv[1])[:3])
if len(areas) > 3:
    top += f", +{len(areas) - 3} more"

lines = ["🔀 PR ready for review", "", title]
lines.append(f"{d.get('changedFiles', len(files))} files  +{d.get('additions', 0)} −{d.get('deletions', 0)}")
if top:
    lines.append(top)
if prose:
    lines += ["", prose]
lines += ["", url]

print("\n".join(lines))
