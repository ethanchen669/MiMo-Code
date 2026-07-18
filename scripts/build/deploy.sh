#!/usr/bin/env bash
# deploy.sh — Deploy built binary to active mimo.me
# Usage: deploy.sh [--binary <path>] [--dry-run]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

BINARY="$MIMOCODE_DIST"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary=*) BINARY="${arg#*=}" ;;
    --binary)   BINARY="$2"; shift ;;
    --dry-run)  DRY_RUN=true ;;
    -h|--help)
      echo "Usage: deploy.sh [--binary <path>] [--dry-run]"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

mimo_preflight || exit 1

[[ -x "$BINARY" ]] || { mimo_error "binary not executable: $BINARY"; exit 1; }

NEW_VERSION="$("$BINARY" --version 2>/dev/null)"
CURRENT_VERSION="$(mimo_current_version)"
mimo_info "deploying: $BINARY ($NEW_VERSION) -> active mimo.me ($CURRENT_VERSION)"

if [[ "$DRY_RUN" == "true" ]]; then
  mimo_info "DRY-RUN: would backup $MIMOCODE_BIN_SYMLINK, replace with $BINARY"
  exit 0
fi

# Step 1: backup current binary
if [[ -f "$MIMOCODE_BIN_SYMLINK" ]]; then
  mimo_backup "$MIMOCODE_BIN_SYMLINK"
fi

# Step 2: replace (handle symlinks correctly)
if [[ -L "$MIMOCODE_BIN" ]]; then
  rm "$MIMOCODE_BIN"
fi
cp "$BINARY" "$MIMOCODE_BIN_SYMLINK"
chmod +x "$MIMOCODE_BIN_SYMLINK"
# Recreate symlink from mimo -> mimo.me
ln -sf "$MIMOCODE_BIN_SYMLINK" "$MIMOCODE_BIN"

# Step 3: sign binary (required for macOS Gatekeeper)
if [[ "$(uname)" == "Darwin" ]]; then
  mimo_info "signing binary with ad-hoc signature"
  codesign --force --sign - "$MIMOCODE_BIN_SYMLINK" 2>/dev/null || mimo_warn "codesign failed (non-fatal)"
fi

# Step 4: sync node_modules (in case plugin was updated)
mimo_info "running: bun install --force (sync node_modules)"
mimo_run_logged "$MIMOCODE_LOGS/bun-install-$(mimo_ts).log" \
  bash -c "cd '$MIMOCODE_HOME' && bun install --force"

# Step 4: clean compose skill extraction
if [[ -d "$MIMOCODE_COMPOSE_LATEST" ]]; then
  mimo_info "removing stale compose/latest"
  rm -rf "$MIMOCODE_COMPOSE_LATEST"
fi

# Step 5: verify
DEPLOYED_VERSION="$(mimo_current_version)"
if [[ "$DEPLOYED_VERSION" == "$NEW_VERSION" ]]; then
  mimo_info "deploy succeeded: mimo now at $DEPLOYED_VERSION"
else
  mimo_error "version mismatch: expected=$NEW_VERSION actual=$DEPLOYED_VERSION"
  exit 2
fi
