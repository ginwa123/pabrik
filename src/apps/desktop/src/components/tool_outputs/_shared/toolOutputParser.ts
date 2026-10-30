/** Typed parsers for tool-output JSON `data` payloads. */
export * from './parsers/xml'

export * from './parsers/fileTools'

export * from './parsers/git'

export * from './parsers/shell'

export * from './parsers/search'

export * from './parsers/skills'

export * from './parsers/kanban'

export * from './parsers/media'

export * from './parsers/webSearch'

export * from './parsers/directory'

export * from './parsers/progressive'

export function asRecord(data: unknown): Record<string, unknown> {
  if (typeof data === 'string') {
    const trimmed = data.trim()
    if (trimmed === '') return {}
    try {
      return asRecord(JSON.parse(trimmed))
    } catch {
      return {}
    }
  }
  if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
    return data as Record<string, unknown>
  }
  return {}
}

/** Normalized view of whatever a tool card's `content` prop carries: either the bare `data` object
 * (ChatView's success path) or a full envelope JSON string/object (ChatView's error fallback,
 * `m.content`). Empty or unparseable input yields null data with no error (running state). */
export interface NormalizedToolContent {
  data: unknown
  error: string | null
  success: boolean
}

export function normalizeToolContent(content: unknown): NormalizedToolContent {
  const empty: NormalizedToolContent = { data: null, error: null, success: true }
  if (content === null || content === undefined) return empty
  if (typeof content === 'string') {
    if (content.trim() === '') return empty
    let parsed: unknown
    try {
      parsed = JSON.parse(content)
    } catch {
      return empty
    }
    return normalizeToolContent(parsed)
  }
  if (typeof content === 'object' && !Array.isArray(content)) {
    const o = content as Record<string, unknown>
    if (typeof o.tool === 'string' || (typeof o.success === 'boolean' && 'data' in o)) {
      const success = o.success !== false
      return {
        data: 'data' in o ? o.data : null,
        error: success ? null : typeof o.error === 'string' ? o.error : 'tool failed',
        success,
      }
    }
    return { data: content, error: null, success: true }
  }
  return empty
}

// ─── mcp_* (universal MCP tool) ───────────────────────────────────────────── Any tool whose name
// starts with `mcp_` (e.g. `mcp_graphify_graph_stats`, `mcp_db_query`) renders through the
// universal `<McpTool>` card.
export interface ParsedMcp {
  /** Full registry name (e.g. `mcp_graphify_graph_stats`). */
  toolName: string
  /** Server segment (e.g. `graphify`), or null when the name has no second underscore. */
  server: string | null
  /** Sub-tool segment (e.g. `graph_stats`), or null when unparseable. */
  subTool: string | null
  /** Raw output text (unwrapped from `<data>` when an envelope is present). */
  output: string
  /** JSON-pretty (2-space) when output parses as JSON, else identical to output. */
  prettyOutput: string
  /** True when output parsed as JSON. */
  isJson: boolean
  /** Line count of output (0 for empty). */
  lineCount: number
  /** Byte length of output. */
  byteSize: number
  /** False only when an envelope carries `<success>false</success>`. */
  success: boolean
  /** Error message on failure; null on success. */
  error: string | null
}

export function splitMcpToolName(toolName: string): {
  server: string | null
  subTool: string | null
} {
  const prefix = 'mcp_'
  if (!toolName.startsWith(prefix)) return { server: null, subTool: null }
  const after = toolName.slice(prefix.length)
  if (!after) return { server: null, subTool: null }
  const idx = after.indexOf('_')
  if (idx === -1) return { server: after || null, subTool: null }
  const server = after.slice(0, idx) || null
  const subTool = after.slice(idx + 1) || null
  return { server, subTool }
}

export function parseMcp(toolName: string, data: unknown): ParsedMcp {
  const { server, subTool } = splitMcpToolName(toolName)

  // The MCP `data` payload is the raw server text on success (a string),
  // or an object carrying `error` on failure. A full envelope object is
  // unwrapped one level so error fallbacks keep working.
  let output: string
  let success: boolean
  let error: string | null
  if (typeof data === 'string') {
    success = true
    error = null
    output = data
  } else if (data === null || data === undefined) {
    success = true
    error = null
    output = ''
  } else if (typeof data === 'object' && !Array.isArray(data)) {
    const record = data as Record<string, unknown>
    if (
      typeof record.tool === 'string' ||
      (typeof record.success === 'boolean' && 'data' in record)
    ) {
      const ok = record.success !== false
      if (!ok) {
        success = false
        error = typeof record.error === 'string' ? record.error : 'tool failed'
        output = ''
      } else {
        const inner = record.data
        success = true
        error = null
        output = typeof inner === 'string' ? inner : JSON.stringify(inner ?? '')
      }
    } else if (typeof record.error === 'string') {
      success = false
      error = record.error
      output = typeof record.output === 'string' ? record.output : ''
    } else if (typeof record.output === 'string') {
      success = true
      error = null
      output = record.output
    } else {
      success = true
      error = null
      output = JSON.stringify(data)
    }
  } else {
    success = true
    error = null
    output = String(data)
  }

  let prettyOutput = output
  let isJson = false
  const trimmed = output.trim()
  if (trimmed) {
    try {
      const parsed = JSON.parse(trimmed)
      prettyOutput = JSON.stringify(parsed, null, 2)
      isJson = true
    } catch {
      // Not JSON — show raw.
    }
  }

  return {
    toolName,
    server,
    subTool,
    output,
    prettyOutput,
    isJson,
    lineCount: output ? output.split('\n').length : 0,
    byteSize: output.length,
    success,
    error,
  }
}

/** Read the `parameters` payload: a JSON-schema object, its JSON string, or ''. */
export function readParametersField(o: Record<string, unknown>): string {
  const v = o.parameters
  if (v === null || v === undefined) return ''
  if (typeof v === 'string') return v
  try {
    return JSON.stringify(v)
  } catch {
    return ''
  }
}

export function prettyJsonOrRaw(s: string): { pretty: string; isJson: boolean } {
  const trimmed = s.trim()
  if (!trimmed) return { pretty: '', isJson: false }
  try {
    return { pretty: JSON.stringify(JSON.parse(trimmed), null, 2), isJson: true }
  } catch {
    return { pretty: s, isJson: false }
  }
}

// Re-export shared param helper (single source of truth in helpers/).
export { extractParam } from '../../../helpers/extractParam'
