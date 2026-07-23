import {
  checkPluginCompatibility,
  createPluginEntry,
  isDeprecatedPlugin,
  pluginSource,
  resolvePluginTarget,
  type PluginKind,
  type PluginPackage,
  type PluginSource,
} from "./shared"
import { ConfigPlugin } from "@/config/plugin"
import { InstallationVersion } from "@/installation/version"
import { computeFileHash, verifyIntegrity } from "./integrity"
import { Flag } from "@/flag/flag"
import { Log } from "@/util"
import { fileURLToPath } from "url"
import { existsSync } from "fs"

const log = Log.create({ service: "plugin.loader" })

export namespace PluginLoader {
  // A normalized plugin declaration derived from config before any filesystem or npm work happens.
  export type Plan = {
    spec: string
    options: ConfigPlugin.Options | undefined
    deprecated: boolean
  }

  // A plugin that has been resolved to a concrete target and entrypoint on disk.
  export type Resolved = Plan & {
    source: PluginSource
    target: string
    entry: string
    pkg?: PluginPackage
  }

  // A plugin target we could inspect, but which does not expose the requested kind of entrypoint.
  export type Missing = Plan & {
    source: PluginSource
    target: string
    pkg?: PluginPackage
    message: string
  }

  // A resolved plugin whose module has been imported successfully.
  export type Loaded = Resolved & {
    mod: Record<string, unknown>
  }

  type Candidate = { origin: ConfigPlugin.Origin; plan: Plan }
  type Report = {
    // Called before each attempt so callers can log initial load attempts and retries uniformly.
    start?: (candidate: Candidate, retry: boolean) => void
    // Called when the package exists but does not provide the requested entrypoint.
    missing?: (candidate: Candidate, retry: boolean, message: string, resolved: Missing) => void
    // Called for operational failures such as install, compatibility, or dynamic import errors.
    error?: (
      candidate: Candidate,
      retry: boolean,
      stage: "install" | "entry" | "compatibility" | "load",
      error: unknown,
      resolved?: Resolved,
    ) => void
  }

  // Normalize a config item into the loader's internal representation.
  function plan(item: ConfigPlugin.Spec): Plan {
    const spec = ConfigPlugin.pluginSpecifier(item)
    return { spec, options: ConfigPlugin.pluginOptions(item), deprecated: isDeprecatedPlugin(spec) }
  }

  // Resolve a configured plugin into a concrete entrypoint that can later be imported.
  //
  // The stages here intentionally separate install/target resolution, entrypoint detection,
  // and compatibility checks so callers can report the exact reason a plugin was skipped.
  export async function resolve(
    plan: Plan,
    kind: PluginKind,
  ): Promise<
    | { ok: true; value: Resolved }
    | { ok: false; stage: "missing"; value: Missing }
    | { ok: false; stage: "install" | "entry" | "compatibility"; error: unknown }
  > {
    // First make sure the plugin exists locally, installing npm plugins on demand.
    let target = ""
    try {
      target = await resolvePluginTarget(plan.spec)
    } catch (error) {
      return { ok: false, stage: "install", error }
    }
    if (!target) return { ok: false, stage: "install", error: new Error(`Plugin ${plan.spec} target is empty`) }

    // Then inspect the target for the requested server/tui entrypoint.
    let base
    try {
      base = await createPluginEntry(plan.spec, target, kind)
    } catch (error) {
      return { ok: false, stage: "entry", error }
    }
    if (!base.entry)
      return {
        ok: false,
        stage: "missing",
        value: {
          ...plan,
          source: base.source,
          target: base.target,
          pkg: base.pkg,
          message: `Plugin ${plan.spec} does not expose a ${kind} entrypoint`,
        },
      }

    // npm plugins can declare which opencode versions they support; file plugins are treated
    // as local development code and skip this compatibility gate.
    if (base.source === "npm") {
      try {
        await checkPluginCompatibility(base.target, InstallationVersion, base.pkg)
      } catch (error) {
        return { ok: false, stage: "compatibility", error }
      }
    }
    return { ok: true, value: { ...plan, source: base.source, target: base.target, entry: base.entry, pkg: base.pkg } }
  }

  // Import the resolved module only after all earlier validation has succeeded.
  export async function load(row: Resolved): Promise<{ ok: true; value: Loaded } | { ok: false; error: unknown }> {
    // Verify integrity before importing — prevents runtime plugin replacement
    // attacks where an attacker swaps a plugin file on disk between sessions.
    const integrityCheck = runIntegrityCheck(row.entry)
    if (!integrityCheck.ok) {
      log.warn("plugin integrity check failed, rejecting load", {
        path: row.entry,
        spec: row.spec,
        hash: integrityCheck.hash,
        reason: integrityCheck.reason,
      })
      return { ok: false, error: new Error(`Plugin ${row.spec} integrity check failed: ${integrityCheck.reason}`) }
    }

    let mod
    try {
      mod = await import(row.entry)
    } catch (error) {
      return { ok: false, error }
    }
    if (!mod) return { ok: false, error: new Error(`Plugin ${row.spec} module is empty`) }
    return { ok: true, value: { ...row, mod } }
  }

  /**
   * Run pre-import integrity verification on a plugin file.
   *
   * Computes the SHA-256 hash of the file and compares against a known-good
   * hash when available. On first load the hash is recorded; on subsequent
   * loads a mismatch blocks the import.
   *
   * The check is only meaningful for file:// plugin entries whose underlying
   * file exists at check time — npm/bundled entries cannot be hashed this way
   * and always pass.
   */
  function runIntegrityCheck(entry: string): { ok: true; hash: string } | { ok: false; hash?: string; reason: string } {
    const fsPath = entry.startsWith("file://") ? fileURLToPath(entry) : entry

    // Skip non-file entries (npm packages, bundled code)
    if (!existsSync(fsPath)) return { ok: true, hash: "n/a" }

    let hash: string
    try {
      hash = computeFileHash(fsPath)
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error)
      log.warn("plugin integrity: cannot read file for hashing", { path: fsPath, error: msg })
      return { ok: true, hash: "error" }
    }

    const result = verifyIntegrity(entry)

    if (!result.verified) {
      return { ok: false, hash, reason: "hash_mismatch" }
    }

    return { ok: true, hash }
  }

  // Run one candidate through the full pipeline: resolve, optionally surface a missing entry,
  // import the module, and finally let the caller transform the loaded plugin into any result type.
  async function attempt<R>(
    candidate: Candidate,
    kind: PluginKind,
    retry: boolean,
    finish: ((load: Loaded, origin: ConfigPlugin.Origin, retry: boolean) => Promise<R | undefined>) | undefined,
    missing: ((value: Missing, origin: ConfigPlugin.Origin, retry: boolean) => Promise<R | undefined>) | undefined,
    report: Report | undefined,
  ): Promise<R | undefined> {
    const plan = candidate.plan

    // Deprecated plugin packages are silently ignored because they are now built in.
    if (plan.deprecated) return

    report?.start?.(candidate, retry)

    const resolved = await resolve(plan, kind)
    if (!resolved.ok) {
      if (resolved.stage === "missing") {
        // Missing entrypoints are handled separately so callers can still inspect package metadata,
        // for example to load theme files from a tui plugin package that has no code entrypoint.
        if (missing) {
          const value = await missing(resolved.value, candidate.origin, retry)
          if (value !== undefined) return value
        }
        report?.missing?.(candidate, retry, resolved.value.message, resolved.value)
        return
      }
      report?.error?.(candidate, retry, resolved.stage, resolved.error)
      return
    }

    const loaded = await load(resolved.value)
    if (!loaded.ok) {
      report?.error?.(candidate, retry, "load", loaded.error, resolved.value)
      return
    }

    // The default behavior is to return the successfully loaded plugin as-is, but callers can
    // provide a finisher to adapt the result into a more specific runtime shape.
    if (!finish) return loaded.value as R
    return finish(loaded.value, candidate.origin, retry)
  }

  type Input<R> = {
    items: ConfigPlugin.Origin[]
    kind: PluginKind
    wait?: () => Promise<void>
    finish?: (load: Loaded, origin: ConfigPlugin.Origin, retry: boolean) => Promise<R | undefined>
    missing?: (value: Missing, origin: ConfigPlugin.Origin, retry: boolean) => Promise<R | undefined>
    report?: Report
  }

  // Resolve and load all configured plugins in parallel.
  //
  // If `wait` is provided, file-based plugins that initially failed are retried once after the
  // caller finishes preparing dependencies. This supports local plugins that depend on an install
  // step happening elsewhere before their entrypoint becomes loadable.
  export async function loadExternal<R = Loaded>(input: Input<R>): Promise<R[]> {
    const candidates = input.items.map((origin) => ({ origin, plan: plan(origin.spec) }))
    const list: Array<Promise<R | undefined>> = []
    for (const candidate of candidates) {
      list.push(attempt(candidate, input.kind, false, input.finish, input.missing, input.report))
    }
    const out = await Promise.all(list)
    if (input.wait) {
      let deps: Promise<void> | undefined
      for (let i = 0; i < candidates.length; i++) {
        if (out[i] !== undefined) continue

        // Only local file plugins are retried. npm plugins already attempted installation during
        // the first pass, while file plugins may need the caller's dependency preparation to finish.
        const candidate = candidates[i]
        if (!candidate || pluginSource(candidate.plan.spec) !== "file") continue
        deps ??= input.wait()
        await deps
        out[i] = await attempt(candidate, input.kind, true, input.finish, input.missing, input.report)
      }
    }

    // Drop skipped/failed entries while preserving the successful result order.
    const ready: R[] = []
    for (const item of out) if (item !== undefined) ready.push(item)
    return ready
  }
}
