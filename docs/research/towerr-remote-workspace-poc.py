import os, sys, time
from pydantic import SecretStr
from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.sdk.workspace import RemoteWorkspace
import openhands.tools.terminal, openhands.tools.file_editor  # registers tool kinds for event deserialization

llm = LLM(model=os.environ["LLM_MODEL"], base_url=os.environ["LLM_BASE_URL"], api_key=SecretStr(os.environ["LLM_API_KEY"]), usage_id="towerr-poc")
agent = Agent(llm=llm, tools=[Tool(name="terminal"), Tool(name="file_editor")])
ws = RemoteWorkspace(host=os.environ["WORKER_HOST"], api_key=os.environ["WORKER_API_KEY"], working_dir="/home/agent/workspaces/poc")
pre = ws.execute_command("mkdir -p /home/agent/workspaces/poc && hostname && id -un && cat /proc/1/comm")
print("PRE-CHECK exit", pre.exit_code, "stdout:", pre.stdout.strip().replace("\n", " | "))
conv = Conversation(agent=agent, workspace=ws)
conv.send_message("Run `hostname; id -un; pwd; date -u +%FT%TZ` and write the exact output to a file named poc.txt in the current working directory. Then reply with only the file contents.")
t = time.time(); conv.run(); print("RUN seconds", round(time.time() - t, 1))
post = ws.execute_command("cat /home/agent/workspaces/poc/poc.txt; stat -c '%U:%G %a %n' /home/agent/workspaces/poc/poc.txt")
print("POST-CHECK exit", post.exit_code, "stdout:", post.stdout.strip().replace("\n", " | "))
conv.close()
