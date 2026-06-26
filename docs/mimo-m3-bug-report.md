# Bug Report: M3 model stringifies nested `operation` envelope for tools with `discriminatedUnion` schema

## Summary

When **M3 (MiniMax-M3)** is the primary agent and emits a tool call for a tool whose
`parameters` schema is a `z.strictObject({ operation: z.discriminatedUnion("action", [...]) })`
(e.g. `task`, `actor`, any future tool with the same shape), the model **stringifies
the entire `operation` envelope as a JSON string** rather than nesting an object. The
harness then fails to zod-parse the call. Affected tool calls surface to the user as:

```
⚙ invalid [tool=task, error=Invalid input for tool task: JSON parsing failed:
{"operation":{"action":"create","summary":"..."}}]
<]minimax[": "[
... more truncated invocations ...
... Unexpected EOF]
```

The downstream effect is that any primary agent configured as M3 (default in
`compose` mode and increasingly in custom setups) cannot reliably use `task`,
`actor`, or any tool with the same schema shape. This blocks the entire
specs-driven compose workflow.

## The M3-specific mutation

The same class of bug is already documented in
`packages/opencode/src/tool/task.ts` line 99-105 as a known defect for
`mimo-v2.5-pro`:

```typescript
// .meta({ type: "object" }) is REQUIRED — without it, the emitted JSON
// schema's `operation` node has only `anyOf`, no `type`. Some models
// (notably mimo-v2.5-pro) then stringify the entire envelope, producing
// {"operation":"{\"action\":\"create\",...}"} which fails zod validation.
// See research-tool-call-schema/REPORT.md §2.5 "success-nested" warning.
```

The `meta({ type: "object" })` annotation was added to `task` and `actor` to
mitigate this for those two tools. **M3 exhibits the identical bug**, and the
mitigation does not fully cover it because:

1. **M3 stringifies even when `type: "object"` IS present.** Empirically, even
   with the annotation, M3 produces:
   - `{operation: "{action:\"create\",summary:\"x\"}"}` (stringified, with bare keys)
   - Or wrapped in `<|object_ref_start|>minimax<|object_ref_end|>` markers
   - Output truncated mid-stream when the payload exceeds M3's per-call budget

2. **The bug is probabilistic.** Sometimes the call works. Sometimes the
   zod-parse fails. There's no clean error message — the agent just gets
   `JSON Parse error: Unexpected EOF` and either re-tries with a degraded
   payload or abandons the operation.

3. **M3's `operation` value is sometimes already a properly-nested object**
   `{operation: {action: "list"}}` that the harness also fails to parse on
   a *different* code path (the e2e test reproduced this 3 times in a row
   for `task list` / `task get` / `task abandon`).

## Steps to reproduce

1. Configure `mimocode.json` with M3 as the primary agent for **any** mode:
   ```json
   "agent": {
     "compose": {
       "mode": "primary",
       "model": "anthropic-proxy/minimax/MiniMax-M3",
       "tool_allowlist": ["read", "actor", "task", "glob", "grep", "write", "edit", "bash", "skill", "webfetch", "todowrite"]
     }
   }
   ```
2. Run a session: `mimo run --agent compose --format json --title "repro" "<a request that requires a task tree>"`
3. Observe the JSONL event stream. Within the first 3-5 tool invocations,
   at least one `task` or `actor` call will fail with the truncated-JSON
   error pattern.

A working repro script:
```bash
cd /tmp && mkdir m3-repro && cd m3-repro
timeout 60 mimo run --agent compose --format json \
  --title 'm3-task-repro' \
  'Create 5 tasks: T1..T5, each a 1-sentence summary of: "find the bug",
  "fix the bug", "test the fix", "review the fix", "merge".' \
  2>&1 | grep -E '"tool":"task"|Invalid input' | head -20
```

## Expected behavior

M3 should emit `{operation: {action: "create", summary: "..."}}` and the call
should be parsed and executed.

## Actual behavior

M3 emits a stringified, sometimes marker-wrapped, sometimes truncated envelope.
The harness's zod schema rejects the call. The agent sees a generic
`JSON Parse error: Unexpected EOF` and either retries with a degraded payload
or abandons.

## Root cause analysis

`packages/opencode/src/tool/task.ts:111-130` defines the parameters schema:
```typescript
const parameters = z.strictObject({
  operation: z
    .discriminatedUnion("action", [
      createOperation, listOperation, getOperation, ...
    ])
    .meta({ type: "object" }),
})
```

The `meta({ type: "object" })` annotation is necessary but not sufficient for
M3. Three things go wrong:

### 1. JSON Schema `anyOf` is ambiguous to M3

The `discriminatedUnion("action", ...)` emits a JSON schema with `anyOf` for
the action variants. M3's schema emitter does not propagate the `type: "object"`
hint down into the `anyOf` children, so M3 falls back to "the simplest
serialization I can think of" and produces a JSON string of the envelope
rather than a nested object.

### 2. M3 uses custom `<|object_ref_start|>minimax<|object_ref_end|>` markers

When M3's tool-call output exceeds a certain token budget, the harness
intercepts it and wraps JSON in custom markers. These markers are not valid
JSON. `JSON.parse` throws on the wrapped string. The truncated output we
observe in user logs is the model's tool-call content being cut off at the
markers.

### 3. The `anyOf` discriminator is not picked up consistently

For nested-object `operation` envelopes (the case where M3 does emit a
correct object, just with a different action verb), the harness's second
internal code path (used for `task list` / `task get` / `task abandon` per
the e2e test) parses them incorrectly. We suspect there's a second `parse`
call somewhere in the message-handling pipeline that doesn't go through the
same `wrap()` validation path.

## Proposed upstream fix

This is the schema-emitter problem at root, not a model-fix-on-the-client
problem. We strongly recommend:

### A. In `packages/opencode/src/tool/task.ts` (and any other tool using the
discriminatedUnion shape)

Replace the discriminated union with a single `z.object({...})` having an
explicit `action` enum field, then have `execute()` do the dispatch. The
current `discriminatedUnion` shape is JSON-Schema-unfriendly and any model
that has trouble with `anyOf` will hit this bug.

### B. In `packages/opencode/src/session/prompt.ts`

Strip `<|object_ref_start|>minimax<|object_ref_end|>` markers (and any
similar custom model tags) from tool-call input **before** validation.
Currently the markers reach the JSON parser, which throws.

### C. In `packages/opencode/src/tool/registry.ts`

Audit every tool that uses `discriminatedUnion` for its `parameters` — make
sure they all have `.meta({ type: "object" })` on the top-level AND on the
discriminated union itself, and that the generated JSON Schema does not
contain `anyOf` at the top level (where M3 will fall back to stringification).

## Workaround used locally (we are NOT asking the mimo team to merge this)

For the record, we patched locally at:
- `packages/opencode/src/tool/tool.ts` — added `recover?(rawArgs)` field on
  `Def`; `wrap()` retries zod parse once with `recover(args)` if the first
  parse fails.
- `packages/opencode/src/tool/task.ts` / `actor.ts` — `recoverTaskArgs`
  / `recoverActorArgs` strip the `<|object_ref_start|>` markers and apply
  a `looseJsonParse` (regex-quote bare keys, then regex-quote unquoted
  string values, skipping primitives) to recover M3's stringified output.
- `packages/opencode/src/tool/memory.ts` — added the same
  `.meta({ type: "object" })` annotation that `task.ts` and `actor.ts`
  have. (Previously missed; this caused `memory` to also fail on M3.)
- `packages/opencode/src/cli/cmd/tui/routes/session/index.tsx` — wired
  `messages_page_up` and `messages_page_down` to `scroll.scrollBy(±scroll.height)`
  in the session view's useKeyboard block. (Previously the keybinds were
  registered but no listener existed, so pageup/pagedown did nothing
  in the session view.)

These patches unblock our local development but are band-aids; the right
fix is to make the schema emitter produce M3-friendly shapes natively.

## Environment

- mimo version: 0.1.3 (binary built from `94f9582`)
- M3 model version: `anthropic-proxy/minimax/MiniMax-M3` (1M context)
- OS: macOS 15.5 (M4 Pro, arm64)
- Affected tools: `task`, `actor`, `memory`, and any tool with
  `discriminatedUnion` in its parameters

## Severity

**High.** Any user who configures M3 as their primary agent (the default
for `compose` mode in `mimocode.json`) cannot reliably run any specs-driven
workflow. The compose operating model is effectively unusable on M3 without
the local patches described above.
