# Model Fallback Guardrail Preservation Audit (C4/S12)

**Date:** 2026-06-25
**Auditor:** MiMoCode (automated security audit)
**Status:** NO ISSUE FOUND — no automatic model fallback exists

## 1. Threat Hypothesis

When MiMoCode's primary model fails (capacity overload, context overflow, network error,
etc.), the system might silently fall back to a different model that has:
- A smaller context window → guardrail instructions get truncated
- Different instruction-following capability → guardrails ignored
- Different provider → different system message format

## 2. Audit Scope

Files examined:
- `packages/opencode/src/session/llm.ts` — LLM request construction, system prompt, retry
- `packages/opencode/src/session/processor.ts` — Message processor, retry policy, overflow
- `packages/opencode/src/session/retry.ts` — Retry logic and policy
- `packages/opencode/src/session/system.ts` — System prompt (provider-specific)
- `packages/opencode/src/session/prompt.ts` — Main runLoop, system prompt assembly, compaction routing
- `packages/opencode/src/session/compaction.ts` — Context compaction and truncation
- `packages/opencode/src/session/prune.ts` — Tool output pruning
- `packages/opencode/src/session/overflow.ts` — Context window overflow detection
- `packages/opencode/src/session/message-v2.ts` — Message serialization
- `packages/opencode/src/session/instruction.ts` — AGENTS.md/CLAUDE.md instruction loading
- `packages/opencode/src/provider/provider.ts` — Model resolution (including tier fallback)
- `packages/opencode/src/provider/error.ts` — Error parsing (overflow detection)
- `packages/opencode/src/provider/transform.ts` — Message transformation pipeline
- `packages/opencode/src/session/llm-request-prefix.ts` — Prefix (system+tools+inherited messages)

## 3. Current Fallback Mechanism

### 3.1 Two-Level Retry (Same Model)

MiMoCode has **two levels of retry**, both using the **same model**:

**Level 1 — LLM-internal retry** (`llm.ts:732-736`):
```ts
const result = yield* streamWithTelemetry.pipe(
  Effect.retry({
    while: isTransientCapacityError,
    schedule: persistentRetrySchedule,  // 10 retries, exponential backoff
  }),
)
```
Retries on: 429, 5xx, 529, ECONNRESET/EPIPE/ETIMEDOUT, SSE timeout.
Uses `maxRetries: 2` on the AI SDK's internal `streamText()` call.

**Level 2 — Processor-level retry** (`processor.ts:806-819`):
```ts
Effect.retry(
  SessionRetry.policy({
    parse,
    set: (info) => (isMain ? status.set(...) : Effect.void),
  }),
)
```
Retries on: same transient errors. Adds a visible `[retrying attempt #N]` banner.
Uses capped per-attempt delay (max 30s) with retry-after header support.

Both levels retry the **original model** — the model is resolved once at `llm.ts:323-331`
and never changed during retry.

### 3.2 Context Overflow → Compaction (Not Model Switch)

When a context overflow error is detected (`error.ts:8-28`, 12+ regex patterns):
1. Error is parsed as `ContextOverflowError` (`message-v2.ts:1131-1138`)
2. Retry is explicitly **skipped** (`retry.ts:106-107`): `ContextOverflowError` returns `undefined`
3. Processor triggers `needsOverflowHandling` (`processor.ts:748-752`)
4. runLoop routes to `compaction.create()` or `rebuildFromCheckpoint()` (`prompt.ts:3201-3264`)
5. Compaction uses LLM summarization to reduce conversation history, keeping **tail turns** only

### 3.3 Model Group Tier Resolution

`resolveModelRef()` (`provider.ts:1648-1687`) resolves model group names (e.g. `standard`,
`lite`) to concrete models. A `BUILTIN_TIERS` check falls back to `defaultModel()` when
a group is not configured — but this is **upfront resolution**, not a mid-request fallback.

## 4. Guardrail Inventory

The following guardrail instruction blocks exist in the system:

### 4.1 System Prompt Layers

| Layer | Source | Content |
|-------|--------|---------|
| Agent prompt / provider prompt | `llm.ts:252` | Core personality and behavior instructions |
| Custom system | `llm.ts:254` | Per-call system additions (skills, env, instructions) |
| User system | `llm.ts:255-256` | User-specific instructions from last message |
| Memory instructions | `llm.ts:262-288` | Memory system ownership and protocol |
| Plugin transform | `llm.ts:292-296` | `experimental.chat.system.transform` hook |

### 4.2 Environment/Safety Blocks

From `system.ts:58-110`:
- **MiMo identity**: "You are MiMo Code Agent, built by Xiaomi MiMo Team"
- **Language constraint**: "Your response must ALWAYS strictly follow the same major language as the user"
- **Vision-capability block** (non-vision models): Explicit instructions about vision limitations and how to dispatch vision work

### 4.3 User Message Guards

Injected per-turn in `prompt.ts`:
- **Memory recall reminder** (`prompt.ts:2900-2918`): `<system-reminder>` about memory tools
- **Context pressure nudge** (`prompt.ts:3077-3126`): Save-your-work reminder at >70% context
- **Repeated-step nudge** (`prompt.ts:3132-3171`): Loop/stuck detection warning

## 5. How System Prompt Is Never Truncated

### 5.1 System Prompt Building

The system prompt is **built fresh each turn** in `buildSystemArray()` (`llm.ts:240-307`):
1. Selection: `agent.prompt` or `SystemPrompt.provider(model)` (model-specific `.txt`)
2. Append: custom system additions
3. Append: user.system from last user message
4. Collapse: `.join("\n\n")` into a single block

### 5.2 System Prompt Placement

In `llm.ts:382-394`, system messages are prepended to the message array:
```ts
const messages = [
  ...system.map((x) => ({ role: "system", content: x })),
  ...requestMessages,
]
```
The system prompt is always the **FIRST** message sent to the model.

### 5.3 Truncation Targets

| Mechanism | What it truncates | Never touches |
|-----------|------------------|---------------|
| `compaction.ts:select()` | Conversation turns (user/assistant pairs) | System prompt |
| `prune.ts:prune()` | Old tool outputs (compact/trim) | System prompt |
| `overflow.ts` | Lossy compaction (LLM summarization) | System prompt |
| `toModelMessagesEffect()` | Serializes message history only | System prompt |

**The system prompt is NOT part of the message history that gets compacted or pruned.**
It is constructed separately and always sent as the prefix to every request.

## 6. Risk Assessment

**Finding: LOW RISK — no automatic model fallback exists in the current codebase.**

The threat described in C4/S12 does not apply because:

1. **No automatic model switching on failure.** Both retry levels use the same model.
2. **System prompt is immutable across retries.** It's built fresh each turn from the same sources.
3. **System prompt cannot be partially truncated.** Only conversation history and tool outputs are targets of context-reduction mechanisms.
4. **Model-specific system prompts are intentional.** Different providers get different base prompts by design (`system.ts:23-40`), not due to fallback.

The only model-switching scenarios (user-initiated, compaction agent, goal judge) are all intentional and occur at predictable boundaries.

## 7. Edge Case: Manual Model Switch

If a user manually switches to a model with a **smaller context window** during a session:

1. The new model's smaller context window will cause more aggressive compaction
2. **Older conversation turns** may be summarized/lost
3. The **system prompt** (including guardrails) is rebuilt fresh for the new model and sent first
4. The `overflow.ts:usable()` calculation is model-aware (`input.model.limit.context`)

This is correct behavior — guardrails are preserved while conversation history is compacted.

## 8. Recommendations

No code changes are required. The current architecture already protects guardrails:
- System prompt is always atomic and first in the message array
- Retries never change models
- Truncation targets only conversation history and tool outputs
- `DEFAULT_CONTEXT_WINDOW` warning (`provider.ts:1234`) alerts operators when a model's context window is not explicitly configured

For defense-in-depth (future consideration, not required now):
- Consider adding an assertion that `system.length > 0` before building model messages
- Consider logging the system prompt SHA at the start of each request for auditability
