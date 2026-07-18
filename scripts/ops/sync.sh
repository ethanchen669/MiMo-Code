#!/usr/bin/env bash
# sync.sh — Sync upstream MiMo-Code, resolve conflicts semi-automatically
# Usage: sync.sh [--dry-run] [--strategy ours|theirs]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DRY_RUN=false
STRATEGY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=true ;;
    --strategy=ours)   STRATEGY="ours" ;;
    --strategy=theirs) STRATEGY="theirs" ;;
    --strategy) STRATEGY="$2"; shift ;;
    -h|--help)
      echo "Usage: sync.sh [--dry-run] [--strategy ours|theirs]"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

mimo_preflight || exit 1

cd "$MIMOCODE_REPO"
LOG="$MIMOCODE_LOGS/sync-$(mimo_ts).log"

mimo_info "fetching upstream $UPSTREAM_REPO"
if ! mimo_run_logged "$LOG" git fetch "$UPSTREAM_REPO" --quiet; then
  mimo_error "git fetch failed; check remote config"
  exit 1
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD)"
UPSTREAM_REF="$UPSTREAM_REPO/main"
LOCAL_SHA="$(git rev-parse "$CURRENT")"
REMOTE_SHA="$(git rev-parse "$UPSTREAM_REF")"

if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
  mimo_info "already up-to-date with upstream ($LOCAL_SHA)"
  exit 0
fi

mimo_info "local:  $LOCAL_SHA"
mimo_info "remote: $REMOTE_SHA"

COMMITS_BEHIND="$(git rev-list --count "$LOCAL_SHA..$UPSTREAM_REF")"
mimo_info "behind upstream by $COMMITS_BEHIND commit(s)"

if [[ "$DRY_RUN" == "true" ]]; then
  mimo_info "DRY-RUN: would attempt merge --no-edit"
  exit 0
fi

# Try merge
if mimo_run_logged "$LOG" git merge "$UPSTREAM_REF" --no-edit; then
  mimo_info "merge clean — running build + deploy"
  "$SCRIPT_DIR/../build/build.sh" --force
  exit 0
fi

# Conflict — generate report
REPORT="$MIMOCODE_LOGS/sync-conflict-$(mimo_ts).md"
{
  echo "# Sync conflict report"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "Local branch: $CURRENT ($LOCAL_SHA)"
  echo "Upstream:     $UPSTREAM_REF ($REMOTE_SHA)"
  echo ""
  echo "## Conflicted files"
  git diff --name-only --diff-filter=U
  echo ""
  echo "## Our local patches (last 10 commits)"
  git log --oneline -10
} > "$REPORT"

mimo_error "merge CONFLICT — see $REPORT, resolve manually then rerun"
exit 4
