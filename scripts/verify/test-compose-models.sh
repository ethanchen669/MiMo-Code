#!/usr/bin/env bash
set -euo pipefail

# Usage: test-compose-models.sh <test-dir>
# Runs both M3 and DeepSeek on compose tasks, logs tool calls

TESTDIR="${1:?Usage: test-compose-models.sh <test-dir>}"
CONFIG=~/.config/mimocode/mimocode.json
RESULTS=~/compose-test-results-$(date +%Y%m%d-%H%M%S).log
TIMEOUT=45

echo "=== Compose Model Test ===" | tee "$RESULTS"
echo "Test dir: $TESTDIR" | tee -a "$RESULTS"
echo "Results: $RESULTS" | tee -a "$RESULTS"
echo "" | tee -a "$RESULTS"

# Helper: set compose model
set_compose_model() {
  local model="$1"
  python3 -c "
import json
with open('$CONFIG','r') as f: c=json.load(f)
c['agent']['compose']['model']='$model'
with open('$CONFIG','w') as f: json.dump(c,f,indent=2)
print(f'Set compose model: $model')
"
}

# Helper: run test and extract tool calls
run_test() {
  local model="$1" task="$2" testnum="$3"
  local output
  echo "--- Test $testnum: $task ($model) ---" | tee -a "$RESULTS"
  
  output=$(cd "$TESTDIR" && timeout "$TIMEOUT" ~/.mimocode/bin/mimo run \
    --agent compose \
    --format json \
    "$task" 2>&1 || true)
  
  # Extract tool calls from JSON output
  local tool_calls actor_calls self_writes
  tool_calls=$(echo "$output" | grep -o '"tool_use"' | wc -l | tr -d ' ')
  actor_calls=$(echo "$output" | grep -o 'actor\|run_general\|run_security\|run_tdd\|run_planner' | wc -l | tr -d ' ')
  self_writes=$(echo "$output" | grep -o '"Write"\|"Edit"\|"bash"' | wc -l | tr -d ' ')
  
  # Extract tool names
  local tools
  tools=$(echo "$output" | grep -o '"tool_use".*"name":"[^"]*"' | sed 's/.*"name":"//;s/".*//' | tr '\n' ',' | sed 's/,$//')
  
  echo "  tools: [$tools]" | tee -a "$RESULTS"
  echo "  dispatched: $actor_calls, self-executed: $self_writes" | tee -a "$RESULTS"
  echo "$output" | tail -5 | tee -a "$RESULTS"
  echo "" | tee -a "$RESULTS"
}

# Tasks
declare -a TASKS=(
  "给 src/utils.ts 的 foo 函数重命名为 bar，然后更新所有引用"
  "审计 src/auth.ts 的安全性，找出漏洞"
  "写 src/utils.test.ts 的单元测试"
  "规划一个用户认证功能的完整实现方案"
  "修复 src/auth.ts 里的 bug：密码长度校验应该是 12 而不是 8"
)

# Test M3
set_compose_model "minimax/MiniMax-M3"
echo "=== M3 Tests ===" | tee -a "$RESULTS"
for i in "${!TASKS[@]}"; do
  run_test "minimax/MiniMax-M3" "${TASKS[$i]}" "$((i+1))M3"
done

# Test DeepSeek
set_compose_model "openai-proxy/deepseek/deepseek-v4-pro"
echo "=== DeepSeek Tests ===" | tee -a "$RESULTS"
for i in "${!TASKS[@]}"; do
  run_test "deepseek-v4-pro" "${TASKS[$i]}" "$((i+1))DS"
done

echo "" | tee -a "$RESULTS"
echo "=== Test Complete ===" | tee -a "$RESULTS"
echo "Results: $RESULTS" | tee -a "$RESULTS"
