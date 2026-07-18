#!/usr/bin/env bash
# config-reload.sh — Validate mimocode.json config (JSON syntax + required fields)
# Usage: config-reload.sh [--validate-only]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=true ;;
    -h|--help) echo "Usage: config-reload.sh [--validate-only]"; exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

[[ -f "$MIMOCODE_CONFIG" ]] || { mimo_error "config missing: $MIMOCODE_CONFIG"; exit 1; }

# JSON syntax check
if ! python3 -c "import json; json.load(open('$MIMOCODE_CONFIG'))" 2>/dev/null; then
  mimo_error "JSON syntax error in $MIMOCODE_CONFIG"
  exit 1
fi
mimo_info "JSON syntax OK"

# Required fields
python3 << PYEOF
import json, sys
with open("$MIMOCODE_CONFIG") as f:
    cfg = json.load(f)
required = ["agent"]
agents_required = ["build", "plan", "compose"]
for key in required:
    if key not in cfg:
        print(f"missing top-level: {key}", file=sys.stderr); sys.exit(2)
for name in agents_required:
    if name not in cfg["agent"]:
        print(f"missing agent: {name}", file=sys.stderr); sys.exit(2)
print("required fields OK")
PYEOF

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  mimo_info "validation complete"
  exit 0
fi

mimo_info "config validates — note: most changes require mimo restart to take effect"
