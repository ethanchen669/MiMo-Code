#!/usr/bin/env bash
# build.sh — Build the MiMo Code binary from source
# Usage: build.sh [--force] [--no-deploy]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

FORCE=false
NO_DEPLOY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)     FORCE=true ;;
    --no-deploy) NO_DEPLOY=true ;;
    -h|--help)
      echo "Usage: build.sh [--force] [--no-deploy]"
      echo "  --force      Skip dirty-check (rebuild even if source unchanged)"
      echo "  --no-deploy  Build only, do not invoke deploy.sh"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

mimo_preflight || exit 1

LAST_BUILD_FILE="$MIMOCODE_LOGS/.last_build_ts"
cd "$MIMOCODE_PKG_OPENCODE"
LOG="$MIMOCODE_LOGS/build-$(mimo_ts).log"
mimo_info "starting build (force=$FORCE, no-deploy=$NO_DEPLOY)"

# Optional: skip if source unchanged
if [[ "$FORCE" != "true" ]]; then
  if [[ -f "$MIMOCODE_DIST" && -f "$LAST_BUILD_FILE" ]]; then
    if [[ -z "$(find packages/opencode/src -newer "$LAST_BUILD_FILE" -type f 2>/dev/null)" ]]; then
      mimo_info "source unchanged, skipping build (use --force to override)"
      exit 0
    fi
  fi
fi

# Snapshot the lockfile before building. bun's auto-install (fires during
# `bun run build`) rewrites bun.lock URLs against the configured registry; the
# repo-root .npmrc pins the official registry so rewrites are content-identical
# and the file stays clean. If it DOES change, the pin is being bypassed
# (e.g. NPM_CONFIG_REGISTRY env override) — warn loudly instead of letting the
# pollution surface later as a mysterious dirty tree.
LOCK_HASH_BEFORE="$(git hash-object "$MIMOCODE_REPO/bun.lock" 2>/dev/null || echo none)"

if ! mimo_run_logged "$LOG" bun run --single build; then
  mimo_error "build failed; binary NOT replaced"
  exit 1
fi

LOCK_HASH_AFTER="$(git hash-object "$MIMOCODE_REPO/bun.lock" 2>/dev/null || echo none)"
if [[ "$LOCK_HASH_BEFORE" != "$LOCK_HASH_AFTER" ]]; then
  mimo_warn "bun.lock CHANGED during build — registry pin bypassed? inspect: git diff bun.lock (repo .npmrc pins registry.npmjs.org)"
fi

NEW_VERSION="$(mimo_built_version)"
mimo_info "build succeeded: $NEW_VERSION"
touch "$LAST_BUILD_FILE"

if [[ "$NO_DEPLOY" != "true" ]]; then
  mimo_info "calling deploy.sh"
  "$SCRIPT_DIR/deploy.sh"
fi
