#!/usr/bin/env bash
# verify.sh — Run E2E test suite, aggregate pass/fail, write report
# Usage: verify.sh [--suite all|plan|compose|build|prewalk|meta] [--report json|text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/e2e.sh"

SUITE="all"
REPORT_FORMAT="text"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite=*)  SUITE="${1#*=}" ;;
    --suite)    SUITE="$2"; shift ;;
    --report=*) REPORT_FORMAT="${1#*=}" ;;
    --report)   REPORT_FORMAT="$2"; shift ;;
    -h|--help)
      echo "Usage: verify.sh [--suite all|plan|compose|build|prewalk|meta] [--report json|text]"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

mimo_preflight || exit 1

LOG="$MIMOCODE_LOGS/verify-$(mimo_ts).log"
REPORT="$MIMOCODE_LOGS/verify-$(mimo_ts).json"

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if OUTPUT="$(e2e_run_all "$SUITE" 2>&1)"; then
  SUITE_RC=0
else
  SUITE_RC=1
fi
END_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "$OUTPUT"

PASS_LINE="$(echo "$OUTPUT" | grep -oE 'Result: [0-9]+/[0-9]+' | head -1 | awk '{print $2}')"
PASSED="${PASS_LINE%/*}"
TOTAL="${PASS_LINE#*/}"

python3 - "$PASSED" "$TOTAL" "$START_TS" "$END_TS" "$SUITE" "$REPORT" <<'PYEOF' >/dev/null
import json, sys, datetime
passed, total, start, end, suite, path = sys.argv[1:7]
report = {
    "suite": suite,
    "passed": int(passed),
    "total": int(total),
    "start_ts": start,
    "end_ts": end,
    "duration_seconds": (datetime.datetime.fromisoformat(end.replace("Z","+00:00")) - datetime.datetime.fromisoformat(start.replace("Z","+00:00"))).total_seconds(),
    "result": "PASS" if passed == total else "FAIL",
}
with open(path, "w") as f:
    json.dump(report, f, indent=2)
PYEOF

mimo_info "JSON report: $REPORT"

exit $SUITE_RC
