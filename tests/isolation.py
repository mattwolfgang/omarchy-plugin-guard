"""Regression tests for how the agent CLIs are launched for a review: no
tools, none of the user's integrations, an empty working directory. Run by
tests/run.sh as: python3 -I isolation.py <bin/plugin-guard>.

Fake claude, codex and grok commands on PATH record the arguments, working
directory and environment they were started with, and answer with a fixed
review. Nothing is sent to a model. Each case prints "ok   name" or
"FAIL name"; the exit status is 1 if any failed.
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

GUARD = Path(sys.argv[1]).resolve()
loader = importlib.machinery.SourceFileLoader("plugin_guard", str(GUARD))
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)

failed = False
work = Path(tempfile.mkdtemp(prefix="plugin-guard-isolation-"))
bindir = work / "bin"
bindir.mkdir()
record = work / "launch.json"

REVIEW = {"verdict": "safe", "summary": "fake", "purposeMatch": "yes", "findings": [], "networkDestinations": []}

# One script plays all three CLIs; it tells them apart by its own name.
FAKE = f"""#!{sys.executable} -I
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
prompt = sys.stdin.read()
Path({str(record)!r}).write_text(json.dumps({{
  "name": name, "args": args, "cwd": os.getcwd(), "cwdFiles": sorted(os.listdir(".")),
  "env": dict(os.environ), "prompt": prompt}}))
review = {json.dumps(REVIEW)!r}
if name == "claude":
  print(json.dumps({{"is_error": False, "structured_output": json.loads(review)}}))
elif name == "codex":
  Path(args[args.index("-o") + 1]).write_text(review)
elif name == "grok":
  print(json.dumps({{"structuredOutput": json.loads(review)}}))
"""
for name in ("claude", "codex", "grok"):
  script = bindir / name
  script.write_text(FAKE)
  script.chmod(script.stat().st_mode | stat.S_IXUSR)
os.environ["PATH"] = f"{bindir}:{os.environ['PATH']}"
# A user's own settings for these must not leak through.
os.environ["GROK_CLAUDE_MCPS_ENABLED"] = "true"
os.environ["GROK_MEMORY"] = "1"


def case(name):
  def wrap(fn):
    global failed
    try:
      problem = fn()
    except Exception as e:  # a test that raises has failed
      problem = f"{type(e).__name__}: {e}"
    if problem:
      failed = True
      print(f"FAIL {name}\n  {problem}")
    else:
      print(f"ok   {name}")
    return fn
  return wrap


def launch(kind, model=""):
  record.unlink(missing_ok=True)
  reply = pg.review_batch({"id": kind, "kind": kind, "model": model}, "PROMPT", 30)
  if reply != REVIEW:
    raise AssertionError(f"reply {reply!r}")
  return json.loads(record.read_text())


def option(args, flag):
  """The value after the last occurrence of flag, or None."""
  values = [args[i + 1] for i, a in enumerate(args[:-1]) if a == flag]
  return values[-1] if values else None


def common(run, plugin_dir_files=()):
  """Problems every CLI must avoid: a working directory with anything in it
  but Plugin Guard's own files, or one inside the scanned plugin."""
  extra = set(run["cwdFiles"]) - set(plugin_dir_files)
  if extra:
    return f"working directory holds {sorted(extra)}"
  if not Path(run["cwd"]).name.startswith("plugin-guard-"):
    return f"working directory {run['cwd']}"
  return None


@case("claude runs with no tools, safe mode and no MCP servers")
def _():
  run = launch("claude", "opus")
  args = run["args"]
  if option(args, "--tools") != "":
    return f"--tools {option(args, '--tools')!r}"
  for flag in ("--safe-mode", "--strict-mcp-config", "--no-session-persistence"):
    if flag not in args:
      return f"missing {flag}"
  if "--mcp-config" in args:
    return "passes an MCP config"
  if option(args, "--model") != "opus":
    return "model not passed"
  return common(run) or (None if run["prompt"] == "PROMPT" else "prompt not on stdin")


@case("codex ignores the user's config, rules, MCP servers, hooks and plugins")
def _():
  run = launch("codex", "gpt-5")
  args = run["args"]
  for flag in ("--ignore-user-config", "--ignore-rules", "--ephemeral"):
    if flag not in args:
      return f"missing {flag}"
  if option(args, "--sandbox") != "read-only":
    return f"sandbox {option(args, '--sandbox')!r}"
  overrides = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-c"]
  wanted = ["mcp_servers={}", 'web_search="disabled"'] + [f"features.{f}=false" for f in (
    "hooks", "plugins", "remote_plugin", "apps", "browser_use", "browser_use_external", "computer_use",
    "in_app_browser", "image_generation", "multi_agent", "memories", "shell_tool")]
  missing = [w for w in wanted if w not in overrides]
  if missing:
    return f"missing overrides {missing}"
  if any(o.endswith("=true") for o in overrides):
    return "turns a feature on"
  for flag in ("--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--enable",
               "--profile", "-p", "--add-dir", "--oss"):
    if flag in args:
      return f"passes {flag}"
  if option(args, "-m") != "gpt-5" or args[-1] != "-":
    return "model or stdin prompt missing"
  return common(run, {"schema.json"})


@case("grok runs with no tools, MCP denied, and the user's integrations off")
def _():
  run = launch("grok", "grok-4")
  args, env = run["args"], run["env"]
  allowed = option(args, "--tools")
  if not allowed:
    return f"--tools {allowed!r} is no filter at all in Grok"
  removed = set((option(args, "--disallowed-tools") or "").split(","))
  left = set(allowed.split(",")) - removed
  if left:
    return f"tools still allowed: {sorted(left)}"
  if not {"search_tool", "use_tool", "Agent"} <= removed:
    return f"MCP or subagent tools not removed: {sorted(removed)}"
  if option(args, "--deny") != "MCPTool":
    return "MCP calls not denied"
  for flag in ("--no-subagents", "--disable-web-search"):
    if flag not in args:
      return f"missing {flag}"
  if option(args, "--permission-mode") != "plan":
    return f"permission mode {option(args, '--permission-mode')!r}"
  for flag in ("--always-approve", "--allow", "--add-dir", "--agent", "--agents", "--mcp-config"):
    if flag in args:
      return f"passes {flag}"
  wanted = {f"GROK_{v}_{k}_ENABLED": "false" for v in ("CLAUDE", "CURSOR")
            for k in ("MCPS", "HOOKS", "SKILLS", "RULES", "AGENTS")}
  wanted.update(GROK_MANAGED_MCPS_ENABLED="false", GROK_MEMORY="0", GROK_SUBAGENTS="0",
                GROK_WEB_FETCH="0", GROK_BACKEND_SEARCH="0")
  wrong = {k: env.get(k) for k, v in wanted.items() if env.get(k) != v}
  if wrong:
    return f"environment {wrong}"
  if option(args, "-m") != "grok-4":
    return "model not passed"
  prompt_file = Path(option(args, "--prompt-file"))
  if prompt_file.parent != Path(run["cwd"]):
    return f"prompt file {prompt_file} outside the working directory"
  return common(run, {"prompt.txt"})


sys.exit(1 if failed else 0)
