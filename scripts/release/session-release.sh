#!/usr/bin/env bash
# session-release.sh — Export a session's context as a standalone tarball
# Usage: session-release.sh <session_id> [output_dir]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ---- arg parsing ----
if [[ $# -lt 1 ]]; then
  echo "Usage: session-release.sh <session_id> [output_dir]"
  echo "  session_id   Session ID to export (e.g. ses_10295f18cfferSGD0cTJT4zQkE)"
  echo "  output_dir   Output directory for tarball (default: ~/.local/share/mimocode/releases)"
  exit 2
fi

SESSION_ID="$1"
OUTPUT_DIR="${2:-$HOME/.local/share/mimocode/releases}"
SOURCE_DB="$HOME/.local/share/mimocode/mimocode.db"
MEMORY_DIR="$HOME/.local/share/mimocode/memory/sessions/$SESSION_ID"

# ---- validate ----
if [[ ! -f "$SOURCE_DB" ]]; then
  mimo_error "source database not found: $SOURCE_DB"
  exit 1
fi

SESSION_TITLE=$(sqlite3 "$SOURCE_DB" "SELECT title FROM session WHERE id='$SESSION_ID';" 2>/dev/null || true)
if [[ -z "$SESSION_TITLE" ]]; then
  mimo_error "session not found in database: $SESSION_ID"
  exit 1
fi

PROJECT_ID=$(sqlite3 "$SOURCE_DB" "SELECT project_id FROM session WHERE id='$SESSION_ID';")
SESSION_SLUG=$(sqlite3 "$SOURCE_DB" "SELECT slug FROM session WHERE id='$SESSION_ID';")

MSG_COUNT=$(sqlite3 "$SOURCE_DB" "SELECT COUNT(*) FROM message WHERE session_id='$SESSION_ID';")
PART_COUNT=$(sqlite3 "$SOURCE_DB" "SELECT COUNT(*) FROM part WHERE session_id='$SESSION_ID';")
TASK_COUNT=$(sqlite3 "$SOURCE_DB" "SELECT COUNT(*) FROM task WHERE session_id='$SESSION_ID';")

echo "Session: $SESSION_ID"
echo "  title:    $SESSION_TITLE"
echo "  messages: $MSG_COUNT"
echo "  parts:    $PART_COUNT"
echo "  tasks:    $TASK_COUNT"

# ---- staging ----
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d)"
STAGING_SESSION="$STAGING/session"
mkdir -p "$STAGING_SESSION"
trap "rm -rf $STAGING" EXIT

# ---- export DB ----
DATA_DB="$STAGING_SESSION/data.db"

sqlite3 "$DATA_DB" <<EOSQL
CREATE TABLE project (
  id text PRIMARY KEY, worktree text NOT NULL, vcs text, name text,
  icon_url text, icon_color text, time_created integer NOT NULL,
  time_updated integer NOT NULL, time_initialized integer,
  sandboxes text NOT NULL, commands text
);

CREATE TABLE session (
  id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
  slug text NOT NULL, directory text NOT NULL, title text NOT NULL,
  version text NOT NULL, share_url text, summary_additions integer,
  summary_deletions integer, summary_files integer, summary_diffs text,
  revert text, permission text, time_created integer NOT NULL,
  time_updated integer NOT NULL, time_compacting integer, time_archived integer,
  workspace_id text, context_from text, context_watermark text,
  last_checkpoint_message_id text
);

CREATE TABLE message (
  id text PRIMARY KEY NOT NULL, session_id text NOT NULL,
  agent_id text NOT NULL DEFAULT 'main', time_created integer NOT NULL,
  time_updated integer NOT NULL, data text NOT NULL
);

CREATE TABLE part (
  id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
  time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
);

CREATE TABLE task (
  id text NOT NULL, session_id text NOT NULL, parent_task_id text,
  status text NOT NULL, summary text NOT NULL, created_at integer NOT NULL,
  last_event_at integer NOT NULL, ended_at integer, cleanup_after integer,
  owner text, PRIMARY KEY (session_id, id)
);

CREATE TABLE task_event (
  id integer PRIMARY KEY AUTOINCREMENT NOT NULL, session_id text NOT NULL,
  task_id text NOT NULL, at integer NOT NULL, kind text NOT NULL, summary text
);
EOSQL

# Attach source and copy data
sqlite3 "$DATA_DB" <<EOSQL
ATTACH '$SOURCE_DB' AS src;
INSERT INTO project SELECT * FROM src.project WHERE id='$PROJECT_ID';
INSERT INTO session SELECT * FROM src.session WHERE id='$SESSION_ID';
INSERT INTO message SELECT * FROM src.message WHERE session_id='$SESSION_ID';
INSERT INTO part SELECT * FROM src.part WHERE session_id='$SESSION_ID';
INSERT INTO task SELECT * FROM src.task WHERE session_id='$SESSION_ID';
INSERT INTO task_event SELECT * FROM src.task_event WHERE session_id='$SESSION_ID';
DETACH src;
EOSQL

DB_SIZE=$(du -h "$DATA_DB" | cut -f1)
echo "  data.db:  $DB_SIZE"
echo "  ✓ database exported"

# ---- copy memory ----
if [[ -d "$MEMORY_DIR" ]]; then
  mkdir -p "$STAGING_SESSION/memory"
  cp -R "$MEMORY_DIR/"* "$STAGING_SESSION/memory/" 2>/dev/null || true
  MEM_COUNT=$(find "$STAGING_SESSION/memory" -type f | wc -l | tr -d ' ')
  echo "  ✓ memory: $MEM_COUNT files"
else
  mimo_warn "memory dir not found: $MEMORY_DIR"
fi

# ---- MANIFEST ----
GIT_COMMIT="$(git -C "$MIMOCODE_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
cat > "$STAGING_SESSION/MANIFEST.txt" <<EOF
session_id: $SESSION_ID
title:      $SESSION_TITLE
slug:       $SESSION_SLUG
project_id: $PROJECT_ID
timestamp:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
git:        $GIT_COMMIT
stats:
  messages:  $MSG_COUNT
  parts:     $PART_COUNT
  tasks:     $TASK_COUNT
  data_db:   $DB_SIZE
EOF

# ---- tarball ----
TARBALL_NAME="mimo-session-${SESSION_ID}.tar.gz"
TARBALL_PATH="$OUTPUT_DIR/$TARBALL_NAME"

tar --no-xattrs -czf "$TARBALL_PATH" \
  -C "$STAGING" \
  --exclude='._*' \
  --exclude='.DS_Store' \
  "session"

TARBALL_SIZE="$(du -h "$TARBALL_PATH" | cut -f1)"

echo ""
echo "Session release complete:"
echo "  tarball: $TARBALL_PATH"
echo "  size:    $TARBALL_SIZE"
echo ""
echo "Transfer to target machine and run:"
echo "  bash $(dirname "$0")/session-install.sh $TARBALL_PATH"
