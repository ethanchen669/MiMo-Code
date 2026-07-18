#!/usr/bin/env bash
# loop.sh — Main orchestrator: chains build → deploy → verify
# Usage: loop.sh <patch|sync|config|all> [--dry-run] [--skip-verify]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TYPE="${1:-}"
shift || true
DRY_RUN=false
SKIP_VERIFY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true ;;
    --skip-verify) SKIP_VERIFY=true ;;
    -h|--help)
      echo "Usage: loop.sh <patch|sync|config|all> [--dry-run] [--skip-verify]"
      echo "  patch   : build + deploy + verify (for source edits)"
      echo "  sync    : sync upstream + build + deploy + verify"
      echo "  config  : validate config + verify"
      echo "  all     : sync + patch + config + verify"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

case "$TYPE" in
  patch|sync|config|all) ;;
  "") mimo_error "missing type arg"; exit 2 ;;
  *) mimo_error "unknown type: $TYPE (use patch|sync|config|all)"; exit 2 ;;
esac

mimo_preflight || exit 1
mimo_info "loop start: type=$TYPE dry-run=$DRY_RUN skip-verify=$SKIP_VERIFY"

EXTRA_ARGS=()
if [[ "$DRY_RUN" == "true" ]]; then EXTRA_ARGS+=(--dry-run); fi

# Step 1: upstream sync (if requested)
if [[ "$TYPE" == "sync" || "$TYPE" == "all" ]]; then
  mimo_info "step 1/4: sync upstream"
  "$SCRIPT_DIR/sync.sh" "${EXTRA_ARGS[@]}" || { mimo_error "sync failed"; exit 1; }
fi

# Step 2: build + deploy (if requested)
if [[ "$TYPE" == "patch" || "$TYPE" == "sync" || "$TYPE" == "all" ]]; then
  mimo_info "step 2/4: build + deploy"
  if [[ "$DRY_RUN" == "true" ]]; then
    "$SCRIPT_DIR/../build/build.sh" --no-deploy || exit 1
  else
    "$SCRIPT_DIR/../build/build.sh" --force || exit 1
  fi
fi

# Step 3: config validation (if requested)
if [[ "$TYPE" == "config" || "$TYPE" == "all" ]]; then
  mimo_info "step 3/4: config validation"
  "$SCRIPT_DIR/../build/config-reload.sh" || exit 1
fi

# Step 4: verify
if [[ "$SKIP_VERIFY" != "true" ]]; then
  mimo_info "step 4/4: verify"
  "$SCRIPT_DIR/../verify/verify.sh" || mimo_warn "verify reported failures (continuing)"
fi

mimo_info "loop complete"
