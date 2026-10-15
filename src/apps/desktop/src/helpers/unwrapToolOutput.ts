/** Parsed parts of the standardized tool result envelope (JSON form).
 * Returned by `unwrapToolOutput` / `tryUnwrapToolOutput`.
 * Wire shape (see docs/superpowers/plans/2026-09-18-agent-tool-output-json-schema.md §1):
 *   {"tool":"read_file","parameters":{...},"success":true,
 *    "data":{...},"error":null,"v":1} */
export interface UnwrappedToolOutput {
  /** Tool name (e.g. "read_file") */
  name: string
  /** Tool arguments re-stringified via JSON.stringify so ToolParameters.vue keeps working */
  parameters: string
  /** Whether the tool succeeded */
  success: boolean
  /** Error message, or null on success */
  error: string | null
  /** Inner tool-specific payload (parsed object) on success, null on error */
  data: unknown
}

/**  * Parse a JSON tool envelope. Throws on malformed input — use `tryUnwrapToolOutput` for a null
 * fallback. Hard cut: legacy `<tool>…</tool>` XML is rejected, never parsed. */
export function unwrapToolOutput(content: string): UnwrappedToolOutput {
  let parsed: unknown
  try {
    parsed = JSON.parse(content)
  } catch {
    throw new Error('MalformedToolEnvelope: content is not valid JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('MalformedToolEnvelope: envelope must be a JSON object')
  }
  const env = parsed as Record<string, unknown>
  if (typeof env.tool !== 'string' || env.tool.length === 0) {
    throw new Error('MalformedToolEnvelope: missing required field (tool|parameters|success)')
  }
  if (typeof env.success !== 'boolean') {
    throw new Error('MalformedToolEnvelope: missing required field (tool|parameters|success)')
  }
  if (env.parameters === undefined) {
    throw new Error('MalformedToolEnvelope: missing required field (tool|parameters|success)')
  }

  let parameters: string
  if (typeof env.parameters === 'string') {
    parameters = env.parameters
  } else {
    try {
      parameters = JSON.stringify(env.parameters ?? {})
    } catch {
      parameters = '{}'
    }
  }

  const success = env.success
  return {
    name: env.tool,
    parameters,
    success,
    error: success
      ? null
      : typeof env.error === 'string'
        ? env.error
        : env.error == null
          ? 'tool failed'
          : String(env.error),
    data: success ? (env.data ?? null) : null,
  }
}

/**
 * Like `unwrapToolOutput` but returns `null` instead of throwing.
 */
export function tryUnwrapToolOutput(content: string): UnwrappedToolOutput | null {
  try {
    return unwrapToolOutput(content)
  } catch {
    return null
  }
}
