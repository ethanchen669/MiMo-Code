#!/usr/bin/env bash
set -euo pipefail

echo "=== MiMo Code 安装脚本 ==="
echo ""

MIMOCODE_HOME="${HOME}/.mimocode"
MIMOCODE_CONFIG="${HOME}/.config/mimocode"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$MIMOCODE_HOME/bin" ]; then
  echo "错误: 未找到 $MIMOCODE_HOME/bin，请先安装 MiMo Code"
  exit 1
fi

# Step 1: Backup current binary
echo "[1/7] 备份当前二进制..."
cp "$MIMOCODE_HOME/bin/mimo.me" "$MIMOCODE_HOME/bin/mimo.me.bak" 2>/dev/null || true

# Step 2: Replace binary
echo "[2/7] 更新二进制..."
cp "$SCRIPT_DIR/mimo.me" "$MIMOCODE_HOME/bin/mimo.me"
chmod +x "$MIMOCODE_HOME/bin/mimo.me"

# Step 3: Remove quarantine + Gatekeeper bypass (critical for macOS 26+)
echo "[3/7] 绕过 Gatekeeper..."
xattr -cr "$MIMOCODE_HOME/bin/mimo.me" 2>/dev/null || true
# Re-sign with adhoc to ensure valid signature
if [[ "$(uname)" == "Darwin" ]]; then
  codesign --force --sign - "$MIMOCODE_HOME/bin/mimo.me" 2>/dev/null || true
  # Gatekeeper allow-list (spctl --add) was removed in macOS 26+ (Tahoe).
  # ad-hoc codesign above + 'xattr -cr' above is sufficient for local dev.
fi

# Step 4: Create symlink
echo "[4/7] 创建符号链接..."
ln -sf "$MIMOCODE_HOME/bin/mimo.me" "$MIMOCODE_HOME/bin/mimo"

# Step 5: Sync skills, plugins, prompts
echo "[5/7] 同步配置文件..."
if [ -d "$SCRIPT_DIR/skills" ]; then
  mkdir -p "$MIMOCODE_CONFIG/skills"
  cp -R "$SCRIPT_DIR/skills/"* "$MIMOCODE_CONFIG/skills/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/plugins" ]; then
  mkdir -p "$MIMOCODE_CONFIG/plugins"
  cp -R "$SCRIPT_DIR/plugins/"* "$MIMOCODE_CONFIG/plugins/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/prompts" ]; then
  mkdir -p "$MIMOCODE_CONFIG/prompts"
  cp -R "$SCRIPT_DIR/prompts/"* "$MIMOCODE_CONFIG/prompts/" 2>/dev/null || true
fi
if [ -d "$SCRIPT_DIR/commands" ]; then
  mkdir -p "$MIMOCODE_CONFIG/commands"
  cp -R "$SCRIPT_DIR/commands/"* "$MIMOCODE_CONFIG/commands/" 2>/dev/null || true
  echo "  ✓ commands"
fi

# Step 6: Sync node_modules
echo "[6/7] 同步 node_modules..."
if [ -d "$SCRIPT_DIR/node_modules" ]; then
  rsync -a --delete "$SCRIPT_DIR/node_modules/" "$MIMOCODE_HOME/node_modules/"
fi

# Step 7: Merge agent configs
echo "[7/7] 合并 agent 配置..."
python3 << 'MERGEOF' 2>/dev/null || echo "  跳过 agent 配置合并"
import json, os

config_path = os.path.expanduser("~/.config/mimocode/mimocode.json")
if not os.path.exists(config_path):
    print("  警告: mimocode.json 不存在，跳过合并")
    exit(0)

with open(config_path, 'r') as f:
    config = json.load(f)

backup_path = config_path + ".bak.pre-merge"
os.system(f"cp '{config_path}' '{backup_path}'")
print(f"  备份: {backup_path}")

agents = config.get('agent', {})
tarball_agents = {
    'compose': {
        'description': "Orchestration mode for specs-driven development and skill-driven workflows",
        'mode': "primary",
        'model': "openai-proxy/deepseek/deepseek-v4-pro",
        'tools': {"write": True, "edit": True},
        'permission': {"edit": {"docs/compose/*.md": "allow", "docs/compose/specs/*.md": "allow", "docs/compose/plans/*.md": "allow", "docs/compose/reports/*.md": "allow", "*": "deny"}}
    },
    'plan': {
        'description': "Read-only analysis mode for code exploration and solution design",
        'mode': "primary",
        'model': "anthropic-proxy/minimax/MiniMax-M3"
    },
    'security': {
        'description': "Security analysis mode. Dispatches to security-reviewer and other security specialists for vulnerability analysis, penetration testing, and threat modeling.",
        'mode': "primary",
        'model': "openai-proxy/deepseek/deepseek-v4-pro",
        'tools': {"write": False, "edit": False},
        'permission': {"edit": {"docs/security/*.md": "allow", "docs/security/audits/*.md": "allow", "docs/security/threats/*.md": "allow", "security-audit-*.md": "allow", "threat-model-*.md": "allow", "*": "deny"}}
    },
}

updated = 0
for agent_name, tarball_cfg in tarball_agents.items():
    existing = agents.get(agent_name, {})
    merged = {**existing, **tarball_cfg}
    agents[agent_name] = merged
    updated += 1
    print(f"  更新 agent: {agent_name}")

config['agent'] = agents
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"  合并完成 ({updated} 个 agent)")
MERGEOF

echo ""
echo "=== 安装完成 ==="
echo "版本: $(strings "$MIMOCODE_HOME/bin/mimo.me" 2>/dev/null | grep -o '0\.0\.0-main-[0-9]*' | head -1 || echo 'unknown')"
echo "运行 'mimo --version' 验证"
