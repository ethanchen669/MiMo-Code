#!/usr/bin/env bash
# release.sh — MiMo Code release pipeline: build → verify → package → install-sync → summary
# Usage: release.sh [--skip-verify] [--skip-tarball] [--skip-install-update] [--platform macos|ubuntu]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ---- flag parsing ----
SKIP_VERIFY=false
SKIP_TARBALL=false
SKIP_INSTALL_UPDATE=false
PLATFORM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-verify)          SKIP_VERIFY=true ;;
    --skip-tarball)         SKIP_TARBALL=true ;;
    --skip-install-update)  SKIP_INSTALL_UPDATE=true ;;
    --platform=*)           PLATFORM="${1#*=}" ;;
    --platform)             PLATFORM="$2"; shift ;;
    -h|--help)
      echo "Usage: release.sh [--skip-verify] [--skip-tarball] [--skip-install-update] [--platform macos|ubuntu]"
      echo ""
      echo "  --skip-verify           Skip the e2e test verification phase"
      echo "  --skip-tarball          Skip tarball creation"
      echo "  --skip-install-update   Skip updating agent configs in install scripts"
      echo "  --platform macos|ubuntu Override platform auto-detection"
      exit 0
      ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# ---- platform detection ----
if [[ -z "$PLATFORM" ]]; then
  case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="ubuntu" ;;
    *)      mimo_error "unsupported OS: $(uname -s) (use --platform macos|ubuntu)"; exit 1 ;;
  esac
fi
if [[ "$PLATFORM" != "macos" && "$PLATFORM" != "ubuntu" ]]; then
  mimo_error "invalid platform: $PLATFORM (use macos or ubuntu)"; exit 1
fi

# ---- setup ----
BUILD_START=$(date +%s)
TARBALL_PATH="(skipped)"
TARBALL_SIZE="-"
TOTAL_PHASES=5
phase=0

phase_header() {
  phase=$((phase + 1))
  local label="$1"
  local offset="${2:-}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[$phase/$TOTAL_PHASES] $label"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

section_ok() {
  echo "  ✓ $1"
}

# ================================================================
# Phase 1: Build
# ================================================================
phase_header "Building (build.sh --force)"

"$SCRIPT_DIR/../build/build.sh" --force || {
  mimo_error "build failed — aborting release"
  exit 1
}

VERSION="$(mimo_built_version)"
GIT_COMMIT="$(git -C "$MIMOCODE_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
section_ok "version: $VERSION"
section_ok "git: $GIT_COMMIT"

# ================================================================
# Phase 2: Verify
# ================================================================
if [[ "$SKIP_VERIFY" == "true" ]]; then
  phase_header "Verify (skipped)"
else
  phase_header "Verifying (verify.sh)"

  "$SCRIPT_DIR/../verify/verify.sh" || {
    mimo_error "verify failed — aborting release"
    exit 1
  }
  section_ok "all e2e tests passed"
fi

# ================================================================
# Phase 3: Create tarball
# ================================================================
if [[ "$SKIP_TARBALL" == "true" ]]; then
  phase_header "Package (skipped)"
else
  phase_header "Packaging tarball"

  RELEASES_DIR="$HOME/.local/share/mimocode/releases"
  mkdir -p "$RELEASES_DIR"

  TARBALL_NAME="mimo-${VERSION}-${PLATFORM}.tar.gz"
  TARBALL_PATH="$RELEASES_DIR/$TARBALL_NAME"

  STAGING="$(mktemp -d)"
  STAGING_PKG="$STAGING/mimo-${VERSION}-${PLATFORM}"
  mkdir -p "$STAGING_PKG"

  # ---- binary ----
  if [[ -f "$MIMOCODE_BIN_SYMLINK" ]]; then
    cp "$MIMOCODE_BIN_SYMLINK" "$STAGING_PKG/mimo.me"
    chmod +x "$STAGING_PKG/mimo.me"
    section_ok "binary: mimo.me"
  else
    mimo_error "binary not found at $MIMOCODE_BIN_SYMLINK"
    rm -rf "$STAGING"
    exit 1
  fi

  # ---- skills ----
  if [[ -d "$MIMOCODE_CONFIG_DIR/skills" ]]; then
    mkdir -p "$STAGING_PKG/skills"
    cp -R "$MIMOCODE_CONFIG_DIR/skills/"* "$STAGING_PKG/skills/" 2>/dev/null || true
    section_ok "skills: $(find "$MIMOCODE_CONFIG_DIR/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') entries"
  else
    mimo_warn "skills dir missing: $MIMOCODE_CONFIG_DIR/skills"
  fi

  # ---- plugins (exclude .ts / .tsx, keep .js only) ----
  if [[ -d "$MIMOCODE_CONFIG_DIR/plugins" ]]; then
    mkdir -p "$STAGING_PKG/plugins"
    rsync -a \
      --exclude='*.ts' \
      --exclude='*.tsx' \
      --exclude='.DS_Store' \
      --exclude='._*' \
      "$MIMOCODE_CONFIG_DIR/plugins/" "$STAGING_PKG/plugins/" 2>/dev/null || true
    section_ok "plugins: synced (js only)"
  else
    mimo_warn "plugins dir missing: $MIMOCODE_CONFIG_DIR/plugins"
  fi

  # ---- prompts (optional) ----
  if [[ -d "$MIMOCODE_CONFIG_DIR/prompts" ]]; then
    mkdir -p "$STAGING_PKG/prompts"
    cp -R "$MIMOCODE_CONFIG_DIR/prompts/"* "$STAGING_PKG/prompts/" 2>/dev/null || true
    section_ok "prompts: $(find "$MIMOCODE_CONFIG_DIR/prompts" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') entries"
  fi

  # ---- commands (optional) ----
  if [[ -d "$MIMOCODE_CONFIG_DIR/commands" ]]; then
    mkdir -p "$STAGING_PKG/commands"
    cp -R "$MIMOCODE_CONFIG_DIR/commands/"* "$STAGING_PKG/commands/" 2>/dev/null || true
    section_ok "commands: $(find "$MIMOCODE_CONFIG_DIR/commands" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') entries"
  fi

  # ---- node_modules (exclude .cache) ----
  if [[ -d "$MIMOCODE_HOME/node_modules" ]]; then
    mkdir -p "$STAGING_PKG/node_modules"
    rsync -a --delete \
      --exclude='.cache' \
      --exclude='.DS_Store' \
      --exclude='._*' \
      "$MIMOCODE_HOME/node_modules/" "$STAGING_PKG/node_modules/" 2>/dev/null || true
    section_ok "node_modules: synced"
  else
    mimo_warn "node_modules missing: $MIMOCODE_HOME/node_modules"
  fi

  # ---- install script ----
  INSTALL_SCRIPT="mimo-install.sh"
  [[ "$PLATFORM" == "ubuntu" ]] && INSTALL_SCRIPT="mimo-install-ubuntu24.sh"
  if [[ -f "$SCRIPT_DIR/../install/$INSTALL_SCRIPT" ]]; then
    cp "$SCRIPT_DIR/../install/$INSTALL_SCRIPT" "$STAGING_PKG/$INSTALL_SCRIPT"
    section_ok "install script: $INSTALL_SCRIPT"
  else
    mimo_error "install script not found: $SCRIPT_DIR/$INSTALL_SCRIPT"
    rm -rf "$STAGING"
    exit 1
  fi

  # ---- RELEASE.txt ----
  cat > "$STAGING_PKG/RELEASE.txt" <<EOF
version: $VERSION
date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
git:     $GIT_COMMIT
platform: $PLATFORM
EOF

  # ---- create tarball ----
  tar --no-xattrs -czf "$TARBALL_PATH" \
    -C "$STAGING" \
    --exclude='._*' \
    --exclude='.DS_Store' \
    --exclude='.git' \
    "mimo-${VERSION}-${PLATFORM}"

  tar_rc=$?
  rm -rf "$STAGING"

  if [[ $tar_rc -ne 0 ]]; then
    mimo_error "tar failed (rc=$tar_rc)"
    exit 1
  fi

  TARBALL_SIZE="$(du -h "$TARBALL_PATH" | cut -f1)"

  # ---- verify tarball ----
  VERIFY_TMP="$(mktemp -d)"
  if tar -xzf "$TARBALL_PATH" -C "$VERIFY_TMP" &>/dev/null; then
    if [[ -x "$VERIFY_TMP/mimo-${VERSION}-${PLATFORM}/mimo.me" ]]; then
      section_ok "tarball verified: mimo.me is executable"
    else
      mimo_error "tarball verification failed: mimo.me not executable"
      rm -rf "$VERIFY_TMP"
      exit 1
    fi
  else
    mimo_error "tarball verification failed: cannot extract"
    rm -rf "$VERIFY_TMP"
    exit 1
  fi
  rm -rf "$VERIFY_TMP"

  section_ok "tarball: $TARBALL_PATH ($TARBALL_SIZE)"
fi

# ================================================================
# Phase 4: Update install scripts
# ================================================================
if [[ "$SKIP_INSTALL_UPDATE" == "true" ]]; then
  phase_header "Install-script sync (skipped)"
else
  phase_header "Syncing install-script agent configs"

  python3 << 'PYEOF'
import json, os, re, sys

config_path = os.path.expanduser("~/.config/mimocode/mimocode.json")
if not os.path.exists(config_path):
    print("  ⚠ mimocode.json not found — skipping install-script sync")
    sys.exit(0)

with open(config_path) as f:
    config = json.load(f)

agents = config.get("agent", {})

def extract(name, *keys):
    """Extract a dict of only the requested keys from an agent config."""
    agent = agents.get(name, {})
    out = {}
    for k in keys:
        if k in agent:
            out[k] = agent[k]
    return out

compose_data = extract("compose", "description", "mode", "model", "tools", "permission")
plan_data = extract("plan", "description", "mode", "model")
security_data = extract("security", "description", "mode", "model", "tools", "permission")

# Fallback to keep descriptions if absent in config
if "description" not in compose_data:
    compose_data["description"] = "Orchestration mode for specs-driven development and skill-driven workflows"
if "description" not in plan_data:
    plan_data["description"] = "Planning and design mode"
if "description" not in security_data:
    security_data["description"] = "Security analysis mode. Dispatches to security-reviewer and other security specialists for vulnerability analysis, penetration testing, and threat modeling."
if "mode" not in compose_data:
    compose_data["mode"] = "primary"
if "mode" not in plan_data:
    plan_data["mode"] = "primary"
if "mode" not in security_data:
    security_data["mode"] = "primary"

# Build the NEW tarball_agents dict as raw python source
new_block_lines = ["tarball_agents = {"]
for name, data in [
    # Preserve exact field order from current install scripts
    ("compose", compose_data),
    ("plan",   plan_data),
    ("security", security_data),
]:
    lines = []
    lines.append(f"    '{name}': {{")
    items = [
        ("description", data.get("description")),
        ("mode", data.get("mode")),
        ("model", data.get("model")),
    ]
    if name in ("compose", "security"):
        items.append(("tools", data.get("tools")))
    if name in ("compose", "security"):
        items.append(("permission", data.get("permission")))

    present = [(k, v) for k, v in items if v is not None]
    for i, (k, v) in enumerate(present):
        comma = "," if i < len(present) - 1 else ""
        val_str = json.dumps(v, ensure_ascii=False) \
            .replace("true", "True") \
            .replace("false", "False") \
            .replace("null", "None")
        lines.append(f"        '{k}': {val_str}{comma}")
    lines.append(f"    }},")
    new_block_lines.extend(lines)

new_block_lines.append("}")
new_block = "\n".join(new_block_lines)

scripts_dir = os.path.expanduser("~/.local/share/mimocode/scripts/install")
updated = 0

for script_name in ["mimo-install.sh", "mimo-install-ubuntu24.sh"]:
    script_path = os.path.join(scripts_dir, script_name)
    if not os.path.exists(script_path):
        print(f"  ⚠ {script_name} not found — skipping")
        continue

    with open(script_path) as f:
        content = f.read()

    # Match the tarball_agents = { … } block inside the MERGEOF heredoc
    # Pattern: "tarball_agents = {" followed by non-greedy content until "}"
    # followed by blank line and "updated = 0"
    pattern = r"(tarball_agents\s*=\s*\{)(.*?)(^\s*\}\s*\n\nupdated\s*=\s*0)"
    match = re.search(pattern, content, re.DOTALL | re.MULTILINE)
    if not match:
        print(f"  ⚠ {script_name}: tarball_agents block not found — skipping")
        continue

    new_content = content[:match.start()] + new_block + "\n\nupdated = 0" + content[match.end():]

    # Back up and write
    os.system(f"cp '{script_path}' '{script_path}.bak.release'")
    with open(script_path, "w") as f:
        f.write(new_content)

    print(f"  ✓ {script_name}: synced compose/plan/security configs")
    updated += 1

print(f"  同步完成 ({updated} 个脚本)")
PYEOF

  section_ok "install scripts updated"
fi

# ================================================================
# Phase 5: Summary
# ================================================================
BUILD_DURATION=$(( $(date +%s) - BUILD_START ))
phase_header "Release summary"

cat <<SUMMARY

  version:    $VERSION
  platform:   $PLATFORM
  tarball:    $TARBALL_PATH
  size:       $TARBALL_SIZE
  git:        $GIT_COMMIT
  duration:   ${BUILD_DURATION}s

SUMMARY

echo "Release pipeline complete."
