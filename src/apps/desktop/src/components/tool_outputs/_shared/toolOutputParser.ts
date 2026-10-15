/**
 * Typed parsers for tool-output JSON `data` payloads.
 *
 * Each parser takes the envelope's `data` payload as a parsed object (via
 * `normalizeToolContent`, which also unwraps full envelopes and JSON
 * strings), reads fields directly, and gracefully handles missing keys
 * (returns `null` for missing optional fields, sensible defaults for
 * missing required fields where applicable).
 *
 * Parsers are pure functions; safe to call inside `computed`. JSON needs
 * no entity decoding — values arrive byte-exact from `std.json`.
 *
 * The legacy XML helpers (`extractTag`, `extractBool`, `extractInt`,
 * `unescapeXml`) are retained for `helpers/isBackgroundCommandOutput.ts`,
 * the only remaining XML consumer. New code must not use them.
 *
 * Conventions:
 *   - Singular boolean fields default to `false` (absent key = false).
 *   - Optional strings return `null` when missing, not empty string.
 *   - Optional numbers return `null` when missing or unparseable.
 */
/**
 * Decode XML entities produced by the backend's `toXmlSuccess` / `xmlError`.
 * Mirrors `llm_history.zig xmlEscape` (its inverse) exactly. The order matters:
 * `&amp;` MUST be replaced last, otherwise the other replacements would
 * double-decode earlier `&amp;`-prefixed entities (e.g. `&amp;quot;` would
 * incorrectly become `"` instead of `&quot;`).
 *
 * Decodes:
 *   - `&lt;`   → `<`
 *   - `&gt;`   → `>`
 *   - `&quot;` → `"`
 *   - `&apos;` → `'`
 *   - `&amp;`  → `&`   (last)
 */
import { stripAnsiEscapes } from '../../../helpers/stripAnsiEscapes'

export function unescapeXml(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function findTag(content: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = content.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = content.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  return content.slice(valueStart, closeIdx)
}

export function extractTag(content: string, tag: string, _multiline = true): string | null {
  // The `_multiline` flag is preserved for back-compat with the original
  // public signature but is currently a no-op (the implementation already
  // supports multiline inner content via `indexOf` matching the first `<tag>`
  // / `</tag>` pair, which works for both single-line and multi-line
  // bodies). Existing call sites pass only `content` and `tag`.
  const raw = findTag(content, tag)
  if (raw === null) return null
  return unescapeXml(raw)
}

/** Trim helper used by every boolean / number parser. */
function trimTag(text: string | null): string {
  return text === null ? '' : text.trim()
}

/** Parse a boolean tag like <success>true</success>. Defaults to `false`. */
export function extractBool(content: string, tag: string, defaultValue = false): boolean {
  const raw = trimTag(extractTag(content, tag))
  if (raw === '') return defaultValue
  return raw === 'true' || raw === '1'
}

/** Parse an integer tag like <exit_code>0</exit_code>. Returns null on parse failure. */
export function extractInt(content: string, tag: string): number | null {
  const raw = trimTag(extractTag(content, tag))
  if (raw === '') return null
  const n = Number(raw)
  return Number.isFinite(n) ? n : null
}

// ─── JSON data-object helpers ────────────────────────────────────────────── Migrated parsers
// (read_file, shell family, search, ask_user) take the envelope's `data` payload as a parsed object
// and read fields directly — no tag extraction, no entity decoding (JSON needs none).
// The helpers below are lenient by design: a JSON string is parsed, a full envelope object (or its
// JSON string) is unwrapped one level to `.data`, and anything else yields safe defaults so a card
// never throws.
/** Coerce unknown input to a plain record. Unparseable input → {}. */
function asRecord(data: unknown): Record<string, unknown> {
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

/**  * Unwrap one level when the input is a full tool envelope (`{tool, parameters, success, data,
 * error, v}` or its JSON string) instead of the bare `data` payload. Otherwise coerce to a record. */
function unwrapDataRecord(data: unknown): Record<string, unknown> {
  const record = asRecord(data)
  if (
    typeof record.tool === 'string' ||
    (typeof record.success === 'boolean' && 'data' in record)
  ) {
    return asRecord(record.data)
  }
  return record
}

function strField(o: Record<string, unknown>, key: string): string {
  const v = o[key]
  if (typeof v === 'string') return v
  if (v === null || v === undefined) return ''
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

function strOrNullField(o: Record<string, unknown>, key: string): string | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

function numOrNullField(o: Record<string, unknown>, key: string): number | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim())
    return Number.isFinite(n) ? n : null
  }
  return null
}

function boolField(o: Record<string, unknown>, key: string, defaultValue = false): boolean {
  const v = o[key]
  if (v === null || v === undefined) return defaultValue
  if (typeof v === 'boolean') return v
  if (typeof v === 'string') {
    const t = v.trim()
    if (t === '') return defaultValue
    return t === 'true' || t === '1'
  }
  if (typeof v === 'number') return v !== 0
  return defaultValue
}

/**  * Normalized view of whatever a tool card's `content` prop carries: either the bare `data` object
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

export interface ParsedTextReplace {
  path: string
  before: string
  after: string
  unified: string
  linesChanged: number
  success: boolean
  error: string | null
}

export function parseTextReplace(data: unknown): ParsedTextReplace {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const success = error === null
  return {
    path: strField(o, 'path'),
    before: strOrNullField(o, 'before') ?? strOrNullField(o, 'old_str') ?? '',
    after: strOrNullField(o, 'after') ?? strOrNullField(o, 'new_str') ?? '',
    unified: strOrNullField(o, 'unified') ?? '',
    linesChanged: numOrNullField(o, 'lines_changed') ?? 0,
    success,
    error,
  }
}

export interface ParsedReadFile {
  path: string
  content: string
  totalLines: number | null
  startLine: number | null
  endLine: number | null
  success: boolean
  error: string | null
}

export function parseReadFile(data: unknown): ParsedReadFile {
  const o = unwrapDataRecord(data)
  const success = boolField(o, 'success', true)
  return {
    path: strField(o, 'path'),
    content: strField(o, 'content'),
    totalLines: numOrNullField(o, 'total_lines'),
    startLine: numOrNullField(o, 'start_line'),
    endLine: numOrNullField(o, 'end_line'),
    success,
    error: success ? null : strOrNullField(o, 'error'),
  }
}

export interface ParsedWriteFile {
  path: string
  success: boolean
  error: string | null
}

export function parseWriteFile(data: unknown): ParsedWriteFile {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const success = error === null
  return {
    path: strOrNullField(o, 'file_write') ?? strField(o, 'path'),
    success,
    error,
  }
}

/** The name a skill tool acted on. `skill_name` is the canonical field on every skill tool payload;
 * `name` is the echo of what was requested and is absent from some rows. */
/** An EMPTY `skill_name` counts as absent rather than winning — it would otherwise render a card
 * whose only label is blank, and `??` alone would not catch it because `''` is neither null nor
 * undefined. */
function skillNameField(o: Record<string, unknown>): string {
  const primary = strOrNullField(o, 'skill_name')
  if (primary !== null && primary.trim() !== '') return primary
  return strField(o, 'name')
}

export interface ParsedRemoveFile {
  path: string
  deleted: boolean
  recursive: boolean
  success: boolean
  error: string | null
}

export function parseRemoveFile(data: unknown): ParsedRemoveFile {
  const o = unwrapDataRecord(data)
  const deleted = boolField(o, 'deleted', false)
  const recursive = boolField(o, 'recursive', false)
  const error = strOrNullField(o, 'error')
  return {
    path: strField(o, 'path'),
    deleted,
    recursive,
    success: error === null && (deleted || !('deleted' in o)),
    error,
  }
}

export interface ParsedEditSkill {
  skillName: string
  edited: boolean
  success: boolean
  error: string | null
}

export function parseEditSkill(data: unknown): ParsedEditSkill {
  const o = unwrapDataRecord(data)
  const edited = boolField(o, 'edited', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    edited,
    success: error === null,
    error,
  }
}

export interface ParsedAddSkill {
  skillName: string
  created: boolean
  success: boolean
  error: string | null
}

export function parseAddSkill(data: unknown): ParsedAddSkill {
  const o = unwrapDataRecord(data)
  const created = boolField(o, 'created', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    created,
    success: error === null,
    error,
  }
}

export interface ParsedRemoveSkill {
  skillName: string
  removed: boolean
  success: boolean
  error: string | null
}

export function parseRemoveSkill(data: unknown): ParsedRemoveSkill {
  const o = unwrapDataRecord(data)
  const removed = boolField(o, 'removed', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    removed,
    success: error === null,
    error,
  }
}

export interface ParsedSetGitWorktree {
  path: string | null
  branch: string | null
  cleared: boolean
  created: boolean
  success: boolean
  error: string | null
}

export function parseSetGitWorktree(data: unknown): ParsedSetGitWorktree {
  const o = unwrapDataRecord(data)
  const cleared = boolField(o, 'cleared', false)
  const created = boolField(o, 'created', false)
  const error = strOrNullField(o, 'error')
  return {
    path: strOrNullField(o, 'path'),
    branch: strOrNullField(o, 'branch'),
    cleared,
    created,
    success: error === null,
    error,
  }
}

/**
 * `set_pull_request` result — attach-only, so the payload is one of exactly
 * two shapes (`src/modules/agent/tools/set_pull_request.zig`):
 *
 *   attach: {session_id, attached:true, url, provider, number|null,
 *            verified, warning|null, base|null, head|null}
 *   clear:  {session_id, cleared:true}
 *
 * `number` arrives as a STRING in the wire payload (the backend keeps it a
 * `[]const u8` because clones/forks carry non-numeric IIDs), so it is read
 * as an optional string and never coerced to a number.
 */
export interface ParsedSetPullRequest {
  url: string | null
  provider: string | null
  number: string | null
  attached: boolean
  cleared: boolean
  verified: boolean
  /** Non-fatal note from the attach (e.g. the forge CLI was missing). */
  warning: string | null
  base: string | null
  head: string | null
  sessionId: string | null
  success: boolean
  error: string | null
}

export function parseSetPullRequest(data: unknown): ParsedSetPullRequest {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  return {
    url: strOrNullField(o, 'url'),
    provider: strOrNullField(o, 'provider'),
    number: strOrNullField(o, 'number'),
    attached: boolField(o, 'attached', false),
    cleared: boolField(o, 'cleared', false),
    verified: boolField(o, 'verified', false),
    warning: strOrNullField(o, 'warning'),
    base: strOrNullField(o, 'base'),
    head: strOrNullField(o, 'head'),
    sessionId: strOrNullField(o, 'session_id'),
    success: error === null,
    error,
  }
}

export interface ParsedBash {
  command: string | null
  stdout: string
  stderr: string
  exitCode: number | null
  truncated: boolean
  timedOut: boolean
  stdoutLines: number
  stderrLines: number
}

export function parseBash(data: unknown): ParsedBash {
  const o = unwrapDataRecord(data)
  return {
    command: strOrNullField(o, 'command'),
    // Second, independent escape guard at the parse seam. The backend strips in
    // shell.result_to_json; this covers live/partial payloads and any future raw-bytes producer.
    // It deliberately does NOT try to repair pre-fix rows — see helpers/stripAnsiEscapes.ts on why
    // those are unrecoverable rather than heuristically "fixed".
    stdout: stripAnsiEscapes(strField(o, 'stdout')),
    stderr: stripAnsiEscapes(strField(o, 'stderr')),
    exitCode: numOrNullField(o, 'exit_code'),
    truncated: boolField(o, 'truncated', false),
    timedOut: boolField(o, 'timeout', false),
    stdoutLines: numOrNullField(o, 'stdout_lines') ?? 0,
    stderrLines: numOrNullField(o, 'stderr_lines') ?? 0,
  }
}

/** Parse a pwsh (PowerShell Core) tool result. Same JSON `data` shape as bash — per plan D2 + D10
 * the schema is structurally identical, only the `tool` field that wraps the envelope differs. */
/** Functionally a clone of `parseBash` so future divergence (e.g. pwsh adds a `version` field for
 * the PowerShell version that ran) is a one-line change here. Tests in `toolOutputParser.spec.ts`
 * assert `parsePwsh(x) === parseBash(x)` to catch accidental drift. */
export function parsePwsh(data: unknown): ParsedBash {
  return parseBash(data)
}

/** Parse a `command` (unified shell) tool result. */
/** Same JSON `data` shape as bash — the unified `command` tool reuses the identical 8-field payload
 * (`command`/`stdout`/`stderr`/`exit_code`/`truncated`/`timeout`/ `stdout_lines`/`stderr_lines`),
 * only the `tool` wrapper differs. */
/** Functionally an alias of `parseBash` so future payload divergence is a one-line change here.
 * Tests assert `parseCommand(x) === parseBash(x)` to catch accidental drift. `parseBash` /
 * `parsePwsh` are intentionally left untouched. */
export function parseCommand(data: unknown): ParsedBash {
  return parseBash(data)
}

/**  * Dispatcher: parse a tool result based on the `toolName` it was registered under. 'bash' / 'pwsh'
 * / 'run_command' (legacy alias) / 'command' (unified shell) all use the same payload. New shells
 * with divergent payload shapes must add their own branch here. */
export function parseShell(toolName: string, data: unknown): ParsedBash {
  switch (toolName) {
    case 'bash':
      return parseBash(data)
    case 'pwsh':
      return parsePwsh(data)
    case 'run_command':
      return parseBash(data)
    case 'command':
      return parseCommand(data)
    default:
      return parseBash(data)
  }
}

export interface FileResult {
  path: string
  total: number
  count: number
  matches: Array<{ lineNumber: number; snippet: string }>
}

export interface ParsedSearch {
  pattern: string | null
  path: string | null
  warning: string | null
  error: string | null
  fileResults: FileResult[]
  success: boolean
  returned: number | null
  total: number | null
  truncated: boolean
  outputTruncated: boolean
  truncatedHint: string | null
}

export function parseSearch(data: unknown): ParsedSearch {
  const o = unwrapDataRecord(data)
  const filesRaw = Array.isArray(o.files) ? o.files : []
  const fileResults: FileResult[] = filesRaw.map((f) => {
    const fr = asRecord(f)
    const matchesRaw = Array.isArray(fr.matches) ? fr.matches : []
    return {
      path: strField(fr, 'path'),
      total: numOrNullField(fr, 'total') ?? 0,
      count: numOrNullField(fr, 'count') ?? 0,
      matches: matchesRaw.map((m) => {
        const mr = asRecord(m)
        return {
          lineNumber: numOrNullField(mr, 'line') ?? 0,
          snippet: strField(mr, 'text'),
        }
      }),
    }
  })
  return {
    pattern: strOrNullField(o, 'pattern'),
    path: strOrNullField(o, 'path'),
    warning: strOrNullField(o, 'warning'),
    error: null,
    fileResults,
    success: true,
    returned: numOrNullField(o, 'returned'),
    total: numOrNullField(o, 'total'),
    truncated: boolField(o, 'truncated', false),
    outputTruncated: boolField(o, 'output_truncated', false),
    truncatedHint: strOrNullField(o, 'truncated_hint'),
  }
}

/** One row of a `search_skills` page. Identity is the name ALONE: the page is one workspace's
 * skills, so there is no tier to tag and no path to hand back. */
/** A row that arrived with the old `scope` / `path` keys still parses — the extra keys are simply
 * not read, which keeps a cached transcript from rendering blank rows. */
export interface SkillSearchRow {
  name: string
  description: string
}

/**
 * `search_skills` result. Mirrors `ParsedSearchTool` field-for-field
 * (`query` / `count` / `total` / `truncated` / `hint`) so the two catalog
 * cards share one paging convention, plus the paging and pattern fields
 * `search_tool` has no use for (`pattern_mode` / `pattern_warning` /
 * `offset` / `limit` / `next_offset`).
 *
 * There is no `scope`. The row set is already one workspace's, and a name
 * is unique inside a workspace, so a scope could only ever have been a
 * second, redundant key.
 */
export interface ParsedSearchSkills {
  query: string
  patternMode: string | null
  patternWarning: string | null
  count: number
  total: number
  offset: number | null
  limit: number | null
  skills: SkillSearchRow[]
  truncated: boolean
  nextOffset: number | null
  hint: string | null
}

function parseSkillRecord(item: unknown): SkillSearchRow | null {
  const r = asRecord(item)
  const name = strField(r, 'name')
  if (!name) return null
  return {
    name,
    description: strField(r, 'description'),
  }
}

export function parseSearchSkills(data: unknown): ParsedSearchSkills {
  const o = unwrapDataRecord(data)
  const skills: SkillSearchRow[] = []
  const skillsRaw = Array.isArray(o.skills) ? o.skills : []
  for (const item of skillsRaw) {
    const row = parseSkillRecord(item)
    if (row) skills.push(row)
  }
  return {
    query: strField(o, 'query'),
    patternMode: strOrNullField(o, 'pattern_mode'),
    patternWarning: strOrNullField(o, 'pattern_warning'),
    count: numOrNullField(o, 'count') ?? skills.length,
    total: numOrNullField(o, 'total') ?? skills.length,
    offset: numOrNullField(o, 'offset'),
    limit: numOrNullField(o, 'limit'),
    skills,
    truncated: boolField(o, 'truncated', false),
    nextOffset: numOrNullField(o, 'next_offset'),
    hint: strOrNullField(o, 'hint'),
  }
}

export interface KanbanListColumn {
  id: string
  name: string
  position: number
  taskCount: number
}

export interface KanbanListTask {
  id: string
  name: string
  columnId: string | null
  columnName: string | null
  position: number
}

export interface ParsedKanbanList {
  workspaceId: string | null
  itemId: string | null
  boardLabel: string | null
  columns: KanbanListColumn[]
  tasks: KanbanListTask[]
  totalCount: number | null
  limit: number | null
  offset: number | null
  hasMore: boolean
  hint: string | null
  error: string | null
  success: boolean
}

export function parseKanbanList(data: unknown): ParsedKanbanList {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      workspaceId: null,
      itemId: null,
      boardLabel: null,
      columns: [],
      tasks: [],
      totalCount: null,
      limit: null,
      offset: null,
      hasMore: false,
      hint: null,
      error,
      success: false,
    }
  }
  const columns: KanbanListColumn[] = []
  const colsRaw = Array.isArray(o.columns) ? o.columns : []
  for (const item of colsRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    columns.push({
      id,
      name: strField(r, 'name'),
      position: numOrNullField(r, 'position') ?? 0,
      taskCount: numOrNullField(r, 'task_count') ?? 0,
    })
  }
  const tasks: KanbanListTask[] = []
  const tasksRaw = Array.isArray(o.tasks) ? o.tasks : []
  for (const item of tasksRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    tasks.push({
      id,
      name: strField(r, 'name'),
      columnId: strOrNullField(r, 'column_id'),
      columnName: strOrNullField(r, 'column_name'),
      position: numOrNullField(r, 'position') ?? 0,
    })
  }
  const workspaceId = strOrNullField(o, 'workspace_id')
  const itemId = strOrNullField(o, 'item_id')
  return {
    workspaceId,
    itemId,
    boardLabel: strOrNullField(o, 'board') ?? strOrNullField(o, 'name'),
    columns,
    tasks,
    totalCount: numOrNullField(o, 'total_count'),
    limit: numOrNullField(o, 'limit'),
    offset: numOrNullField(o, 'offset'),
    hasMore: boolField(o, 'has_more', false),
    hint: strOrNullField(o, 'hint'),
    error: null,
    success: true,
  }
}

export interface ParsedKanbanMove {
  boardId: string | null
  taskId: string | null
  taskName: string | null
  fromColumnId: string | null
  toColumnId: string | null
  columnId: string | null
  columnName: string | null
  position: number | null
  error: string | null
  success: boolean
}

export function parseKanbanMove(data: unknown): ParsedKanbanMove {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      boardId: null,
      taskId: null,
      taskName: null,
      fromColumnId: null,
      toColumnId: null,
      columnId: null,
      columnName: null,
      position: null,
      error,
      success: false,
    }
  }
  const success = boolField(o, 'success', true)
  return {
    boardId: strOrNullField(o, 'board_id'),
    taskId: strOrNullField(o, 'task_id'),
    taskName: strOrNullField(o, 'task_name'),
    fromColumnId: strOrNullField(o, 'from_column_id'),
    toColumnId: strOrNullField(o, 'to_column_id') ?? strOrNullField(o, 'column_id'),
    columnId: strOrNullField(o, 'column_id'),
    columnName: strOrNullField(o, 'column_name'),
    position: numOrNullField(o, 'position'),
    error: null,
    success,
  }
}

/** Quick parser for the `metadata` object used by ReadCompactedMessages. */
export function parseMetadata(data: unknown): Record<string, string> {
  const result: Record<string, string> = {}
  const o = unwrapDataRecord(data)
  const meta = o.metadata !== undefined ? asRecord(o.metadata) : o
  for (const [key, value] of Object.entries(meta)) {
    if (value === null || value === undefined) continue
    if (typeof value === 'string') result[key] = value
    else if (typeof value === 'number' || typeof value === 'boolean') result[key] = String(value)
  }
  return result
}

// ─── generate_image ────────────────────────────────────────────────────────
// Parses the JSON `data` payload produced by `execute_generate_image` in
// `src/modules/agent/tools/generate_image.zig`:
//   {"status":"generated","count":1,"model":"dall-e-3","size":"1024x1024",
//    "images":[{"index":0,"path":"/cwd/.../img_xxx.png","bytes":12345,"mime":"image/png"}],
//    "revised_prompt":"A vibrant watercolor painting of a hat-wearing cat","error":null}
// On error:
//   {"status":null,"count":null,"model":null,"size":null,"images":[],
//    "revised_prompt":null,"error":"HTTP 400: ..."}

export interface ParsedGenerateImage {
  status: string | null
  count: number | null
  model: string | null
  size: string | null
  /** Absolute filesystem path of each saved image (DALL-E / gpt-image-1 save to disk). */
  images: Array<{ index: number; path: string; bytes: number; mime: string }>
  /** DALL-E 3 / gpt-image-1 only — null for DALL-E 2 (which doesn't rewrite). */
  revisedPrompt: string | null
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

export function parseGenerateImage(data: unknown): ParsedGenerateImage {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      status: null,
      count: null,
      model: null,
      size: null,
      images: [],
      revisedPrompt: null,
      error,
    }
  }
  const images: ParsedGenerateImage['images'] = []
  const imagesRaw = Array.isArray(o.images) ? o.images : []
  for (const item of imagesRaw) {
    const r = asRecord(item)
    images.push({
      index: numOrNullField(r, 'index') ?? 0,
      path: strField(r, 'path'),
      bytes: numOrNullField(r, 'bytes') ?? 0,
      mime: strField(r, 'mime') || 'image/png',
    })
  }

  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count'),
    model: strOrNullField(o, 'model'),
    size: strOrNullField(o, 'size'),
    images,
    revisedPrompt: strOrNullField(o, 'revised_prompt'),
    error: null,
  }
}

// ─── web_search ────────────────────────────────────────────────────────────
// Parses the JSON `data` payload produced by `exec_web_search` in
// `src/agentic_loop/tools_exec_web_search.zig`.
// On success the payload is UNTYPED PASSTHROUGH (D13): `response` holds the
// provider's own JSON, verbatim and untouched.
//   {"provider":"tinyfish","status":200,"response":{…}}
// TinyFish answers `{results:[…]}`, Brave `{web:{results:[…]}}`, Serper `{organic:[…]}` and a
// self-hosted SearxNG a bare `[{…}]`. There is deliberately NO normalized result schema, so
// `response` stays `unknown` here and the renderer is the only layer allowed an opinion about it.
// A shape this client has never seen is a normal outcome (D13), not an error.
// A failure carries `error` plus a reason flag — `configured:false`, `unknown_provider` (+
// `available`), `host_mismatch` (+ `pinned_host`, `requested_host`), `invalid_curl`, `exhausted` (+
// `other_providers`), `unsafe_pinned_url`, `response_too_large` or `http_status`.
// `transport` is the flagless one: DNS, TLS or timeout, and the message is the envelope.
/** The nine reasons a `web_search` envelope can fail, as the card spells them. */
export type WebSearchErrorFlag =
  | 'configured'
  | 'unknown_provider'
  | 'host_mismatch'
  | 'invalid_curl'
  | 'exhausted'
  | 'unsafe_pinned_url'
  | 'response_too_large'
  | 'http_status'
  | 'transport'

/** An alternative provider, as an error envelope names it. Never carries a key. */
export interface WebSearchProviderRef {
  name: string
  url: string
}

export interface ParsedWebSearchError {
  /** The backend's sentence, verbatim. */
  message: string
  /**    * Which reasons this envelope claims, in a fixed order so two renderings of the same failure
   * never disagree. `transport` is the residual: it is the one failure with no key of its own, so a
   * flagless error is reported as it. Every other flag is read off a key the backend sets. */
  flags: WebSearchErrorFlag[]
  /** True only for `configured:false` — nothing is set up in Settings yet. */
  configured: boolean
  /** `unknown_provider`'s alternatives, so the card can name who IS available. */
  available: WebSearchProviderRef[]
  /** `exhausted`'s alternatives — the providers worth retrying with. */
  otherProviders: WebSearchProviderRef[]
  /** `host_mismatch`: the host the user pinned, and the one the curl asked for. */
  pinnedHost: string | null
  requestedHost: string | null
  /** `http_status`'s number; null for every other reason. */
  httpStatus: number | null
}

export interface ParsedWebSearch {
  /** The provider that ran. Null on `configured`/`unknown_provider` failures. */
  provider: string | null
  /** The provider's HTTP status on success; null on failure. */
  status: number | null
  /** The provider's payload, verbatim. NEVER interpreted — see D13. */
  response: unknown
  /** True when the envelope carries no `error`. */
  success: boolean
  error: ParsedWebSearchError | null
}

/** Read a list of alternative providers. Accepts both spellings the backend
 * and the plan use: `[{name,url}]` objects, and a bare `["tinyfish"]` of names. */
function providerRefs(o: Record<string, unknown>, key: string): WebSearchProviderRef[] {
  const raw = o[key]
  if (!Array.isArray(raw)) return []
  const refs: WebSearchProviderRef[] = []
  for (const item of raw) {
    if (typeof item === 'string') {
      if (item !== '') refs.push({ name: item, url: '' })
      continue
    }
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (name === '') continue
    refs.push({ name, url: strField(r, 'url') })
  }
  return refs
}

/** Typed view of a `web_search` failure envelope. `transport` when nothing claims it. */
export function parseWebSearchError(o: Record<string, unknown>): ParsedWebSearchError {
  const configured = o.configured === false
  const unknownProvider = boolField(o, 'unknown_provider', false)
  const hostMismatch = boolField(o, 'host_mismatch', false)
  const invalidCurl = boolField(o, 'invalid_curl', false)
  const exhausted = boolField(o, 'exhausted', false)
  const unsafePinnedUrl = boolField(o, 'unsafe_pinned_url', false)
  const responseTooLarge = boolField(o, 'response_too_large', false)
  const httpStatus = numOrNullField(o, 'http_status')

  const flags: WebSearchErrorFlag[] = []
  if (configured) flags.push('configured')
  if (unknownProvider) flags.push('unknown_provider')
  if (hostMismatch) flags.push('host_mismatch')
  if (invalidCurl) flags.push('invalid_curl')
  if (exhausted) flags.push('exhausted')
  if (unsafePinnedUrl) flags.push('unsafe_pinned_url')
  if (responseTooLarge) flags.push('response_too_large')
  if (httpStatus !== null) flags.push('http_status')
  if (flags.length === 0) flags.push('transport')

  return {
    message: strField(o, 'error'),
    flags,
    configured,
    available: unknownProvider ? providerRefs(o, 'available') : [],
    otherProviders: exhausted ? providerRefs(o, 'other_providers') : [],
    pinnedHost: strOrNullField(o, 'pinned_host'),
    requestedHost: strOrNullField(o, 'requested_host'),
    httpStatus,
  }
}

/** The exec wrapper reports a failure in TWO places: the envelope's `error` field, and — for the
 * reasons the model can recover from on its own — the whole inner JSON envelope as that field's
 * TEXT. */
/** When it is a text envelope, read the flags out of it; when it is a plain sentence, report the
 * sentence and no flag, because a message with no reason key is not evidence of a transport
 * failure. */
export function parseWebSearchErrorText(text: string): ParsedWebSearchError {
  const o = asRecord(text)
  if (typeof o.error === 'string' && Object.keys(o).length > 1) return parseWebSearchError(o)
  return {
    message: text,
    flags: [],
    configured: false,
    available: [],
    otherProviders: [],
    pinnedHost: null,
    requestedHost: null,
    httpStatus: null,
  }
}

export function parseWebSearch(data: unknown): ParsedWebSearch {
  const o = unwrapDataRecord(data)
  const message = strOrNullField(o, 'error')
  if (message !== null) {
    return {
      provider: strOrNullField(o, 'provider'),
      status: null,
      response: null,
      success: false,
      error: parseWebSearchError(o),
    }
  }
  return {
    provider: strOrNullField(o, 'provider'),
    status: numOrNullField(o, 'status'),
    response: 'response' in o ? o.response : null,
    success: true,
    error: null,
  }
}

// ─── list_web_search_providers ─────────────────────────────────────────────
// The `exec_list_web_search_providers` payload (D14):
//   {"providers":[{"name":"tinyfish","url":"https://api.search.tinyfish.ai",
//                  "description":"…","curl":"curl 'https://…?key={key}'"}]}
// `curl` is a TEMPLATE: it carries the literal text `{key}` where the
// credential belongs, so the listing is safe by construction — nothing
// secret reaches the model, and the card may render it verbatim.

export interface ParsedSearchProviderEntry {
  name: string
  url: string
  description: string
  /** The editable template. Contains `{key}`, never the key itself. */
  curl: string
}

export interface ParsedListSearchProviders {
  providers: ParsedSearchProviderEntry[]
}

export function parseListWebSearchProviders(data: unknown): ParsedListSearchProviders {
  const o = unwrapDataRecord(data)
  const raw = Array.isArray(o.providers) ? o.providers : []
  const providers: ParsedSearchProviderEntry[] = []
  for (const item of raw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    // A nameless row has nothing to key a settings edit on.
    if (name === '') continue
    providers.push({
      name,
      url: strField(r, 'url'),
      description: strField(r, 'description'),
      curl: strField(r, 'curl'),
    })
  }
  return { providers }
}

// ─── list_directory ─────────────────────────────────────────────────────────
//
// Parses the JSON `data` payload produced by `execute_list_directory` +
// `toJSON` in `src/modules/agent/tools/list_directory.zig`:
//
//   {"path":"/proj","count":3,"entries":[
//     {"name":"src","path":"/proj/src","is_directory":true,"is_symlink":false},
//     {"name":"main.zig","path":"/proj/main.zig","is_directory":false,"is_symlink":false}
// ]} The sort order is whatever the backend produced (directories first, then files, alphabetical)
// — the frontend does NOT re-sort. On error, `normalizeToolContent` unwraps the full envelope and
// the parser reads the `error` key — see the `error !== null` branch below.

export interface ParsedListDirectoryEntry {
  name: string
  path: string
  isDirectory: boolean
  isSymlink: boolean
}

export interface ParsedListDirectory {
  /** Absolute path that was listed (from `path="..."` on the wrapper). */
  path: string
  /** Total entry count (from `count="..."` on the wrapper). */
  count: number
  /** Parsed entries in backend sort order (dirs first, then files). */
  entries: ParsedListDirectoryEntry[]
  /** false when the parser finds an `<error>` tag (success path) or wrapper `<success>false</success>`. */
  success: boolean
  /** Error message on failure; null on success. */
  error: string | null
}

export function parseListDirectory(data: unknown): ParsedListDirectory {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return { path: '', count: 0, entries: [], success: false, error }
  }

  const dirPath = strField(o, 'path')
  const entriesRaw = Array.isArray(o.entries) ? o.entries : []
  const entries: ParsedListDirectoryEntry[] = []
  for (const item of entriesRaw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (!name) continue // skip malformed rows
    entries.push({
      name,
      path: strField(r, 'path'),
      isDirectory: boolField(r, 'is_directory', false),
      isSymlink: boolField(r, 'is_symlink', false),
    })
  }

  return {
    path: dirPath,
    count: numOrNullField(o, 'count') ?? entries.length,
    entries,
    success: true,
    error: null,
  }
}

// ─── mcp_* (universal MCP tool) ─────────────────────────────────────────────
//
// Any tool whose name starts with `mcp_` (e.g. `mcp_graphify_graph_stats`,
// `mcp_db_query`) renders through the universal `<McpTool>` card. The backend
// (`handle_tool.zig`) stores MCP results as RAW server text (not a wrapped
// envelope) on success, and as a wrapped
// `wrapToolOutput(..., success=false, err, "")` JSON envelope on failure — so the
// parser tolerates BOTH shapes:
//
//   raw success:   `Nodes: 14885 Edges: 21958 ...` (or JSON)
//   error envelope: `{"tool":"mcp_...","parameters":{},"success":false,"data":null,"error":"..."}`
//
// `toolName` is the full registry name (`mcp_<server>_<tool>`). The server is
// the segment between the first and second underscore; the sub-tool is the
// remainder (which may itself contain underscores, e.g. `graph_stats`).

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

// ─── progressive tools (search_tool / view_tool / use_tool) ──────────────────
//
// Universal `<ProgressiveTool>` card: the three agent tools that let the model
// browse a catalog of not-yet-enabled tools and equip one for the session.
// Backend renderers live in `src/agentic_loop/progressive_catalog.zig`; the
// exec adapter wraps them with the standard `wrapToolOutput` JSON envelope,
// and the card reads the inner `data` object here.
//
//   search_tool success:
//     {"query":"q","server":"s"|null,"count":N,"total":M,
//      "tools":[{"name":"n","kind":"builtin|mcp","server":"s",
//        "equipped":"session|no","summary":"one-liner"}, ...],
//      "truncated":false,"hint":"..."|null}
//   view_tool found:
//     {"name":"n","kind":"...","server":"s","equipped":"session|no",
//      "description":"...","parameters":{...}|"..."|null,
//      "note":null,"hint":"..."}
//   view_tool miss:
//     {"name":"n","found":false,"error":"...",
//      "did_you_mean":["..."],"hint":"..."}
//   use_tool found (minimal equip signal — no repeated schema, view_tool
//   already showed it):
//     {"name":"n","kind":"...","equipped":true,
//      "inserted":true|false,"wait_next_turn":true|false,
// "source":"session"|null,"note":"..."} use_tool miss:
// {"name":"n","equipped":false,"inserted":false, "error":"...","did_you_mean":[...],"hint":"..."}

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

/** Read the `parameters` payload: a JSON-schema object, its JSON string, or ''. */
function readParametersField(o: Record<string, unknown>): string {
  const v = o.parameters
  if (v === null || v === undefined) return ''
  if (typeof v === 'string') return v
  try {
    return JSON.stringify(v)
  } catch {
    return ''
  }
}

function prettyJsonOrRaw(s: string): { pretty: string; isJson: boolean } {
  const trimmed = s.trim()
  if (!trimmed) return { pretty: '', isJson: false }
  try {
    return { pretty: JSON.stringify(JSON.parse(trimmed), null, 2), isJson: true }
  } catch {
    return { pretty: s, isJson: false }
  }
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

// Re-export shared param helper (single source of truth in helpers/).
export { extractParam } from '../../../helpers/extractParam'
// ─── present_files ─────────────────────────────────────────────────────────
//
// Parses the JSON `data` payload produced by `executePresentFilesToString` in
// `src/modules/agent/tools/present_files.zig`:
//
//   {"status":"presented","count":2,"files":[
//     {"path":"/abs/a.txt","bytes":12,"mime":"text/plain; charset=utf-8","label":"notes"},
//     {"path":"/abs/b.jpg","bytes":48211,"mime":"image/jpeg","label":"b.jpg"}
//   ],"error":null}
//
// Error shape: {"status":null,"count":0,"files":[],"error":"..."}

export interface ParsedPresentFile {
  path: string
  bytes: number
  mime: string
  label: string
}

export interface ParsedPresentFiles {
  status: string | null
  count: number | null
  files: ParsedPresentFile[]
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

function parsePresentFileRecord(item: unknown): ParsedPresentFile {
  const r = asRecord(item)
  return {
    path: strField(r, 'path'),
    bytes: numOrNullField(r, 'bytes') ?? 0,
    mime: strField(r, 'mime') || 'application/octet-stream',
    label: strField(r, 'label'),
  }
}

export function parsePresentFiles(data: unknown): ParsedPresentFiles {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return { status: null, count: null, files: [], error }
  }
  const files: ParsedPresentFile[] = []
  const filesRaw = Array.isArray(o.files) ? o.files : []
  for (const item of filesRaw) {
    files.push(parsePresentFileRecord(item))
  }
  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count') ?? files.length,
    files,
    error: null,
  }
}

/** True for renderable image mimes (thumbnail preview before download). */
export function isPreviewableImage(mime: string): boolean {
  return mime.toLowerCase().startsWith('image/')
}

/** Basename of an absolute path (`/a/b/c.jpg` → `c.jpg`). */
export function basenameOfPath(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

/** Human-readable byte size (`48211` → `47.1 KB`). */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '0 B'
  if (n < 1024) return `${n} B`
  const units = ['KB', 'MB', 'GB']
  let v = n / 1024
  let u = 0
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024
    u += 1
  }
  return `${v.toFixed(1)} ${units[u]}`
}
