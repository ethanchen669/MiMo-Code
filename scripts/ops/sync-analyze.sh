#!/usr/bin/env bash
# sync-analyze.sh — Pre-sync four-layer analysis (SYNC-SOP)
# Usage: sync-analyze.sh [--no-fetch] [--report <path>]
#
# Generates the pre-merge analysis report required by docs/SYNC-SOP.md:
#   A. upstream change inventory     B. code-conflict preview (merge-tree, zero side effects)
#   C. semantic-conflict evidence    D. performance/behavior impact evidence
#   + BUILD-DEPLOY-RELEASE-SOP §9.1 regression re-checks (current tree)
#
# READ-ONLY by design: fetches (unless --no-fetch), never merges/builds/deploys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NO_FETCH=false
REPORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-fetch)        NO_FETCH=true ;;
    --report)          REPORT="$2"; shift ;;
    -h|--help)
      echo "Usage: sync-analyze.sh [--no-fetch] [--report <path>]"
      echo "  --no-fetch   skip git fetch upstream (use existing refs)"
      echo "  --report     output report path (default: \$MIMOCODE_LOGS/sync-analysis-<ts>.md)"
      exit 0 ;;
    *) mimo_error "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

mimo_preflight || exit 1

cd "$MIMOCODE_REPO"
UPSTREAM_REF="upstream/main"
LOCAL_SHA="$(git rev-parse HEAD)"
BASE_SHA="$(git merge-base HEAD "$UPSTREAM_REF" 2>/dev/null || echo "")"

if [[ "$NO_FETCH" != "true" ]]; then
  mimo_info "fetching upstream"
  git fetch upstream --quiet || { mimo_error "git fetch failed"; exit 1; }
fi

if ! git rev-parse --verify "$UPSTREAM_REF" >/dev/null 2>&1; then
  mimo_error "no upstream ref: $UPSTREAM_REF (run without --no-fetch first)"
  exit 1
fi

REMOTE_SHA="$(git rev-parse "$UPSTREAM_REF")"
BASE_SHA="$(git merge-base HEAD "$UPSTREAM_REF")"
BEHIND="$(git rev-list --count "$LOCAL_SHA..$UPSTREAM_REF")"
AHEAD="$(git rev-list --count "$UPSTREAM_REF..$LOCAL_SHA")"
[[ "$BEHIND" -eq 0 ]] && { mimo_info "already up-to-date with upstream ($LOCAL_SHA)"; exit 0; }

REPORT="${REPORT:-$MIMOCODE_LOGS/sync-analysis-$(mimo_ts).md}"
mkdir -p "$(dirname "$REPORT")"

# ---- local customizations (keep-local-first audit list, PATCH-REGISTRY + AGENTS.md) ----
LOCAL_CUSTOM_FILES=(
  "packages/opencode/src/agent/agent.ts"                                  # security primary agent
  "packages/opencode/src/session/prompt/compose.txt"                      # Grill Gate
  "packages/opencode/src/session/prompt/security.txt"                     # security prompt
  "packages/opencode/src/tool/plan.ts"                                    # plan_enter (restored 02680e98)
  "packages/opencode/src/tool/registry.ts"                                # case-insensitive + plan_enter
  "packages/opencode/src/provider/transform.ts"                           # 20MB image cap / dimension cap revert
  "packages/opencode/src/provider/image.ts"                               # image dimension helpers
  "packages/opencode/src/project/project.ts"                              # non-git worktree=directory
  "packages/opencode/src/session/prompt.ts"                               # skill catalog injection (ffbfaa12)
  "packages/opencode/src/session/message-v2.ts"                           # skillCatalogSeen removal
  "packages/opencode/src/session/system.ts"                               # skills() catalog
  "packages/opencode/src/tool/skill-content.ts"                           # GC-resilient render (2e4cce18)
  "packages/opencode/src/skill/search.ts"                                 # aliases exact-match
  "packages/opencode/src/skill/compose/extract.ts"                        # composeSkillsRoot
  "packages/opencode/src/tool/task.ts"                                    # M3 recover
  "packages/opencode/src/tool/actor.ts"                                   # M3 recover + abort-cancel (61c7e9c3)
  "packages/opencode/src/tool/memory.ts"                                  # M3 recover
  "packages/opencode/src/tool/tool.ts"                                    # Def.recover
  "packages/opencode/src/cli/cmd/tui/context/local.tsx"                   # model switch fix
  "packages/opencode/src/cli/cmd/tui/routes/session/index.ts"             # keybind fix
  "scripts/build/build.sh"                                                # lock tripwire
  "scripts/build/deploy.sh"                                               # version-dir GC keep-previous
  "scripts/audit/skill-audit.sh"                                          # audit tooling
  ".npmrc"                                                                # registry pin (19688cff)
)

# ---- collect upstream-changed files ----
UPSTREAM_CHANGED="$(git diff --name-only "$BASE_SHA...$UPSTREAM_REF" 2>/dev/null || git diff --name-only "$BASE_SHA" "$UPSTREAM_REF")"

{
  echo "# Sync analysis $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "Local:  $LOCAL_SHA ($(git rev-parse --abbrev-ref HEAD))"
  echo "Base:   $BASE_SHA"
  echo "Upstream: $UPSTREAM_REF = $REMOTE_SHA"
  echo "Behind: $BEHIND commits | Ahead: $AHEAD commits"
  echo ""

  # ---------------- A. upstream change inventory ----------------
  echo "## A. 更新点分析"
  echo ""
  echo "### commits ($BEHIND)"
  # 提交标题脱敏：%x00 作记录分隔，压平嵌入的多行正文，单行截断 140 字符，最多 60 行
  git log --no-merges --format='%h %s%x00' "$LOCAL_SHA..$UPSTREAM_REF" | tr -d '\n' | tr '\0' '\n' | sed 's/\\n/ /g' | cut -c1-140 | head -60 || true
  echo "（提交标题已脱敏：压平多行正文、截断 140 字符）"
  echo ""
  echo "### 子系统分布（改动文件数）"
  echo "$UPSTREAM_CHANGED" | awk -F/ '{ if (NF>=3) print $1"/"$2"/"$3; else print $0 }' \
    | sort | uniq -c | sort -rn | head -20 || true
  echo ""
  echo "### 回归高发区命中（prompt/overflow/compact/transform/registry/skill）"
  echo "$UPSTREAM_CHANGED" | grep -E "prompt|overflow|compact|transform|registry|skill" \
    || echo "(无命中)"
  echo ""

  # ---------------- B. code-conflict preview ----------------
  echo "## B. 代码冲突点分析（merge-tree 预演，零副作用）"
  echo ""
  MT_RC=0
  MT_OUT="$(git merge-tree --write-tree --name-only "$LOCAL_SHA" "$UPSTREAM_REF" 2>&1)" || MT_RC=$?
  # 冲突路径 = "冲突（内容）：合并冲突于 <path>" / "CONFLICT (content): Merge conflict in <path>"
  MT_CONFLICTS="$(echo "$MT_OUT" | sed -n 's/.*冲突于 //p; s/.*Merge conflict in //p' | sort -u || true)"
  if [[ "$MT_RC" -eq 0 ]]; then
    echo "**预演结果：无冲突**（clean merge）"
  else
    echo "**预演结果：有冲突**（rc=${MT_RC}）"
    echo ""
    echo "### 冲突文件"
    echo "$MT_CONFLICTS" | head -30
    echo ""
    echo "### 冲突文件与本地定制交集（keep-local-first 需人工裁决）"
    HIT=0
    for f in "${LOCAL_CUSTOM_FILES[@]}"; do
      if grep -qx "$f" <<< "$MT_CONFLICTS"; then echo "- **$f**"; HIT=1; fi
    done
    if [[ "$HIT" -eq 0 ]]; then echo "（冲突文件均非本地定制清单内——仍建议人工核对）"; fi
  fi
  echo ""

  # ---------------- C. semantic-conflict evidence ----------------
  echo "## C. 逻辑冲突点分析（证据收集，语义判断留人）"
  echo ""
  echo "### 本地定制文件 × 上游改动交集"
  HIT=0
  for f in "${LOCAL_CUSTOM_FILES[@]}"; do
    if grep -qx "$f" <<< "$UPSTREAM_CHANGED"; then
      echo "- **$f**（上游已改动 → 必须逐 hunk 核对本地定制是否保留）"
      HIT=1
    fi
  done
  if [[ "$HIT" -eq 0 ]]; then echo "(本地定制文件均未被上游改动)"; fi
  echo ""
  echo "### 上游新增/删除文件"
  git diff --diff-filter=D --name-only "$BASE_SHA" "$UPSTREAM_REF" | sed 's/^/- 删: /' | head -20 || true
  git diff --diff-filter=A --name-only "$BASE_SHA" "$UPSTREAM_REF" | sed 's/^/+ 增: /' | head -20 || true
  echo ""
  echo "### 功能链路证据（上游版本关键符号）"
  echo "（依赖类：本地修复/定制依赖它，上游移除=回归风险；规避类：本地已主动移除，上游移除=趋同）"
  DEPEND_SYMS=("plan_enter" "planenter" "providerImageCap" "COMPACTION_BUFFER" "skill_search")
  AVOID_SYMS=("insertReminders" "skillCatalogSeen" "providerImageDimensionCap" "DEFAULT_MAX_IMAGE_DIMENSION")
  UP_PROMPT="$(git show "$UPSTREAM_REF:packages/opencode/src/session/prompt.ts" 2>/dev/null || true)"
  UP_TRANSFORM="$(git show "$UPSTREAM_REF:packages/opencode/src/provider/transform.ts" 2>/dev/null || true)"
  UP_OVERFLOW="$(git show "$UPSTREAM_REF:packages/opencode/src/session/overflow.ts" 2>/dev/null || true)"
  UP_REGISTRY="$(git show "$UPSTREAM_REF:packages/opencode/src/tool/registry.ts" 2>/dev/null || true)"
  UP_SKILL_SEARCH="$(git show "$UPSTREAM_REF:packages/opencode/src/tool/skill-search.ts" 2>/dev/null || true)"
  UP_SKILL_SYS="$(git show "$UPSTREAM_REF:packages/opencode/src/session/system.ts" 2>/dev/null || true)"
  UP_ALL="$UP_PROMPT $UP_TRANSFORM $UP_OVERFLOW $UP_REGISTRY $UP_SKILL_SEARCH $UP_SKILL_SYS"
  for sym in "${DEPEND_SYMS[@]}"; do
    if grep -q "$sym" <<< "$UP_ALL"; then
      echo "- 上游仍含 **$sym**（本地依赖 → 保持）"
    else
      echo "- ⚠️ 上游已无 **$sym**（本地修复依赖它 → **回归风险**）"
    fi
  done
  for sym in "${AVOID_SYMS[@]}"; do
    if grep -q "$sym" <<< "$UP_ALL"; then
      echo "- 上游仍含 **$sym**（本地已弃用 → 若上游行为回归需警惕）"
    else
      echo "- 上游已无 **$sym**（本地已弃用 → 趋同，无风险）"
    fi
  done
  echo ""

  # ---------------- D. performance/behavior impact evidence ----------------
  echo "## D. 性能与表现影响评估（证据收集）"
  echo ""
  echo "### 上下文注入位置（系统提示词 vs per-message）"
  if grep -q "insertReminders\|skillCatalogSeen" <<< "$UP_PROMPT"; then
    echo "- **上游含 per-message 技能目录注入**（insertReminders/skillCatalogSeen）→ 每轮重注入 + cache 打爆风险（96371cae 回归 1 同款），需重点评估"
  else
    echo "- 上游无 per-message catalog 注入"
  fi
  echo ""
  echo "### 溢出/压缩参数（上游 vs 本地）"
  UP_BUF="$(git show "$UPSTREAM_REF:packages/opencode/src/session/overflow.ts" 2>/dev/null | grep -o "COMPACTION_BUFFER *= *[0-9]*" | head -1)"
  LO_BUF="$(grep -o "COMPACTION_BUFFER *= *[0-9]*" packages/opencode/src/session/overflow.ts 2>/dev/null | head -1)"
  echo "- 上游: ${UP_BUF:-n/a} | 本地: ${LO_BUF:-n/a}"
  echo ""
  echo "### 图片处理（上游）"
  git show "$UPSTREAM_REF:packages/opencode/src/provider/transform.ts" 2>/dev/null | grep -n "2000\|DimensionCap" | head -5 || echo "- 上游无图片维度上限逻辑"
  echo ""
  echo "### 提示词体积（上游 txt 行数）"
  for f in default.txt compose.txt security.txt build.txt deepseek.txt glm.txt gpt.txt minimax.txt anthropic.txt; do
    n="$(git show "$UPSTREAM_REF:packages/opencode/src/session/prompt/$f" 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "$n" != "0" ]]; then echo "- $f: $n 行"; fi
  done
  echo ""
  echo "### 工具面规模（上游 registry Tool.init 计数）"
  git show "$UPSTREAM_REF:packages/opencode/src/tool/registry.ts" 2>/dev/null | grep -c "Tool.init" | sed 's/^/- 上游 registry Tool.init: /' || echo "- 上游 registry 读取失败"
  echo ""

  # ---------------- §9.1 regression re-checks (current tree) ----------------
  echo "## 回归复查（BUILD-DEPLOY-RELEASE-SOP §9.1，当前工作树）"
  echo ""
  echo "### 1. 技能目录注入位置"
  # ffbfaa12 删的是 per-message catalog 注入：insertReminders 函数本身仍存在
  #（compose/security/mention 等用途），特征是 skillCatalogSeen 去重与 catalogText 构造
  if grep -rn "skillCatalogSeen\|catalogText" packages/opencode/src/session/ 2>/dev/null | grep -qv "skill-catalog.ts"; then
    echo "- ⚠️ 检出 per-message catalog 注入残留："
    grep -rn "skillCatalogSeen\|catalogText" packages/opencode/src/session/ 2>/dev/null | grep -v "skill-catalog.ts" | head -5
  else
    echo "- ✅ 无 per-message catalog 注入（ffbfaa12 修复在位）"
  fi
  echo ""
  echo "### 2. plan_enter 注册 + 权限"
  for f in packages/opencode/src/tool/registry.ts packages/opencode/src/agent/agent.ts packages/opencode/src/cli/cmd/run.ts; do
    if grep -q "plan_enter\|planenter" "$f" 2>/dev/null; then echo "- ✅ $f 含 plan_enter"; else echo "- ❌ $f 缺 plan_enter（02680e98 修复丢失）"; fi
  done
  echo ""
  echo "### 3. 图片维度上限"
  # 2a38cc05 修复在位 ⟺ ①非注释代码无 2000px 限制 ②providerImageDimensionCap 恒返回 Infinity
  NON_COMMENT_2000="$(grep -n "2000" packages/opencode/src/provider/transform.ts 2>/dev/null | grep -v "^\s*[0-9]*:\s*//" | grep -v "Fork" || true)"
  CAP_IS_INFINITY="$(grep -A3 "function providerImageDimensionCap" packages/opencode/src/provider/transform.ts 2>/dev/null | grep -c "Infinity" || true)"
  if [[ -n "$NON_COMMENT_2000" ]]; then
    echo "- ⚠️ transform.ts 检出 2000px 维度上限（2a38cc05 修复丢失）："
    echo "$NON_COMMENT_2000" | head -5
  elif [[ "$CAP_IS_INFINITY" -eq 0 ]]; then
    echo "- ⚠️ providerImageDimensionCap 未恒返回 Infinity（2a38cc05 修复丢失）"
  else
    echo "- ✅ transform.ts 无 2000px 维度上限（2a38cc05 修复在位）"
  fi
  echo ""
  echo "---"
  echo "Generated by sync-analyze.sh（只读分析，未 merge/未 build）"
} > "$REPORT"

mimo_info "report written: $REPORT"
CONFLICT_N="$(grep -c '预演结果：有冲突' "$REPORT" 2>/dev/null || true)"
mimo_info "behind=$BEHIND ahead=$AHEAD | 预演冲突: ${CONFLICT_N:-0} | 复查: $(grep -c '✅' "$REPORT" 2>/dev/null || echo 0)/3 ✅"
