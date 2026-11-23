"""Regression tests for local model servers (plugin-guard endpoints): address
checks, reading a server's model list, and discovery on this computer and on
Tailscale devices. Run by tests/run.sh as: python3 -I endpoints.py
<bin/plugin-guard>. The model server is a fake on 127.0.0.1, and Tailscale is
a stub script; discovery's network calls are replaced, so nothing else is
contacted.
"""
import atexit
import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

GUARD = Path(sys.argv[1]).resolve()
loader = importlib.machinery.SourceFileLoader("plugin_guard", str(GUARD))
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)

failed = False
work = Path(tempfile.mkdtemp(prefix="plugin-guard-endpoints-"))
atexit.register(shutil.rmtree, work, True)


def check(name, ok, detail=""):
  global failed
  print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
  failed |= not ok


# --- Addresses --------------------------------------------------------------

good = {
  "http://127.0.0.1:8080": "http://127.0.0.1:8080",
  "http://ai-desktop:8080/": "http://ai-desktop:8080",
  " https://models.example.ts.net ": "https://models.example.ts.net",
  "http://[fd7a::1]:11434": "http://[fd7a::1]:11434",
}
for value, want in good.items():
  try:
    got = pg.normalize_endpoint(value)
  except pg.GuardError as e:
    got = f"error: {e}"
  check(f"address accepted: {value!r}", got == want, got)

bad = ["", "http://[:::]:80", "http://[zz::1]:80", "ftp://host:21", "http://host:8080/v1", "http://user@host:8080", "http://host:0", "http://host:65536",
       "http://host:8080?x=1", "http://host:8080\nx", "http://ho\nst:8080", "http://-host:80", "http://host_name:80", "host:8080",
       "http://" + "a" * 200 + ":80", "file:///etc/passwd"]
for value in bad:
  try:
    pg.normalize_endpoint(value)
    check(f"address refused: {value!r}", False, "accepted")
  except pg.GuardError:
    check(f"address refused: {value!r}", True)


# --- Reading a server's models ----------------------------------------------

replies = {}


class FakeServer(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    status, body = replies.get(self.path, (404, b"{}"))
    self.send_response(status)
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def log_message(self, *_):
    pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeServer)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def serve(body, status=200):
  replies["/v1/models"] = (status, body if isinstance(body, bytes) else json.dumps(body).encode())


serve({"data": [{"id": "qwen", "status": {"value": "loaded", "args": ["--ctx-size", "65536"]}}, {"id": ""}, "x"]})
models = pg.server_models(BASE)
check("server models read", models is not None and [m["model"] for m in models] == ["qwen"]
      and models[0]["contextTokens"] == 65536 and models[0]["endpoint"] == BASE, models)
serve({"data": [{"id": f"m{i}"} for i in range(pg.MAX_MODELS + 20)]})
check("server models capped", len(pg.server_models(BASE)) == pg.MAX_MODELS)
for name, body, status in [("not JSON", b"<html>", 200), ("no data list", {"models": []}, 200),
                           ("error status", {"data": [{"id": "x"}]}, 500)]:
  serve(body, status)
  check(f"not a model server: {name}", pg.server_models(BASE) is None)
serve(b'{"data": [{"id": "bad\\ud800"}, {"id": 5}, {"id": "ok", "status": {"value": "x\\udc00"}}]}')
models = pg.server_models(BASE)
check("unprintable model names skipped", models is not None and [(m["model"], m["status"]) for m in models] == [("ok", "")],
      models)
serve({"data": [{"id": "odd", "status": {"args": ["--ctx-size", ["x"], "-c", {"a": 1}]}}]})
models = pg.server_models(BASE)
check("odd context size ignored", models is not None and models[0]["contextTokens"] == 0, models)
serve(b"[" * 100000 + b"]" * 100000)
check("deeply nested reply refused", pg.server_models(BASE) is None)
replies["/moved/v1/models"] = (200, json.dumps({"data": [{"id": "elsewhere"}]}).encode())


class Redirect(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(302)
    self.send_header("Location", BASE + "/moved/v1/models")
    self.send_header("Content-Length", "0")
    self.end_headers()

  def log_message(self, *_):
    pass


redirector = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
threading.Thread(target=redirector.serve_forever, daemon=True).start()
check("redirect not followed", pg.server_models(f"http://127.0.0.1:{redirector.server_port}") is None)
redirector.shutdown()
serve({"data": [{"id": "qwen"}]})
os.environ.update(http_proxy="http://127.0.0.1:9", HTTP_PROXY="http://127.0.0.1:9", no_proxy="", NO_PROXY="")
check("proxy settings ignored", pg.server_models(BASE) is not None)
for name in ("http_proxy", "HTTP_PROXY", "no_proxy", "NO_PROXY"):
  os.environ.pop(name)
serve(b"x" * (pg.MODELS_REPLY_LIMIT + 10))
check("oversized model list refused", pg.server_models(BASE) is None)
check("closed port is not a server", pg.server_models("http://127.0.0.1:9", 2) is None)

# One server that does not answer does not hide another's models.
serve({"data": [{"id": "qwen"}]})
listed = pg.local_models({"localEndpoints": ["http://127.0.0.1:9", BASE]})
check("local models skip a dead server", [m["id"] for m in listed] == ["local:qwen"], listed)


# --- Discovery --------------------------------------------------------------

bin_dir = work / "bin"
bin_dir.mkdir()
status_file = work / "status.json"
(bin_dir / "tailscale").write_text('#!/bin/sh\ncat -- "$STATUS_FILE"\n')
os.environ["STATUS_FILE"] = str(status_file)
(bin_dir / "tailscale").chmod(0o755)
os.environ["PATH"] = f"{bin_dir}:{os.environ['PATH']}"


def peer(host, ip, user=1, online=True, dns=None):
  return {"HostName": host, "DNSName": dns if dns is not None else f"{host.lower()}.tail.ts.net.",
          "UserID": user, "Online": online, "TailscaleIPs": [ip, "fd7a::1"]}


status = {
  "Self": {"UserID": 1, "HostName": "laptop"},
  "CurrentTailnet": {"MagicDNSEnabled": True},
  "Peer": {
    "a": peer("Desktop", "100.100.70.46"),
    "b": peer("Phone", "100.118.93.33", user=2),          # someone else's device
    "c": peer("Steam", "100.127.189.25", online=False),   # offline
    "d": peer("Odd", "192.168.1.5"),                       # not a Tailscale address
    "f": peer("Public", "100.200.1.1"),                    # 100.x, but outside 100.64.0.0/10
    "g": peer("Bad", "100.64.1.999"),                      # not an address
    "h": peer("Tagged", "100.70.0.9") | {"Tags": ["tag:server"]},
    "e": peer("Jetson", "100.90.136.67", dns="bad name.ts.net."),
  },
}
status_file.write_text(json.dumps(status))

devices = pg.tailscale_devices()
check("tailscale: only your online devices",
      devices == [("Desktop", "100.100.70.46", "desktop.tail.ts.net"), ("Jetson", "100.90.136.67", "")], devices)
status_file.write_text(json.dumps(status | {"CurrentTailnet": {"MagicDNSEnabled": False}}))
check("tailscale: IPs without MagicDNS", all(dns == "" for _, _, dns in pg.tailscale_devices()))
status_file.write_text(json.dumps(status | {"Self": {"UserID": 1, "Tags": ["tag:server"]}}))
check("tailscale: a tagged computer searches only itself", pg.tailscale_devices() == [])
status_file.write_text("not json")
check("tailscale: unreadable status ignored", pg.tailscale_devices() == [])
status_file.write_text(json.dumps(status))

# Every port is "open"; servers answer on the desktop's 8080 and this
# computer's 11434. Nothing is contacted.
connects, asked = [], []
pg.port_open = lambda host, port: connects.append((host, port)) or True
served = {"http://desktop.tail.ts.net:8080": ["radiance"], "http://127.0.0.1:11434": ["llama3\x1b]52;c;eA==\x07"]}


def fake_models(url, timeout=3):
  asked.append(url)
  return [{"model": m} for m in served[url]] if url in served else None


pg.server_models = fake_models
found = pg.discover_endpoints({"localEndpoints": ["http://127.0.0.1:8080"]})
urls = sorted(f["url"] for f in found)
check("discover finds both servers", urls == ["http://127.0.0.1:11434", "http://desktop.tail.ts.net:8080"], found)
check("discover connects by IP only to your devices",
      {h for h, _ in connects} == {"127.0.0.1", "100.100.70.46", "100.90.136.67"}, connects)
check("discover skips a server already added", "http://127.0.0.1:8080" not in asked, asked)

connects.clear()
found = pg.discover_endpoints({"localEndpoints": ["http://Desktop:8080", "http://127.0.0.1:11434"]})
check("discover knows a short name", found == [], found)
found = pg.discover_endpoints({"localEndpoints": ["http://100.100.70.46:8080", "http://localhost:11434"]})
check("discover knows an IP and localhost", found == [], found)

text = pg.describe_models(served["http://127.0.0.1:11434"])
check("model names escaped for the terminal", "\x1b" not in text and "\x07" not in text, repr(text))


# --- Commands ---------------------------------------------------------------

ENV = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"))


def run(*args):
  r = subprocess.run([sys.executable, "-I", str(GUARD), "endpoints", *args], env=ENV, capture_output=True,
                     text=True, timeout=60)
  return r.returncode, r.stdout + r.stderr


def saved():
  return json.loads((work / "config" / "plugin-guard" / "config.json").read_text())["localEndpoints"]


code, out = run("add", BASE + "/", "--json")
check("add saves the address", code == 0 and saved() == ["http://127.0.0.1:8080", BASE]
      and json.loads(out)["models"] == ["qwen"], out)
code, _ = run("add", BASE)
check("add twice keeps one", code == 0 and saved().count(BASE) == 1)
code, out = run("add", "http://host:8080/v1")
check("add refuses a path", code != 0 and BASE in saved(), out)
for i in range(10):
  run("add", f"http://127.0.0.1:{20000 + i}")
check("add stops at the limit", len(saved()) == pg.MAX_LOCAL_ENDPOINTS, saved())
code, out = run("add", "http://127.0.0.1:30000")
check("add past the limit fails", code != 0 and "at most" in out, out)
code, _ = run("remove", BASE)
check("remove drops it", code == 0 and BASE not in saved())
code, out = run("remove", BASE)
check("remove an unknown address fails", code != 0, out)
code, out = run("list", "--json")
config_file = work / "config" / "plugin-guard" / "config.json"
many = [f"http://127.0.0.1:{21000 + i}" for i in range(12)]
config_file.write_text(json.dumps({"localEndpoints": many}))
code, out = run("add", "http://127.0.0.1:31000")
check("full list left untouched", code != 0 and saved() == many, saved())
code, out = run("add", many[10])
check("adding a listed server past the limit succeeds", code == 0 and saved() == many, out)
config_file.write_text(json.dumps({"localEndpoints": ["http://old-host:8080/v1", BASE]}))
code, out = run("remove", "http://old-host:8080/v1")
check("remove an address saved with a path", code == 0 and saved() == [BASE], out)
config_file.write_text(json.dumps({"localEndpoints": many}))
code, out = run("remove", many[0])
check("remove keeps entries past the limit", code == 0 and saved() == many[1:], saved())
code, out = run("list", "--json")
check("list reports the servers in use", code == 0 and len(json.loads(out)["endpoints"]) == min(len(saved()), pg.MAX_LOCAL_ENDPOINTS), out)
code, out = run("discover", "--ask", "--add")
check("--ask and --add are exclusive", code != 0, out)

server.shutdown()
sys.exit(1 if failed else 0)
