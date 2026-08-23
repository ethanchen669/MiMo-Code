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

# Step 5: clean compose skill extraction (old convention dir)
if [[ -d "$MIMOCODE_COMPOSE_LATEST" ]]; then
  mimo_info "removing stale compose/latest"
  rm -rf "$MIMOCODE_COMPOSE_LATEST"
fi

# Step 6: GC stale runtime-extracted version dirs
# builtin_skills/<version>/ and compose/<version>/ are runtime caches: each
# binary extracts its own bundle into its version dir on first run and
# re-extracts on demand when the marker mismatches (so a rolled-back binary
# simply re-extracts — nothing is lost by deleting old dirs). Keep only the
# deployed version and `local` (dev-build extraction root); without this GC
# every build/deploy cycle accumulates another ~1.5-3M dir forever.
mimo_gc_version_dirs() {
  local dir="$1" label="$2" removed=0 name
  [[ -n "$NEW_VERSION" && -d "$dir" ]] || { mimo_warn "GC skipped for $label"; return 0; }
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    [[ "$name" == "$NEW_VERSION" || "$name" == "local" ]] && continue
    rm -rf "$entry"
    removed=$((removed + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0)
  if (( removed > 0 )); then
    mimo_info "GC: removed $removed stale dir(s) under $label (kept: $NEW_VERSION, local)"
  fi
}
mimo_gc_version_dirs "$MIMOCODE_BUILTIN_SKILLS_DIR" "builtin_skills"
mimo_gc_version_dirs "$MIMOCODE_COMPOSE_DIR" "compose"

# Step 7: verify
DEPLOYED_VERSION="$(mimo_current_version)"
if [[ "$DEPLOYED_VERSION" == "$NEW_VERSION" ]]; then
  mimo_info "deploy succeeded: mimo now at $DEPLOYED_VERSION"
else
  mimo_error "version mismatch: expected=$NEW_VERSION actual=$DEPLOYED_VERSION"
  exit 2
fi
