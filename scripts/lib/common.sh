#!/usr/bin/env bash
# common.sh — Shared library for mimo loop scripts
# Source this from other scripts: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# ---- Path constants ----
export MIMOCODE_HOME="${MIMOCODE_HOME:-$HOME/.mimocode}"
export MIMOCODE_CONFIG_DIR="${MIMOCODE_CONFIG_DIR:-$HOME/.config/mimocode}"
export MIMOCODE_REPO="${MIMOCODE_REPO:-$HOME/.local/share/mimocode/source/MiMo-Code}"
export MIMOCODE_PKG_OPENCODE="$MIMOCODE_REPO/packages/opencode"
export MIMOCODE_DIST="$MIMOCODE_PKG_OPENCODE/dist/mimocode-darwin-arm64/bin/mimo"
export MIMOCODE_BIN="${MIMOCODE_BIN:-$MIMOCODE_HOME/bin/mimo}"
export MIMOCODE_BIN_SYMLINK="$MIMOCODE_HOME/bin/mimo.me"
export MIMOCODE_CONFIG="$MIMOCODE_CONFIG_DIR/mimocode.json"
export MIMOCODE_COMPOSE_LATEST="$HOME/.local/share/mimocode/compose/latest"
export MIMOCODE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MIMOCODE_LOGS="$MIMOCODE_SCRIPTS_DIR/logs"
export MIMOCODE_DOCS="$HOME/.local/share/mimocode/docs"
export UPSTREAM_REPO="${UPSTREAM_REPO:-XiaomiMiMo/MiMo-Code}"

# ---- Logging ----
mimo_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] [$level] $msg"
}

mimo_info()  { mimo_log "INFO"  "$@"; }
mimo_warn()  { mimo_log "WARN"  "$@" >&2; }
mimo_error() { mimo_log "ERROR" "$@" >&2; }

# ---- Preflight checks ----
mimo_preflight() {
  local ok=true
  [[ -d "$MIMOCODE_REPO" ]]    || { mimo_error "repo missing: $MIMOCODE_REPO"; ok=false; }
  [[ -f "$MIMOCODE_CONFIG" ]]  || { mimo_error "config missing: $MIMOCODE_CONFIG"; ok=false; }
  command -v bun >/dev/null    || { mimo_error "bun not in PATH"; ok=false; }
  command -v gh >/dev/null     || { mimo_warn "gh not in PATH (issue tracking disabled)"; }
  [[ "$ok" == "true" ]] || { mimo_error "preflight failed"; return 1; }
}

# ---- Version helpers ----
mimo_current_version() {
  "$MIMOCODE_BIN" --version 2>/dev/null || echo "unknown"
}

mimo_built_version() {
  [[ -x "$MIMOCODE_DIST" ]] && "$MIMOCODE_DIST" --version 2>/dev/null || echo "not-built"
}

# ---- Backup rotation ----
mimo_backup() {
  local src="$1"
  [[ -f "$src" ]] || { mimo_warn "backup source missing: $src"; return 0; }
  local old="$src.bak9"
  if [[ -f "$old" ]]; then rm -f "$old"; fi
  for i in 8 7 6 5 4 3 2 1; do
    if [[ -f "$src.bak$i" ]]; then
      mv "$src.bak$i" "$src.bak$((i+1))"
    fi
  done
  if [[ -f "$src.bak" ]]; then
    mv "$src.bak" "$src.bak2"
  fi
  cp "$src" "$src.bak"
  mimo_info "backup created: $src.bak"
}

# ---- Run a command, log output, capture exit code ----
mimo_run_logged() {
  local logfile="$1"; shift
  mkdir -p "$(dirname "$logfile")"
  mimo_info "running: $* (log: $logfile)"
  if "$@" >"$logfile" 2>&1; then
    mimo_info "success: $*"
    return 0
  else
    local rc=$?
    mimo_error "failed (rc=$rc): $* -- see $logfile"
    return $rc
  fi
}

# ---- Timestamp helper ----
mimo_ts() { date -u +%Y%m%d-%H%M%S; }

# ---- Session-mode helper ----
mimo_run() {
  local agent="$1"; shift
  local model="$1"; shift
  local prompt="$1"; shift
  "$MIMOCODE_BIN" run --agent "$agent" -m "$model" --format json "$prompt"
}
