#!/usr/bin/env bash
# skill-audit.sh — Skill inventory / overlap / integrity audit + safe cleanup actions
# Companion tool for docs/SKILL-AUDIT-SOP.md (see ~/.local/share/mimocode/docs/).
#
# Default (no args): READ-ONLY report — baseline, health, redundancy signals,
#   description-similarity candidates, prefix families. Never mutates anything.
#
# Usage:
#   skill-audit.sh                       # read-only report
#   skill-audit.sh --tsv <path>          # also export full name+description TSV
#   skill-audit.sh --backup a,b,c        # move listed user skills to dated backup dir
#   skill-audit.sh --restore a,b,c       # restore skills from newest matching backup
#   skill-audit.sh --gc-versions         # remove stale builtin/compose version dirs
#                                        #   (keeps current binary version + local)
#   skill-audit.sh --list-backups        # inventory of backup dirs
#   skill-audit.sh --help
#
# Exit codes: 0 ok · 1 usage error · 2 health problems found (report mode)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TSV_PATH=""
ACTION="report"
SKILL_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tsv=*)       TSV_PATH="${1#*=}" ;;
    --tsv)         shift; TSV_PATH="$1" ;;
    --backup=*)    ACTION="backup"; SKILL_LIST="${1#*=}" ;;
    --backup)      shift; ACTION="backup"; SKILL_LIST="$1" ;;
    --restore=*)   ACTION="restore"; SKILL_LIST="${1#*=}" ;;
    --restore)     shift; ACTION="restore"; SKILL_LIST="$1" ;;
    --gc-versions) ACTION="gc-versions" ;;
    --list-backups) ACTION="list-backups" ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
    *)             mimo_error "unknown arg: $1 (see --help)"; exit 1 ;;
  esac
  shift
done

USER_SKILLS="$MIMOCODE_CONFIG_DIR/skills"
BACKUP_ROOT="$HOME/.local/share/mimocode/releases"
CURRENT_VERSION="$(mimo_current_version)"
HEALTH_ISSUES=0

# ================================================================
# Actions
# ================================================================

if [[ "$ACTION" == "list-backups" ]]; then
  found=0
  for d in "$BACKUP_ROOT"/skill-cleanup-backup-*; do
    [[ -d "$d" ]] || continue
    found=1
    echo "== $d ($(ls "$d" | wc -l | tr -d ' ') skills) =="
    ls "$d"
  done
  [[ "$found" == 1 ]] || echo "(no backup dirs under $BACKUP_ROOT)"
  exit 0
fi

if [[ "$ACTION" == "backup" ]]; then
  [[ -n "$SKILL_LIST" ]] || { mimo_error "--backup requires a comma-separated skill list"; exit 1; }
  BACKUP_DIR="$BACKUP_ROOT/skill-cleanup-backup-$(date +%Y%m%d)"
  mkdir -p "$BACKUP_DIR"
  moved=0
  IFS=',' read -ra NAMES <<< "$SKILL_LIST"
  for name in "${NAMES[@]}"; do
    name="$(echo "$name" | xargs)" # trim
    src="$USER_SKILLS/$name"
    if [[ ! -d "$src" ]]; then
      mimo_warn "skip (not found): $name"
      continue
    fi
    if [[ -d "$BACKUP_DIR/$name" ]]; then
      mimo_warn "skip (already in backup): $name"
      continue
    fi
    mv "$src" "$BACKUP_DIR/"
    moved=$((moved + 1))
    mimo_info "backed up: $name -> $BACKUP_DIR/"
  done
  mimo_info "backup done: $moved moved, kept=$(ls "$USER_SKILLS" | wc -l | tr -d ' ') user skills remain"
  mimo_info "rollback: skill-audit.sh --restore $SKILL_LIST"
  exit 0
fi

if [[ "$ACTION" == "restore" ]]; then
  [[ -n "$SKILL_LIST" ]] || { mimo_error "--restore requires a comma-separated skill list"; exit 1; }
  restored=0
  IFS=',' read -ra NAMES <<< "$SKILL_LIST"
  for name in "${NAMES[@]}"; do
    name="$(echo "$name" | xargs)"
    if [[ -d "$USER_SKILLS/$name" ]]; then
      mimo_warn "skip (already installed): $name"
      continue
    fi
    # newest backup dir containing the skill wins
    src=""
    for d in $(ls -dt "$BACKUP_ROOT"/skill-cleanup-backup-* 2>/dev/null); do
      [[ -d "$d/$name" ]] && { src="$d/$name"; break; }
    done
    if [[ -z "$src" ]]; then
      mimo_warn "skip (not in any backup): $name"
      continue
    fi
    mv "$src" "$USER_SKILLS/"
    restored=$((restored + 1))
    mimo_info "restored: $name <- $src"
  done
  mimo_info "restore done: $restored restored, total user skills: $(ls "$USER_SKILLS" | wc -l | tr -d ' ')"
  exit 0
fi

if [[ "$ACTION" == "gc-versions" ]]; then
  gc_dir() {
    local dir="$1" label="$2" removed=0 idx=0 name
    [[ -n "$CURRENT_VERSION" && -d "$dir" ]] || { mimo_warn "GC skipped for $label"; return 0; }
    # Keep `local` plus the two NEWEST version dirs (mtime order): the current
    # binary's extraction and the immediately-previous one — sessions started
    # on the replaced binary may still be running with catalog entries pointing
    # at it (deleting it mid-session breaks compose:*/builtin skill loads).
    while IFS= read -r entry; do
      name="$(basename "$entry")"
      [[ "$name" == "local" ]] && continue
      idx=$((idx + 1))
      if (( idx > 2 )); then
        rm -rf "$entry"
        removed=$((removed + 1))
      fi
    done < <(ls -dt "$dir"/*/ 2>/dev/null)
    if (( removed > 0 )); then
      mimo_info "GC: removed $removed stale dir(s) under $label (kept: 2 newest + local)"
    else
      mimo_info "GC: nothing stale under $label"
    fi
    return 0
  }
  gc_dir "$MIMOCODE_BUILTIN_SKILLS_DIR" "builtin_skills"
  gc_dir "$MIMOCODE_COMPOSE_DIR" "compose"
  mimo_info "GC done (builtin: $(ls "$MIMOCODE_BUILTIN_SKILLS_DIR" | wc -l | tr -d ' ') dirs, compose: $(ls "$MIMOCODE_COMPOSE_DIR" | wc -l | tr -d ' ') dirs)"
  exit 0
fi

# ================================================================
# Report (default, read-only)
# ================================================================

echo "=== Skill Audit Report — $(date '+%Y-%m-%d %H:%M') ==="
echo "binary: $CURRENT_VERSION"

# --- [1/5] Baseline ---
USER_COUNT=$(ls "$USER_SKILLS" 2>/dev/null | wc -l | tr -d ' ')
BUILTIN_DIRS=$(ls "$MIMOCODE_BUILTIN_SKILLS_DIR" 2>/dev/null | wc -l | tr -d ' ')
COMPOSE_DIRS=$(ls "$MIMOCODE_COMPOSE_DIR" 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "[1/5] Baseline"
echo "  user skills:        $USER_COUNT  ($(du -sh "$USER_SKILLS" 2>/dev/null | cut -f1))"
echo "  builtin version dirs: $BUILTIN_DIRS (expect 2: current + local)"
echo "  compose dirs:       $COMPOSE_DIRS (expect 1: local)"

# --- [2/5] Stale version dirs ---
echo ""
echo "[2/5] Stale version dirs"
stale=0
for base in "$MIMOCODE_BUILTIN_SKILLS_DIR" "$MIMOCODE_COMPOSE_DIR"; do
  [[ -d "$base" ]] || continue
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    [[ "$name" == "$CURRENT_VERSION" || "$name" == "local" ]] && continue
    echo "  STALE: $entry"
    stale=$((stale + 1))
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0)
done
if [[ "$stale" == 0 ]]; then
  echo "  OK: none (fix if found: skill-audit.sh --gc-versions)"
else
  echo "  -> run: skill-audit.sh --gc-versions"
fi

# --- [3/5] Health ---
echo ""
echo "[3/5] Health"
for d in "$USER_SKILLS"/*/; do
  name="$(basename "$d")"
  [[ -f "$d/SKILL.md" ]] || { echo "  MISSING SKILL.md: $name"; HEALTH_ISSUES=$((HEALTH_ISSUES+1)); }
done
# name-vs-dir mismatch + deprecated markers + user/builtin collisions via python
python3 - "$USER_SKILLS" "$MIMOCODE_BUILTIN_SKILLS_DIR" "$CURRENT_VERSION" <<'PYEOF' || HEALTH_ISSUES=$((HEALTH_ISSUES+1))
import os, re, sys

user_dir, builtin_base, current = sys.argv[1], sys.argv[2], sys.argv[3]
issues = 0

def frontmatter(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    fm = parts[1]
    def field(key):
        m = re.search(rf"^{key}:\s*(.+)$", fm, re.M)
        if not m:
            return None
        v = m.group(1).strip().strip('"').strip("'")
        return v or None
    return {"name": field("name"), "description": field("description") or ""}

user_names = sorted(d for d in os.listdir(user_dir) if os.path.isdir(os.path.join(user_dir, d)))
for d in user_names:
    fm = frontmatter(os.path.join(user_dir, d, "SKILL.md"))
    if fm is None:
        continue
    # Hierarchical names (security/vulnerabilities/csrf) are the Strix convention
    # with flat dirs — intentional. Namespaced dirs (scientific-db-pubmed-database
    # containing name pubmed-database) are also fine. Only flag when the two
    # share no containment at all (e.g. dir=compose-orchestrator name=compose-routing).
    n = fm["name"] or ""
    suspicious = n and "/" not in n and n != d and n not in d and d not in n
    if suspicious:
        print(f"  NAME/DIR MISMATCH: dir={d} frontmatter.name={n}")
        issues += 1
    if "DEPRECATED" in fm["description"].upper():
        print(f"  DEPRECATED: {d} — {fm['description'][:90]}")
        issues += 1

# user vs builtin collisions (both current version and local extraction roots)
builtin_names = set()
for sub in (current, "local"):
    p = os.path.join(builtin_base, sub, "skills")
    if os.path.isdir(p):
        builtin_names.update(d for d in os.listdir(p) if os.path.isdir(os.path.join(p, d)))
collisions = sorted(set(user_names) & builtin_names)
for c in collisions:
    print(f"  NAME COLLISION user-vs-builtin: {c}")
    issues += 1

if issues == 0:
    print("  OK: all skills have SKILL.md, names match dirs, no deprecated, no builtin collisions")
sys.exit(0 if issues == 0 else 1)
PYEOF

# --- [4/5] Description-similarity candidates (informational) ---
echo ""
echo "[4/5] High-overlap description pairs (Jaccard >= 0.5 — candidates for human review, NOT auto-delete)"
python3 - "$USER_SKILLS" <<'PYEOF'
import os, re, sys
from itertools import combinations

user_dir = sys.argv[1]
STOP = set("use this skill for to the a an and or of in on with when you your it that is are as by from at be can".split())

def frontmatter(path):
    try:
        parts = open(path, encoding="utf-8", errors="replace").read().split("---", 2)
    except OSError:
        return None
    if len(parts) < 3:
        return None
    fm = parts[1]
    m = re.search(r"^description:\s*(.+?)(?=^\w+:|\Z)", fm, re.M | re.S)
    if not m:
        return None
    desc = m.group(1).strip().strip('"').strip("'")
    desc = re.sub(r"\s+", " ", desc)
    return desc

entries = []
for d in sorted(os.listdir(user_dir)):
    p = os.path.join(user_dir, d, "SKILL.md")
    if not os.path.isfile(p):
        continue
    desc = frontmatter(p)
    if desc and len(desc) > 30:
        entries.append((d, desc))

def words(desc):
    return {w for w in re.findall(r"[a-z0-9]+", desc.lower()) if w not in STOP and len(w) > 2}

pairs = []
for (a, da), (b, db) in combinations(entries, 2):
    wa, wb = words(da), words(db)
    if not wa or not wb:
        continue
    j = len(wa & wb) / len(wa | wb)
    if j >= 0.5:
        pairs.append((j, a, b))
pairs.sort(reverse=True)
if not pairs:
    print("  OK: no pairs above threshold")
for j, a, b in pairs[:20]:
    print(f"  {j:.2f}  {a}  <->  {b}")
if len(pairs) > 20:
    print(f"  ... and {len(pairs) - 20} more pairs")
PYEOF

# --- [5/5] Prefix families ---
echo ""
echo "[5/5] Prefix families (>= 2 members — intent clusters to review as a group)"
python3 - "$USER_SKILLS" <<'PYEOF'
import os, sys
from collections import defaultdict

user_dir = sys.argv[1]
families = defaultdict(list)
for d in sorted(os.listdir(user_dir)):
    if not os.path.isdir(os.path.join(user_dir, d)) or "-" not in d:
        continue
    prefix = d.split("-")[0]
    families[prefix].append(d)
for prefix, members in sorted(families.items()):
    if len(members) >= 3:
        print(f"  {prefix}- ({len(members)}): {', '.join(members)}")
PYEOF

# --- TSV export ---
if [[ -n "$TSV_PATH" ]]; then
  python3 - "$USER_SKILLS" "$TSV_PATH" <<'PYEOF'
import os, re, sys

user_dir, out = sys.argv[1], sys.argv[2]
rows = ["name\tdescription"]
for d in sorted(os.listdir(user_dir)):
    p = os.path.join(user_dir, d, "SKILL.md")
    if not os.path.isfile(p):
        continue
    try:
        parts = open(p, encoding="utf-8", errors="replace").read().split("---", 2)
        fm = parts[1] if len(parts) >= 3 else ""
    except OSError:
        fm = ""
    m = re.search(r"^description:\s*(.+?)(?=^\w+:|\Z)", fm, re.M | re.S)
    desc = re.sub(r"\s+", " ", m.group(1).strip().strip('"').strip("'")) if m else ""
    rows.append(f"{d}\t{desc}")
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
print(f"TSV exported: {out} ({len(rows) - 1} skills)", file=sys.stderr)
PYEOF
  echo ""
  echo "TSV exported: $TSV_PATH"
fi

echo ""
if [[ "$HEALTH_ISSUES" -gt 0 ]]; then
  echo "RESULT: $HEALTH_ISSUES health issue(s) found — fix before relying on skill surface"
  exit 2
fi
echo "RESULT: report complete. Judgment calls (B/C/D classification) remain human — see docs/SKILL-AUDIT-SOP.md"
