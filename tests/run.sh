#!/bin/bash
# Static-check regression tests: the malicious fixture must be caught by the
# rules below, and the clean one must pass. Run with --model <id> to also check
# that a model review flags the malicious fixture.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/../bin/plugin-guard"
model_args=(--no-model)
[[ ${1-} == --model && -n ${2-} ]] && model_args=(--model "$2")
failed=0

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

exit $failed
