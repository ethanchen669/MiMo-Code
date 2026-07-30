#!/usr/bin/env bash
# session-install.sh — Import a session tarball on a target machine
# Usage: session-install.sh <tarball_path>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: session-install.sh <tarball_path>"
  echo "  tarball_path   Path to mimo-session-<id>.tar.gz"
  exit 2
fi

TARBALL="$1"

if [[ ! -f "$TARBALL" ]]; then
  mimo_error "tarball not found: $TARBALL"
  exit 1
fi

# ---- extract ----
STAGING="$(mktemp -d)"
trap "rm -rf $STAGING" EXIT

echo "Extracting $TARBALL ..."
tar -xzf "$TARBALL" -C "$STAGING"

SESSION_DIR="$STAGING/session"
if [[ ! -d "$SESSION_DIR" ]]; then
  mimo_error "invalid tarball: no session/ directory"
  exit 1
fi

# ---- read MANIFEST ----
MANIFEST="$SESSION_DIR/MANIFEST.txt"
if [[ ! -f "$MANIFEST" ]]; then
  mimo_error "invalid tarball: no MANIFEST.txt"
  exit 1
fi

SESSION_ID=$(grep "^session_id:" "$MANIFEST" | cut -d' ' -f2)
SESSION_TITLE=$(grep "^title:" "$MANIFEST" | cut -d' ' -f2-)

echo ""
echo "Importing session: $SESSION_ID"
echo "  title: $SESSION_TITLE"
echo ""

# ---- import database ----
TARGET_DB="$HOME/.local/share/mimocode/mimocode.db"
DATA_DB="$SESSION_DIR/data.db"

if [[ -f "$DATA_DB" ]]; then
  # Ensure target DB directory exists
  mkdir -p "$(dirname "$TARGET_DB")"

  # Create target DB if it doesn't exist
  if [[ ! -f "$TARGET_DB" ]]; then
    mimo_warn "target database not found, creating: $TARGET_DB"
    sqlite3 "$TARGET_DB" "SELECT 1;" 2>/dev/null || true
  fi

  echo "Merging session data into $TARGET_DB ..."

  sqlite3 "$TARGET_DB" <<EOSQL
ATTACH '$DATA_DB' AS session_pkg;

-- Create tables if they don't exist (first-time setup)
CREATE TABLE IF NOT EXISTS project (
  id text PRIMARY KEY, worktree text NOT NULL, vcs text, name text,
  icon_url text, icon_color text, time_created integer NOT NULL,
  time_updated integer NOT NULL, time_initialized integer,
  sandboxes text NOT NULL, commands text
);

CREATE TABLE IF NOT EXISTS session (
  id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
  slug text NOT NULL, directory text NOT NULL, title text NOT NULL,
  version text NOT NULL, share_url text, summary_additions integer,
  summary_deletions integer, summary_files integer, summary_diffs text,
  revert text, permission text, time_created integer NOT NULL,
  time_updated integer NOT NULL, time_compacting integer, time_archived integer,
  workspace_id text, context_from text, context_watermark text,
  last_checkpoint_message_id text
);

CREATE TABLE IF NOT EXISTS message (
  id text PRIMARY KEY NOT NULL, session_id text NOT NULL,
  agent_id text NOT NULL DEFAULT 'main', time_created integer NOT NULL,
  time_updated integer NOT NULL, data text NOT NULL
);

CREATE TABLE IF NOT EXISTS part (
  id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
  time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
);

CREATE TABLE IF NOT EXISTS task (
  id text NOT NULL, session_id text NOT NULL, parent_task_id text,
  status text NOT NULL, summary text NOT NULL, created_at integer NOT NULL,
  last_event_at integer NOT NULL, ended_at integer, cleanup_after integer,
  owner text, PRIMARY KEY (session_id, id)
);

CREATE TABLE IF NOT EXISTS task_event (
  id integer PRIMARY KEY AUTOINCREMENT NOT NULL, session_id text NOT NULL,
  task_id text NOT NULL, at integer NOT NULL, kind text NOT NULL, summary text
);

-- Insert data (ORDER MATTERS: project→session→message→part, task→task_event)
INSERT OR REPLACE INTO project SELECT * FROM session_pkg.project;
INSERT OR REPLACE INTO session SELECT * FROM session_pkg.session;
INSERT OR REPLACE INTO message SELECT * FROM session_pkg.message;
INSERT OR REPLACE INTO part SELECT * FROM session_pkg.part;
INSERT OR REPLACE INTO task SELECT * FROM session_pkg.task;
INSERT OR REPLACE INTO task_event SELECT * FROM session_pkg.task_event;

DETACH session_pkg;
EOSQL

  echo "  ✓ database merged"
else
  mimo_warn "no data.db in tarball — skipping database import"
fi

# ---- copy memory ----
MEMORY_SRC="$SESSION_DIR/memory"
if [[ -d "$MEMORY_SRC" ]]; then
  MEMORY_DST="$HOME/.local/share/mimocode/memory/sessions/$SESSION_ID"
  mkdir -p "$MEMORY_DST"
  cp -R "$MEMORY_SRC/"* "$MEMORY_DST/" 2>/dev/null || true
  MEM_COUNT=$(find "$MEMORY_DST" -type f | wc -l | tr -d ' ')
  echo "  ✓ memory: $MEM_COUNT files restored"
else
  mimo_warn "no memory/ in tarball — skipping"
fi

# ---- done ----
echo ""
echo "================================================================"
echo " Session imported successfully!"
echo "================================================================"
echo ""
echo "  Session: $SESSION_ID"
echo "  Title:   $SESSION_TITLE"
echo ""
echo "  Run to resume:"
echo "    mimo -s $SESSION_ID"
echo ""
