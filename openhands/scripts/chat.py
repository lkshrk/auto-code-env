#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["openhands-sdk~=1.44.0", "openhands-tools~=1.44.0"]
# ///
"""Chat with a remote OpenHands agent-server from the terminal.

    OH_API_KEY=... uv run openhands/scripts/chat.py [--dir DIR] [--resume ID] [-t TASK]

OH_URL defaults to http://localhost:8000 (kubectl port-forward svc/openhands 8000).
"""

import argparse
import json
import os
import sys
import urllib.request

os.environ.setdefault("LOG_LEVEL", "WARNING")
os.environ.setdefault("OPENHANDS_SUPPRESS_BANNER", "1")

from pydantic import SecretStr

from openhands.sdk import LLM, Conversation
from openhands.sdk.event import ActionEvent, MessageEvent, ObservationEvent
from openhands.sdk.event.streaming_delta import StreamingDeltaEvent
from openhands.sdk.workspace import RemoteWorkspace
from openhands.tools.preset.default import get_default_agent

DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"


def server_llm(url, key):
    req = urllib.request.Request(
        url + "/api/settings",
        headers={"X-Session-API-Key": key, "X-Expose-Secrets": "plaintext"},
    )
    with urllib.request.urlopen(req) as r:
        llm = json.load(r)["agent_settings"]["llm"]
    return LLM(
        model=llm["model"],
        base_url=llm.get("base_url"),
        api_key=SecretStr(llm["api_key"]),
        usage_id="cli",
        stream=True,
    )


class Printer:
    def __init__(self):
        self.mode = None
        self.streamed = False

    def _switch(self, mode, label):
        if self.mode != mode:
            if self.mode:
                sys.stdout.write(RESET + "\n")
            sys.stdout.write(label)
            self.mode = mode

    def _end(self):
        if self.mode:
            sys.stdout.write(RESET + "\n")
            self.mode = None

    def __call__(self, event):
        if isinstance(event, StreamingDeltaEvent):
            if event.reasoning_content:
                self._switch("think", DIM)
                sys.stdout.write(event.reasoning_content)
            if event.content:
                self._switch("text", "")
                sys.stdout.write(event.content)
                self.streamed = True
            sys.stdout.flush()
        elif isinstance(event, ActionEvent):
            self._end()
            args = event.action.model_dump_json(exclude_none=True) if event.action else ""
            print(f"{BOLD}▶ {event.tool_name}{RESET} {args[:300]}")
        elif isinstance(event, ObservationEvent):
            self._end()
            text = "\n".join(
                c.text for c in event.observation.to_llm_content if hasattr(c, "text")
            )
            lines = text.splitlines()
            print(DIM + "\n".join(lines[:15]) + (f"\n… {len(lines) - 15} more lines" if len(lines) > 15 else "") + RESET)
        elif isinstance(event, MessageEvent) and event.source == "agent":
            self._end()
            if not self.streamed:
                print("\n".join(c.text for c in event.llm_message.content if hasattr(c, "text")))
            self.streamed = False
        elif type(event).__name__.endswith("ErrorEvent"):
            self._end()
            print(f"{BOLD}! {type(event).__name__}{RESET} {getattr(event, 'error', getattr(event, 'detail', ''))}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dir", default="/home/openhands/workspace/cli", help="working dir on the server")
    p.add_argument("--resume", help="conversation id to attach to")
    p.add_argument("-t", "--task", help="send one message, wait, exit")
    a = p.parse_args()

    url = os.environ.get("OH_URL", "http://localhost:8000").rstrip("/")
    key = os.environ.get("OH_API_KEY") or sys.exit("OH_API_KEY not set")

    printer = Printer()
    conv = Conversation(
        agent=get_default_agent(llm=server_llm(url, key), cli_mode=True),
        workspace=RemoteWorkspace(host=url, api_key=key, working_dir=a.dir),
        conversation_id=a.resume,
        callbacks=[printer],
        visualizer=None,
    )
    print(f"{DIM}conversation {conv.id}  dir {a.dir}  (Ctrl-C pauses, /quit exits){RESET}")

    def turn(text):
        conv.send_message(text)
        try:
            conv.run()
        except KeyboardInterrupt:
            conv.pause()
            printer._end()
            print(f"{DIM}paused{RESET}")

    if a.task:
        turn(a.task)
        return
    while True:
        try:
            text = input(f"\n{BOLD}you>{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if text in ("/quit", "/exit"):
            break
        if text == "/id":
            print(conv.id)
            continue
        if text:
            turn(text)
    conv.close()


if __name__ == "__main__":
    main()
