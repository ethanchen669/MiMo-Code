import { NodeFileSystem } from "@effect/platform-node"
import { FetchHttpClient } from "effect/unstable/http"
import { afterEach, describe, expect } from "bun:test"
import { Effect, Fiber, Layer } from "effect"
import { Agent as AgentSvc } from "../../src/agent/agent"
import { Auth } from "../../src/auth"
import { Bus } from "../../src/bus"
import { Command } from "../../src/command"
import { Config } from "../../src/config"
import { LSP } from "../../src/lsp"
import { MCP } from "../../src/mcp"
import { Permission } from "../../src/permission"
import { Plugin } from "../../src/plugin"
import { Provider as ProviderSvc } from "../../src/provider"
import { Env } from "../../src/env"
import { Question } from "../../src/question"
import { Todo } from "../../src/session/todo"
import { Session } from "../../src/session"
import { LLM } from "../../src/session/llm"
import { AppFileSystem } from "@mimo-ai/shared/filesystem"
import { SessionPrune } from "../../src/session/prune"
import { SessionSummary } from "../../src/session/summary"
import { Instruction } from "../../src/session/instruction"
import { SessionProcessor } from "../../src/session/processor"
import { SessionPrompt } from "../../src/session/prompt"
import { SessionRevert } from "../../src/session/revert"
import { SessionRunState } from "../../src/session/run-state"
import { Goal } from "../../src/session/goal"
import { SessionStatus } from "../../src/session/status"
import { Skill } from "../../src/skill"
import { SystemPrompt } from "../../src/session/system"
import { Snapshot } from "../../src/snapshot"
import { ToolRegistry } from "../../src/tool"
import { Truncate } from "../../src/tool"
import { ActorRegistry } from "../../src/actor/registry"
import { ActorWaiter } from "../../src/actor/waiter"
import { Actor } from "../../src/actor/spawn"
import { Worktree } from "../../src/worktree"
import { Memory } from "../../src/memory"
import { History } from "../../src/history"
import { Team } from "../../src/team"
import { SessionCheckpoint } from "../../src/session/checkpoint"
import { SessionCompaction } from "../../src/session/compaction"
import { TaskRegistry } from "../../src/task/registry"
import { defaultLayer as SchedulerDefaultLayer } from "../../src/cron/scheduler"
import { Instance } from "../../src/project/instance"
import * as CrossSpawnSpawner from "../../src/effect/cross-spawn-spawner"
import { Ripgrep } from "../../src/file/ripgrep"
import { Format } from "../../src/format"
import { provideTmpdirServer } from "../fixture/fixture"
import { testEffect } from "../lib/effect"
import { TestLLMServer, reply } from "../lib/llm-server"
import { ModelID, ProviderID } from "../../src/provider/schema"
import { MessageID, PartID, SessionID } from "../../src/session/schema"
import { Inbox } from "../../src/inbox"

afterEach(async () => {
  await Instance.disposeAll()
})

const summary = Layer.succeed(
  SessionSummary.Service,
  SessionSummary.Service.of({
    summarize: () => Effect.void,
    diff: () => Effect.succeed([]),
    computeDiff: () => Effect.succeed([]),
  }),
)

const mcp = Layer.succeed(
  MCP.Service,
  MCP.Service.of({
    status: () => Effect.succeed({}),
    clients: () => Effect.succeed({}),
    tools: () => Effect.succeed({}),
    prompts: () => Effect.succeed({}),
    resources: () => Effect.succeed({}),
    add: () => Effect.succeed({ status: { status: "disabled" as const } }),
    connect: () => Effect.void,
    disconnect: () => Effect.void,
    getPrompt: () => Effect.succeed(undefined),
    readResource: () => Effect.succeed(undefined),
    startAuth: () => Effect.die("unexpected MCP auth in abort-cancel tests"),
    authenticate: () => Effect.die("unexpected MCP auth in abort-cancel tests"),
    finishAuth: () => Effect.die("unexpected MCP auth in abort-cancel tests"),
    removeAuth: () => Effect.void,
    supportsOAuth: () => Effect.succeed(false),
    hasStoredTokens: () => Effect.succeed(false),
    getAuthStatus: () => Effect.succeed("not_authenticated" as const),
  }),
)

const lsp = Layer.succeed(
  LSP.Service,
  LSP.Service.of({
    init: () => Effect.void,
    status: () => Effect.succeed([]),
    hasClients: () => Effect.succeed(false),
    touchFile: () => Effect.void,
    diagnostics: () => Effect.succeed({}),
    hover: () => Effect.succeed(undefined),
    definition: () => Effect.succeed([]),
    references: () => Effect.succeed([]),
    implementation: () => Effect.succeed([]),
    documentSymbol: () => Effect.succeed([]),
    workspaceSymbol: () => Effect.succeed([]),
    prepareCallHierarchy: () => Effect.succeed([]),
    incomingCalls: () => Effect.succeed([]),
    outgoingCalls: () => Effect.succeed([]),
  }),
)

const status = SessionStatus.layer.pipe(Layer.provideMerge(Bus.layer))
const run = SessionRunState.layer.pipe(Layer.provide(status))
const infra = Layer.mergeAll(NodeFileSystem.layer, CrossSpawnSpawner.defaultLayer)

function makeLayer() {
  const deps = Layer.mergeAll(
    Session.defaultLayer,
    Snapshot.defaultLayer,
    LLM.defaultLayer,
    Env.defaultLayer,
    AgentSvc.defaultLayer,
    Command.defaultLayer,
    Permission.defaultLayer,
    Plugin.defaultLayer,
    Config.defaultLayer,
    ProviderSvc.defaultLayer,
    lsp,
    mcp,
    AppFileSystem.defaultLayer,
    status,
  ).pipe(Layer.provideMerge(infra))
  const question = Question.layer.pipe(Layer.provideMerge(deps))
  const todo = Todo.layer.pipe(Layer.provideMerge(deps))
  const checkpoint = SessionCheckpoint.defaultLayer
  const taskRegistry = ActorRegistry.defaultLayer
  const taskWaiter = ActorWaiter.defaultLayer
  const team = Team.defaultLayer
  const registry = ToolRegistry.layer.pipe(
    Layer.provide(Skill.defaultLayer),
    Layer.provide(FetchHttpClient.layer),
    Layer.provide(CrossSpawnSpawner.defaultLayer),
    Layer.provide(Ripgrep.defaultLayer),
    Layer.provide(Format.defaultLayer),
    Layer.provide(taskRegistry),
    Layer.provide(taskWaiter),
    Layer.provide(team),
    Layer.provide(checkpoint),
    Layer.provide(Memory.defaultLayer),
    Layer.provide(History.defaultLayer),
    Layer.provide(TaskRegistry.defaultLayer),
    Layer.provide(SchedulerDefaultLayer),
    Layer.provide(Auth.defaultLayer),
    Layer.provideMerge(todo),
    Layer.provideMerge(question),
    Layer.provideMerge(deps),
  )
  const trunc = Truncate.layer.pipe(Layer.provideMerge(deps))
  const proc = SessionProcessor.layer.pipe(Layer.provide(summary), Layer.provideMerge(deps))
  const prune = SessionPrune.layer.pipe(Layer.provide(checkpoint), Layer.provideMerge(deps))
  const prompt = SessionPrompt.layer.pipe(
    Layer.provide(Goal.defaultLayer),
    Layer.provide(SessionRevert.defaultLayer),
    Layer.provide(summary),
    Layer.provide(checkpoint),
    Layer.provide(SessionCompaction.defaultLayer),
    Layer.provide(team),
    Layer.provide(taskRegistry),
    Layer.provideMerge(run),
    Layer.provideMerge(prune),
    Layer.provideMerge(proc),
    Layer.provideMerge(registry),
    Layer.provideMerge(trunc),
    Layer.provide(Instruction.defaultLayer),
    Layer.provide(SystemPrompt.defaultLayer),
    Layer.provide(Inbox.defaultLayer),
    Layer.provideMerge(deps),
  )
  return Layer.mergeAll(
    TestLLMServer.layer,
    Actor.layer.pipe(
      Layer.provideMerge(prompt),
      Layer.provide(Worktree.defaultLayer),
      Layer.provideMerge(taskRegistry),
      Layer.provide(TaskRegistry.defaultLayer),
      Layer.provide(SchedulerDefaultLayer),
      Layer.provide(Inbox.defaultLayer),
    ),
  ).pipe(Layer.provide(summary))
}

const it = testEffect(makeLayer())

const ref = {
  providerID: ProviderID.make("test"),
  modelID: ModelID.make("test-model"),
}

const cfg = {
  provider: {
    test: {
      name: "Test",
      id: "test",
      env: [],
      npm: "@ai-sdk/openai-compatible",
      models: {
        "test-model": {
          id: "test-model",
          name: "Test Model",
          attachment: false,
          reasoning: false,
          temperature: false,
          tool_call: true,
          release_date: "2025-01-01",
          limit: { context: 100000, output: 10000 },
          cost: { input: 0, output: 0 },
          options: {},
        },
      },
      options: {
        apiKey: "test-key",
        baseURL: "http://localhost:1/v1",
      },
    },
  },
}

function providerCfg(url: string) {
  return {
    ...cfg,
    provider: {
      ...cfg.provider,
      test: {
        ...cfg.provider.test,
        options: {
          ...cfg.provider.test.options,
          baseURL: url,
        },
      },
    },
  }
}

const user = Effect.fn("test.user")(function* (sessionID: SessionID, text: string) {
  const session = yield* Session.Service
  const msg = yield* session.updateMessage({
    id: MessageID.ascending(),
    role: "user",
    sessionID,
    agent: "build",
    model: ref,
    time: { created: Date.now() },
  })
  yield* session.updatePart({
    id: PartID.ascending(),
    messageID: msg.id,
    sessionID,
    type: "text",
    text,
  })
  return msg
})

// Poll the registry until the actor row reaches a terminal (idle) status, or
// the deadline passes. Returns the last observed row.
const awaitActorIdle = Effect.fn("test.awaitActorIdle")(function* (
  sessionID: SessionID,
  actorID: string,
  timeoutMs = 5000,
) {
  const reg = yield* ActorRegistry.Service
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const row = yield* reg.get(sessionID, actorID)
    if (row?.status === "idle") return row
    if (Date.now() >= deadline) return row
    yield* Effect.sleep(50)
  }
})

describe("actor tool abort semantics", () => {
  it.live(
    "aborting a blocking actor run cancels the spawned subagent",
    () =>
      provideTmpdirServer(
        Effect.fnUntraced(function* ({ llm }) {
          const prompt = yield* SessionPrompt.Service
          const sessions = yield* Session.Service
          const reg = yield* ActorRegistry.Service
          const chat = yield* sessions.create({
            title: "Abort run",
            permission: [{ permission: "*", pattern: "*", action: "allow" }],
          })

          // Main reply: the model issues a blocking `actor run` tool call.
          // Subagent reply: hangs forever — the subagent stays busy.
          yield* llm.tool("actor", {
            operation: {
              action: "run",
              description: "long task",
              prompt: "do work",
              subagent_type: "general",
            },
          })
          yield* llm.hang

          yield* user(chat.id, "hello")

          const fiber = yield* prompt.loop({ sessionID: chat.id }).pipe(Effect.forkChild)
          // 1st hit: main model call; 2nd hit: the subagent's own LLM call.
          yield* llm.wait(2)

          // The subagent actor must be registered and running.
          const actors = yield* reg.listBySession(chat.id)
          const sub = actors.find((a) => a.agent === "general")
          expect(sub).toBeDefined()
          if (!sub) return
          expect(sub.status).toBe("running")

          // User abort — the tool call is interrupted mid-flight.
          yield* prompt.cancel(chat.id)
          // Await the loop's termination — the abort surfaces as success
          // (MessageAbortedError path) or an interrupt exit depending on where
          // it lands; termination itself is the precondition.
          yield* Fiber.await(fiber)

          // THE CONTRACT: the aborted dispatch must cancel the actor, not
          // leave it running in the background as a ghost.
          const row = yield* awaitActorIdle(chat.id, sub.actorID)
          expect(row?.status).toBe("idle")
          expect(row?.lastOutcome).toBe("cancelled")
        }),
        { git: true, config: providerCfg },
      ),
    30_000,
  )

  it.live(
    "aborting the parent turn does NOT cancel a background spawn",
    () =>
      provideTmpdirServer(
        Effect.fnUntraced(function* ({ llm }) {
          // Design contrast to the blocking run above: `spawn` is
          // fire-and-forget — the tool returns immediately and the result
          // arrives as a notification later — so a parent abort must leave the
          // background actor running. Guards against the fix overreaching.
          const prompt = yield* SessionPrompt.Service
          const sessions = yield* Session.Service
          const reg = yield* ActorRegistry.Service
          const chat = yield* sessions.create({
            title: "Abort keeps background spawn",
            permission: [{ permission: "*", pattern: "*", action: "allow" }],
          })

          // Deterministic routing: the subagent's FIRST request is uniquely
          // identifiable — exactly one user message, and it is the task text.
          // (The main session's follow-up request ALSO contains "do work" —
          // inside the echoed actor tool-call args — so a naive substring
          // match would misroute.) Hang the subagent's call forever so the
          // background actor stays busy; every other request falls through
          // (call 1 pops the spawn tool call below, call 2 auto-replies
          // "ok"/stop and the main loop ends normally).
          const isSubagentFirstCall = (hit: { body: Record<string, unknown> }) => {
            const msgs = (hit.body.messages ?? []) as Array<{ role: string; content: unknown }>
            const users = msgs.filter((m) => m.role === "user")
            return users.length === 1 && JSON.stringify(users[0]?.content ?? "").includes("do work")
          }
          yield* llm.pushMatch(isSubagentFirstCall, reply().hang())
          yield* llm.tool("actor", {
            operation: {
              action: "spawn",
              description: "background task",
              prompt: "do work",
              subagent_type: "general",
            },
          })

          yield* user(chat.id, "hello")

          const fiber = yield* prompt.loop({ sessionID: chat.id }).pipe(Effect.forkChild)

          // Wait until the background subagent is registered AND running (its
          // hanging LLM call in flight) — no fixed hit-count assumption.
          const running = yield* Effect.gen(function* () {
            const deadline = Date.now() + 5000
            for (;;) {
              const actors = yield* reg.listBySession(chat.id)
              const sub = actors.find((a) => a.agent === "general")
              if (sub?.status === "running") return sub
              if (Date.now() >= deadline) return sub
              yield* Effect.sleep(50)
            }
          })
          expect(running?.status).toBe("running")
          if (!running) return

          yield* prompt.cancel(chat.id)
          yield* Fiber.await(fiber)

          // Grace period: the background actor must STILL be running — the
          // abort was scoped to the parent's turn, not to detached work.
          yield* Effect.sleep(300)
          const row = yield* reg.get(chat.id, running.actorID)
          expect(row?.status).toBe("running")
        }),
        { git: true, config: providerCfg },
      ),
    30_000,
  )
})
