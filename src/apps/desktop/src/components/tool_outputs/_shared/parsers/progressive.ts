import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'
import { prettyJsonOrRaw, readParametersField } from '../toolOutputParser'

// ─── progressive tools (search_tool / view_tool / use_tool) ────────────────── Universal
// `<ProgressiveTool>` card: the three agent tools that let the model browse a catalog of
// not-yet-enabled tools and equip one for the session.
export interface ProgressiveCatalogEntry {
  name: string
  kind: string
  server: string
  equipped: string
  summary: string
}

export interface ParsedSearchTool {
  query: string
  server: string | null
  count: number
  total: number
  tools: ProgressiveCatalogEntry[]
  truncated: boolean
  hint: string | null
  success: boolean
  error: string | null
}

export interface ParsedViewTool {
  name: string
  kind: string | null
  server: string | null
  equipped: string | null
  description: string | null
  parameters: string
  prettyParameters: string
  isJsonParameters: boolean
  found: boolean
  note: string | null
  hint: string | null
  suggestions: string[]
  success: boolean
  error: string | null
}

export interface ParsedUseTool {
  name: string
  kind: string | null
  equipped: boolean
  inserted: boolean
  waitNextTurn: boolean
  source: string | null
  parameters: string
  prettyParameters: string
  isJsonParameters: boolean
  note: string | null
  hint: string | null
  suggestions: string[]
  success: boolean
  error: string | null
}

function extractAllNames(o: Record<string, unknown>): string[] {
  const raw = o.did_you_mean ?? o.suggestions
  if (!Array.isArray(raw)) return []
  const out: string[] = []
  for (const item of raw) {
    if (typeof item === 'string') {
      const t = item.trim()
      if (t) out.push(t)
    } else {
      const r = asRecord(item)
      const name = strField(r, 'name').trim()
      if (name) out.push(name)
    }
  }
  return out
}

export function parseSearchTool(data: unknown): ParsedSearchTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      query: strField(o, 'query'),
      server: strOrNullField(o, 'server'),
      count: 0,
      total: 0,
      tools: [],
      truncated: false,
      hint: strOrNullField(o, 'hint'),
      success: false,
      error,
    }
  }
  const tools: ProgressiveCatalogEntry[] = []
  const toolsRaw = Array.isArray(o.tools) ? o.tools : []
  for (const item of toolsRaw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (!name) continue
    tools.push({
      name,
      kind: strField(r, 'kind'),
      server: strField(r, 'server'),
      equipped: strField(r, 'equipped'),
      summary: strField(r, 'summary'),
    })
  }
  return {
    query: strField(o, 'query'),
    server: strOrNullField(o, 'server'),
    count: numOrNullField(o, 'count') ?? tools.length,
    total: numOrNullField(o, 'total') ?? tools.length,
    tools,
    truncated: boolField(o, 'truncated', false),
    hint: strOrNullField(o, 'hint'),
    success: true,
    error: null,
  }
}

export function parseViewTool(data: unknown): ParsedViewTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const foundRaw = o.found
  const found =
    foundRaw === undefined || foundRaw === null
      ? error === null
      : foundRaw !== false && foundRaw !== 'false'
  const rawParams = readParametersField(o)
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: strField(o, 'name'),
    kind: strOrNullField(o, 'kind'),
    server: strOrNullField(o, 'server'),
    equipped: strOrNullField(o, 'equipped'),
    description: strOrNullField(o, 'description'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    found,
    note: strOrNullField(o, 'note'),
    hint: strOrNullField(o, 'hint'),
    suggestions: extractAllNames(o),
    success: error === null,
    error,
  }
}

export function parseUseTool(data: unknown): ParsedUseTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const rawParams = readParametersField(o)
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: strField(o, 'name'),
    kind: strOrNullField(o, 'kind'),
    equipped: boolField(o, 'equipped', false),
    inserted: boolField(o, 'inserted', false),
    waitNextTurn: boolField(o, 'wait_next_turn', false),
    source: strOrNullField(o, 'source'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    note: strOrNullField(o, 'note'),
    hint: strOrNullField(o, 'hint'),
    suggestions: extractAllNames(o),
    success: error === null,
    error,
  }
}
