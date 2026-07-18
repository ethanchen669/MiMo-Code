#!/usr/bin/env bash
# issue-sync.sh — Sync upstream issue status (adopted vs open)
# Usage: issue-sync.sh [--check-only]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true ;;
    -h|--help) echo "Usage: issue-sync.sh [--check-only]"; exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

command -v gh >/dev/null || { mimo_error "gh not in PATH"; exit 1; }

# Issue registry: number → description
ISSUES=(
  "1371:M3 stringified-operation bug"
  "1372:TUI pageup/pagedown keybind"
  "1517:plan/compose hardPermission runtime enforcement"
  "1526:plan_enter/plan_exit model bug"
)

mimo_info "checking upstream issue status"
LOG="$MIMOCODE_LOGS/issue-sync-$(mimo_ts).log"
REPORT="$MIMOCODE_LOGS/upstream-issues-$(mimo_ts).md"

{
  echo "# Upstream Issue Status"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "| Issue | Title | State | Created |"
  echo "|-------|-------|-------|---------|"
  for entry in "${ISSUES[@]}"; do
    num="${entry%%:*}"
    title="${entry##*:}"
    if DATA="$(gh issue view "$num" --repo "$UPSTREAM_REPO" --json state,title,createdAt 2>/dev/null)"; then
      STATE="$(echo "$DATA" | python3 -c "import json,sys;print(json.load(sys.stdin)['state'])")"
      CREATED="$(echo "$DATA" | python3 -c "import json,sys;print(json.load(sys.stdin)['createdAt'])")"
      echo "| #$num | $title | $STATE | $CREATED |"
    else
      echo "| #$num | $title | UNKNOWN | — |"
    fi
  done
} > "$REPORT" 2>&1

cat "$REPORT"
mimo_info "report: $REPORT"

if [[ "$CHECK_ONLY" == "true" ]]; then exit 0; fi
