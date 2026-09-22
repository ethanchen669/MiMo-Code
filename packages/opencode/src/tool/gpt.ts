import { Flag } from "@/flag/flag"

export function isGPTModel(...values: Array<string | undefined>) {
  const ids = values.flatMap((value) => (value ? [value.toLowerCase()] : []))
  if (ids.some((id) => id.includes("gpt-oss"))) return false
  return ids.some((id) => id.includes("gpt"))
}

export function isMcpToolSearchEnabled(enabled: boolean, ...modelIDs: Array<string | undefined>) {
  return Flag.MIMOCODE_CODEX_MODE || enabled || isGPTModel(...modelIDs) || usesMimoCodexMode(...modelIDs)
}

export function usesMimoCodexMode(...values: Array<string | undefined>) {
  const ids = values.flatMap((value) => (value ? [value.toLowerCase()] : []))
  if (ids.some((id) => /(?:^|[/])mimo-v2\.5(?:-pro)?$/.test(id))) return false
  // mimo-x (preview) families degrade under the Codex toolset: given the long
  // `exec` script-orchestration description they emit the call as plain text or
  // empty `{}` arguments instead of a structured function call. They handle the
  // standard toolset (bash/read/write/...) correctly over the Responses API, so
  // keep them off Codex mode.
  if (ids.some((id) => /(?:^|[/_-])mimo-x(?:$|[/_.-])/.test(id))) return false
  return ids.some((id) => /(?:^|[/_-])mimo(?:$|[/_.-])/.test(id))
}

export function usesGPTToolset(modelID: string) {
  return (
    Flag.MIMOCODE_CODEX_MODE ||
    (modelID.includes("gpt-") && !modelID.includes("oss") && !modelID.includes("gpt-4")) ||
    usesMimoCodexMode(modelID)
  )
}
