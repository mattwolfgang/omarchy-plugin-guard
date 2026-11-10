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
# no local changes, and --scan-all scans it anyway.

verified_check() {
  local name=$1 want=$2
  shift 2
  rm -f "$XDG_STATE_HOME/plugin-guard/marketplace.json"
  local got
  got=$("$guard" scan "$work/verified" --no-model --json "$@" 2>/dev/null |
    python3 -I -c 'import json, sys; print(bool(json.load(sys.stdin).get("marketplaceVerified")))')
  if [[ $got == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name (skipped: $got)"
    failed=1
  fi
}

cp -r "$here/fixtures/clean-clock" "$work/verified"
git -C "$work/verified" init -q
git -C "$work/verified" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
  commit -q --allow-empty -m init
git -C "$work/verified" add -A
git -C "$work/verified" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
  commit -q -m files
verified_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$work/verified/manifest.json")
verified_head=$(git -C "$work/verified" rev-parse HEAD)
export PLUGIN_GUARD_CATALOG_URL="file://$work/catalog.json"
write_catalog() {
  printf '{"plugins":[{"id":"%s","verificationStatus":"%s","verificationCommit":"%s"}]}\n' \
    "$verified_id" "$1" "$2" >"$work/catalog.json"
}

write_catalog verified "$verified_head"
verified_check "verified plugin at its verified commit is skipped" True
verified_check "--scan-all scans a verified plugin" False --scan-all
write_catalog unverified "$verified_head"
verified_check "unverified plugin is scanned" False
write_catalog verified "$(git -C "$work/verified" rev-parse HEAD~1)"
verified_check "verified plugin at another commit is scanned" False
write_catalog verified "$verified_head"
(
  # The saved setting, in a config of its own so a --model run's real config
  # is untouched.
  export XDG_CONFIG_HOME="$work/scan-all-config"
  "$guard" scan-all on >/dev/null
  verified_check "scan-all on scans a verified plugin" False
  verified_check "--skip-verified overrides scan-all on" True --skip-verified
  "$guard" scan-all off >/dev/null
  verified_check "scan-all off skips a verified plugin" True
  exit $failed
) || failed=1
echo "// local change" >>"$work/verified/BarWidget.qml"
verified_check "verified plugin with local changes is scanned" False
unset PLUGIN_GUARD_CATALOG_URL

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
