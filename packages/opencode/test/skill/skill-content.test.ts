import { describe, expect } from "bun:test"
import { Effect, Layer } from "effect"
import { FetchHttpClient } from "effect/unstable/http"
import os from "os"
import path from "path"
import { Ripgrep } from "../../src/file/ripgrep"
import { renderSkillContent } from "../../src/tool/skill-content"
import * as CrossSpawnSpawner from "../../src/effect/cross-spawn-spawner"
import { testEffect } from "../lib/effect"

const it = testEffect(
  Layer.mergeAll(Ripgrep.defaultLayer, CrossSpawnSpawner.defaultLayer, FetchHttpClient.layer),
)

describe("skill content render", () => {
  it.live(
    "renders a skill whose directory was GC'd mid-session (missing dir) with an empty file list",
    () =>
      Effect.gen(function* () {
        const rg = yield* Ripgrep.Service
        // Simulates a bundled (builtin/compose) skill whose per-version dir was
        // deleted by deploy GC while a session still holds a catalog entry
        // pointing at it. SKILL.md content lives in memory; the render must
        // degrade to an empty file list instead of failing on ripgrep ENOENT.
        const missingDir = path.join(os.tmpdir(), "mimocode-gc-missing-" + Date.now())
        const info = {
          name: "compose:ask",
          description: "stale catalog entry",
          aliases: [],
          location: path.join(missingDir, "SKILL.md"),
          content: "# Ask\n\nQuestion routing content already loaded in memory.",
        }
        const rendered = yield* renderSkillContent(info, rg, AbortSignal.any([]))
        expect(rendered.output).toContain("# Ask")
        expect(rendered.output).toContain("<skill_files>")
        const filesSection = rendered.output.split("<skill_files>")[1].split("</skill_files>")[0]
        expect(filesSection.trim()).toBe("")
      }),
  )
})
