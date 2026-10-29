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

exit $failed
