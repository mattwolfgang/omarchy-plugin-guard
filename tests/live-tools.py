"""Check the tools each signed-in agent CLI really offers the model when
Plugin Guard starts it for a review. tests/isolation.py checks the command
line Plugin Guard builds; this asks the real CLI what that command line gives
the model, so it catches a CLI version that ignores or changes an option.

Not run by tests/run.sh: it needs each CLI installed and signed in, and it
sends one short prompt (no plugin code) to each provider. Run it by hand:

  python3 -I tests/live-tools.py bin/plugin-guard [claude] [codex] [grok]

With no names it checks every one of the three that is installed. Each CLI
is started exactly as a review starts it, except for what is needed to see
its tool list:
  claude  --output-format stream-json --verbose; reads the init event
  grok    --output-format streaming-messages-json; reads the init event
  codex   RUST_LOG=trace; reads the tools echoed in its response.created event
A CLI passes when it lists no tools and no MCP servers. The one exception is
Claude Code's StructuredOutput: --json-schema makes the reply a call to it, so
it is how the review comes back, not something the model can act with. Exit
status 1 if any failed.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(sys.argv[1]).resolve()
loader = importlib.machinery.SourceFileLoader("plugin_guard", str(GUARD))
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)

PROMPT = "Reply with a review of an empty plugin: verdict safe, no findings."
TIMEOUT = 300
# The reply channel each CLI adds for a structured answer.
REPLY_TOOLS = {"claude": {"StructuredOutput"}}


def replace_option(cmd, flag, values):
  i = cmd.index(flag)
  return cmd[:i] + values + cmd[i + 2:]


def run(cmd, env, cwd, stdin=PROMPT):
  return subprocess.run(cmd, input=stdin, capture_output=True, text=True, cwd=cwd,
                        env=dict(os.environ, NO_COLOR="1", **env), timeout=TIMEOUT)


def init_event(stdout):
  for line in stdout.splitlines():
    try:
      event = json.loads(line)
    except ValueError:
      continue
    if event.get("type") == "system" and event.get("subtype") == "init":
      return event
  return None


def check_claude(cwd):
  cmd, env = pg.claude_command({"model": ""})
  cmd = replace_option(cmd, "--output-format", ["--output-format", "stream-json", "--verbose"])
  r = run(cmd, env, cwd)
  init = init_event(r.stdout)
  if init is None:
    return None, f"no init event (exit {r.returncode}): {r.stderr[-300:]}"
  return {"tools": init.get("tools"), "mcp_servers": init.get("mcp_servers")}, None


def check_grok(cwd):
  prompt_file = Path(cwd) / "prompt.txt"
  prompt_file.write_text(PROMPT)
  cmd, env = pg.grok_command({"model": ""}, prompt_file)
  cmd = replace_option(cmd, "--output-format", ["--output-format", "streaming-messages-json"])
  r = run(cmd, env, cwd, stdin="")
  init = init_event(r.stdout)
  if init is None:
    return None, f"no init event (exit {r.returncode}): {r.stderr[-300:]}"
  if r.returncode != 0:
    return None, f"exit {r.returncode}: {r.stdout[-300:]}"
  return {"tools": init.get("tools"), "mcp_servers": init.get("mcp_servers")}, None


def codex_tool_names(tools):
  names = []
  for t in tools:
    name = t.get("name") or t.get("type")
    if t.get("tools"):
      names += [f"{name}.{n}" for n in codex_tool_names(t["tools"])]
    else:
      names.append(name)
    if name == "exec":  # code mode: nested tools are listed in its description
      names += [f"exec>{n}" for n in re.findall(r"^### `([^`]+)`", t.get("description", ""), re.M)]
  return names


def check_codex(cwd):
  schema_file = Path(cwd) / "schema.json"
  schema_file.write_text(json.dumps(pg.REVIEW_SCHEMA))
  catalog = pg.codex_catalog(cwd, TIMEOUT)
  cmd, env = pg.codex_command({"model": ""}, schema_file, Path(cwd) / "reply.json", catalog)
  r = run(cmd, dict(env, RUST_LOG="trace"), cwd)
  if r.returncode != 0:
    return None, f"exit {r.returncode}: {r.stderr[-300:]}"
  seen = None
  for line in r.stderr.splitlines():
    i = line.find('{"type":"response.created"')
    if i < 0:
      continue
    try:
      tools = json.loads(line[i:])["response"]["tools"]
    except (ValueError, KeyError, TypeError):
      continue
    seen = (seen or []) + codex_tool_names(tools)
  if seen is None:
    return None, "no response.created event in the trace log"
  return {"tools": seen, "mcp_servers": []}, None


CHECKS = {"claude": check_claude, "codex": check_codex, "grok": check_grok}

names = sys.argv[2:] or [n for n in CHECKS if shutil.which(n)]
failed = False
for name in names:
  with tempfile.TemporaryDirectory(prefix="plugin-guard-") as cwd:
    try:
      surface, problem = CHECKS[name](cwd)
    except Exception as e:  # a check that raises has failed
      surface, problem = None, f"{type(e).__name__}: {e}"
  if problem is None:
    tools = [t for t in surface["tools"] or [] if t not in REPLY_TOOLS.get(name, set())]
    if tools or surface["mcp_servers"]:
      problem = f"tools {tools}, MCP servers {surface['mcp_servers']}"
  if problem:
    failed = True
    print(f"FAIL {name}\n  {problem}")
  else:
    print(f"ok   {name}: no tools, no MCP servers")
sys.exit(1 if failed else 0)
