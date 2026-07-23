import { createHash } from "crypto"
import { fileURLToPath } from "url"
import { readFileSync } from "fs"
import { Log } from "@/util"

const log = Log.create({ service: "plugin.integrity" })

/**
 * Registry of known-good hashes keyed by plugin entry path.
 * Loaded from a signed manifest on startup, then updated on first load.
 */
const knownHashes = new Map<string, string>()

export function registerHash(path: string, hash: string) {
  knownHashes.set(path, hash)
}

export function getHash(path: string): string | undefined {
  return knownHashes.get(path)
}

/**
 * Compute the SHA-256 hash of a file.
 * Supports file:// URLs and absolute paths.
 */
export function computeFileHash(filePath: string): string {
  const fsPath = filePath.startsWith("file://") ? fileURLToPath(filePath) : filePath
  const buf = readFileSync(fsPath)
  return createHash("sha256").update(buf).digest("hex")
}

/**
 * Result of an integrity check against a plugin file.
 */
export type IntegrityResult = {
  path: string
  hash: string
  verified: boolean
  reason: "first_load" | "hash_match" | "hash_mismatch" | "no_reference"
}

/**
 * Verify the integrity of a plugin file.
 *
 * On first load: stores the hash and succeeds.
 * On subsequent loads: compares against the stored hash.
 * If a known-good hash was registered via registerHash, it takes precedence.
 */
export function verifyIntegrity(entryPath: string): IntegrityResult {
  const fsPath = entryPath.startsWith("file://") ? fileURLToPath(entryPath) : entryPath
  const hash = computeFileHash(fsPath)
  const expected = knownHashes.get(entryPath)

  if (expected === undefined) {
    // First load: record the hash
    knownHashes.set(entryPath, hash)
    log.info("plugin integrity: first load", { path: fsPath, hash, timestamp: new Date().toISOString() })
    return { path: fsPath, hash, verified: true, reason: "first_load" }
  }

  if (hash === expected) {
    log.info("plugin integrity: verified", { path: fsPath, hash, timestamp: new Date().toISOString() })
    return { path: fsPath, hash, verified: true, reason: "hash_match" }
  }

  log.warn("plugin integrity: MISMATCH — file may have been tampered with", {
    path: fsPath,
    expected: expected,
    actual: hash,
    timestamp: new Date().toISOString(),
  })
  return { path: fsPath, hash, verified: false, reason: "hash_mismatch" }
}
