#!/usr/bin/env python3
"""Copies AGENTS.md into common.json's agent.system_message_suffix."""
import json
import pathlib

here = pathlib.Path(__file__).resolve().parent
common = here / "common.json"
profile = json.loads(common.read_text())
profile["agent"]["system_message_suffix"] = (here / "AGENTS.md").read_text().strip()
common.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n")
print("common.json updated from AGENTS.md")
