import { afterEach, describe, expect } from "bun:test"
import { Effect, Layer } from "effect"
import { Instance } from "../../src/project/instance"
import * as CrossSpawnSpawner from "../../src/effect/cross-spawn-spawner"
import { ToolRegistry } from "../../src/tool"
import { provideTmpdirInstance } from "../fixture/fixture"
import { testEffect } from "../lib/effect"

const it = testEffect(Layer.mergeAll(ToolRegistry.defaultLayer, CrossSpawnSpawner.defaultLayer))

afterEach(async () => {
  await Instance.disposeAll()
})

// MiMo-Code keeps plan_enter local-first (see tool/plan.ts) so the model can
// still offer switching into plan mode; upstream's plan_enter removal must not
// silently re-apply on a future merge. This guards against a re-removal.
describe("plan_enter registration", () => {
  it.live("plan_enter is registered while plan_exit still is", () =>
    provideTmpdirInstance(() =>
      Effect.gen(function* () {
        const ids = yield* (yield* ToolRegistry.Service).ids()
        expect(ids).toContain("plan_enter")
        expect(ids).toContain("plan_exit")
      }),
    ),
  )
})
