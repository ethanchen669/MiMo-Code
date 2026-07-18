#!/usr/bin/env bash
# mimo-install-ubuntu24.sh — MiMo Code installer for Ubuntu 24.x
set -euo pipefail

echo "=== MiMo Code Ubuntu24 安装脚本 ==="
echo ""

MIMOCODE_HOME="${HOME}/.mimocode"
MIMOCODE_CONFIG="${HOME}/.config/mimocode"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_FROM_SOURCE=false

# ---- flag parsing ----
for arg in "$@"; do
  case "$arg" in
    --build-from-source)
      BUILD_FROM_SOURCE=true
      ;;
    --help|-h)
      echo "Usage: $0 [--build-from-source]"
      echo ""
      echo "  --build-from-source  Build the binary from GitHub source instead of"
      echo "                       using the prebuilt tarball binary."
      echo ""
      echo "  --help, -h           Show this help."
      exit 0
      ;;
    *)
      echo "未知参数: $arg"
      echo "使用 --help 查看帮助"
      exit 1
      ;;
  esac
done

# ============================================================
# [0/7] Prerequisites — check tools and detect Ubuntu version
# ============================================================
echo "[0/7] 检查前置依赖..."

MISSING=""

for cmd in bun python3 unzip; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="${MISSING}  $cmd\n"
  fi
done

if [ -n "$MISSING" ]; then
  echo "错误: 缺少以下前置依赖:"
  printf "%b" "$MISSING"
  echo ""
  echo "请先安装: sudo apt update && sudo apt install -y python3 unzip"
  echo "Bun 安装: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

echo "  ✓ bun:     $(bun --version 2>/dev/null || echo 'installed')"
echo "  ✓ python3: $(python3 --version 2>/dev/null || echo 'installed')"
echo "  ✓ unzip:   $(unzip -v 2>/dev/null | head -1 || echo 'installed')"

# Detect Ubuntu version
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    echo "  警告: 当前系统是 '$ID'，本脚本针对 Ubuntu 24.x 设计，可能不完全兼容"
  else
    echo "  ✓ Ubuntu ${VERSION_ID:-unknown}"
    MAJOR_VER="$(echo "$VERSION_ID" | cut -d. -f1)"
    if [ "$MAJOR_VER" != "24" ]; then
      echo "  注意: 检测到 Ubuntu ${VERSION_ID}，推荐使用 24.x"
    fi
  fi
else
  echo "  警告: 未找到 /etc/os-release，无法检测系统版本"
fi

echo ""

# ============================================================
# [1/7] Acquire binary
# ============================================================
echo "[1/7] 获取二进制..."

BIN_DIR="$MIMOCODE_HOME/bin"
mkdir -p "$BIN_DIR"

if [ "$BUILD_FROM_SOURCE" = true ] || [ ! -f "$SCRIPT_DIR/mimo.me" ]; then
  # ---- build-from-source path ----
  echo "  → 从源码构建..."

  if ! command -v git &>/dev/null; then
    echo "错误: 源码构建需要 git，请先安装: sudo apt install -y git"
    exit 1
  fi

  SOURCE_DIR="$HOME/.local/share/mimocode/source/MiMo-Code"

  if [ -d "$SOURCE_DIR" ]; then
    echo "  → 源码目录已存在，增量更新..."
    (cd "$SOURCE_DIR" && git pull --ff-only)
  else
    echo "  → 克隆仓库 ethanchen669/MiMo-Code..."
    git clone --depth 1 https://github.com/ethanchen669/MiMo-Code.git "$SOURCE_DIR"
  fi

  echo "  → 安装依赖..."
  (cd "$SOURCE_DIR" && bun install)

  echo "  → 构建..."
  (cd "$SOURCE_DIR/packages/opencode" && bun run --single build)

  # Auto-detect the Linux binary
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  BIN_ARCH="x64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    *)
      echo "错误: 不支持的架构: $ARCH"
      exit 1
      ;;
  esac

  SOURCE_BIN="$SOURCE_DIR/packages/opencode/dist/mimocode-linux-${BIN_ARCH}/bin/mimo"
  if [ ! -f "$SOURCE_BIN" ]; then
    echo "错误: 构建产物未找到: $SOURCE_BIN"
    echo "源码目录保留用于调试: $SOURCE_DIR"
    exit 1
  fi

  cp "$SOURCE_BIN" "$BIN_DIR/mimo.me"
  chmod +x "$BIN_DIR/mimo.me"
  echo "  ✓ 构建完成 (linux-${BIN_ARCH})"
else
  # ---- prebuilt binary path ----
  cp "$SCRIPT_DIR/mimo.me" "$BIN_DIR/mimo.me"
  chmod +x "$BIN_DIR/mimo.me"
  echo "  ✓ 二进制已安装"
fi

echo ""

# ============================================================
# [2/7] Symlink
# ============================================================
echo "[2/7] 创建符号链接..."
ln -sf "$BIN_DIR/mimo.me" "$BIN_DIR/mimo"
echo "  ✓ mimo -> mimo.me"

echo ""

# ============================================================
# [3/7] PATH configuration
# ============================================================
echo "[3/7] 配置 PATH..."

PATH_LINE='export PATH="$HOME/.mimocode/bin:$PATH"'

# .bashrc
if [ -f "$HOME/.bashrc" ]; then
  if ! grep -q '.mimocode/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo "$PATH_LINE" >> "$HOME/.bashrc"
    echo "  ✓ 已添加到 ~/.bashrc"
  else
    echo "  ~/.bashrc 已包含 mimocode PATH"
  fi
else
  echo "$PATH_LINE" >> "$HOME/.bashrc"
  echo "  ✓ 已创建 ~/.bashrc 并添加 PATH"
fi

# .zshrc
if [ -f "$HOME/.zshrc" ]; then
  if ! grep -q '.mimocode/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo "$PATH_LINE" >> "$HOME/.zshrc"
    echo "  ✓ 已添加到 ~/.zshrc"
  else
    echo "  ~/.zshrc 已包含 mimocode PATH"
  fi
fi

echo ""

# ============================================================
# [4/7] Sync skills, plugins, prompts
# ============================================================
echo "[4/7] 同步配置文件..."

if [ -d "$SCRIPT_DIR/skills" ]; then
  mkdir -p "$MIMOCODE_CONFIG/skills"
  cp -R "$SCRIPT_DIR/skills/"* "$MIMOCODE_CONFIG/skills/" 2>/dev/null || true
  echo "  ✓ skills"
fi

if [ -d "$SCRIPT_DIR/plugins" ]; then
  mkdir -p "$MIMOCODE_CONFIG/plugins"
  cp -R "$SCRIPT_DIR/plugins/"* "$MIMOCODE_CONFIG/plugins/" 2>/dev/null || true
  echo "  ✓ plugins"
fi

if [ -d "$SCRIPT_DIR/prompts" ]; then
  mkdir -p "$MIMOCODE_CONFIG/prompts"
  cp -R "$SCRIPT_DIR/prompts/"* "$MIMOCODE_CONFIG/prompts/" 2>/dev/null || true
  echo "  ✓ prompts"
fi

if [ -d "$SCRIPT_DIR/commands" ]; then
  mkdir -p "$MIMOCODE_CONFIG/commands"
  cp -R "$SCRIPT_DIR/commands/"* "$MIMOCODE_CONFIG/commands/" 2>/dev/null || true
  echo "  ✓ commands"
fi

echo ""

# ============================================================
# [5/7] Sync node_modules
# ============================================================
echo "[5/7] 同步 node_modules..."

if [ -d "$SCRIPT_DIR/node_modules" ]; then
  if command -v rsync &>/dev/null; then
    rsync -a --delete "$SCRIPT_DIR/node_modules/" "$MIMOCODE_HOME/node_modules/"
  else
    mkdir -p "$MIMOCODE_HOME/node_modules"
    cp -R "$SCRIPT_DIR/node_modules/"* "$MIMOCODE_HOME/node_modules/" 2>/dev/null || true
  fi
  echo "  ✓ node_modules"
fi

echo ""

# ============================================================
# [6/7] Init config — create default mimocode.json if missing
# ============================================================
echo "[6/7] 初始化配置..."

CONFIG_PATH="$MIMOCODE_CONFIG/mimocode.json"
if [ ! -f "$CONFIG_PATH" ]; then
  mkdir -p "$MIMOCODE_CONFIG"
  cat > "$CONFIG_PATH" << 'JSONEOF'
{
  "version": "1.0.0",
  "model": {
    "default": "openai-proxy/deepseek/deepseek-v4-pro"
  },
  "agent": {}
}
JSONEOF
  echo "  ✓ 已创建默认 mimocode.json"
else
  echo "  mimocode.json 已存在，跳过"
fi

echo ""

# ============================================================
# [7/7] Merge agent configs
# ============================================================
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
echo "二进制: $BIN_DIR/mimo.me"
echo "版本: $(strings "$BIN_DIR/mimo.me" 2>/dev/null | grep -o '0\.0\.0-main-[0-9]*' | head -1 || echo 'unknown')"
echo ""
echo "重新打开终端或运行 'source ~/.bashrc' 后，执行 'mimo --version' 验证"
