import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'

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

/** A `rg -n` text row: `path:line:text`. Non-greedy so a Windows drive letter and any
 *  colon in the path stay part of the path. */
const TEXT_MATCH_ROW = /^(.*?):(\d+):([\s\S]*)$/
/** `count_only` text row: `path:count`. */
const TEXT_COUNT_ROW = /^(.*):(\d+)\s*$/
/** A context row (`-B`/`-A`/`-C`): `path-line-text`. Only tried once the two above miss. */
const TEXT_CONTEXT_ROW = /^(.*?)-(\d+)-([\s\S]*)$/
const TEXT_WARNING = /^<warning>([\s\S]*?)<\/warning>/
const TEXT_TRUNCATED = /^\[truncated: showing (\d+) of (\d+) matches/

export interface ParsedSearchText {
  fileResults: FileResult[]
  warning: string | null
  hint: string | null
  returned: number | null
  total: number | null
}

/** Read the tool's DEFAULT output: `text` format (`rg -n` bytes) arrives as `_raw`, not as
 *  `files[]`, and the card used to render that shape as "0 files, 0 matches". */
export function parseSearchText(raw: string): ParsedSearchText {
  const groups = new Map<string, FileResult>()
  let warning: string | null = null
  let hint: string | null = null
  let returned: number | null = null
  let total: number | null = null

  const groupFor = (path: string): FileResult => {
    const existing = groups.get(path)
    if (existing) return existing
    const created: FileResult = { path, total: 0, count: 0, matches: [] }
    groups.set(path, created)
    return created
  }

  for (const line of raw.split('\n')) {
    if (line === '') continue

    if (warning === null) {
      const warned = TEXT_WARNING.exec(line)
      if (warned) {
        warning = warned[1].trim()
        continue
      }
    }

    const truncated = TEXT_TRUNCATED.exec(line)
    if (truncated) {
      returned = Number(truncated[1])
      total = Number(truncated[2])
      hint = line.trim()
      continue
    }

    const match = TEXT_MATCH_ROW.exec(line)
    if (match) {
      const file = groupFor(match[1])
      file.matches.push({ lineNumber: Number(match[2]), snippet: match[3] })
      file.count += 1
      continue
    }

    const counted = TEXT_COUNT_ROW.exec(line)
    if (counted) {
      const file = groupFor(counted[1])
      const n = Number(counted[2])
      file.count += n
      continue
    }

    const context = TEXT_CONTEXT_ROW.exec(line)
    if (context) {
      const file = groupFor(context[1])
      file.matches.push({ lineNumber: Number(context[2]), snippet: context[3] })
      continue
    }
  }

  const fileResults = [...groups.values()]
  // No per-file total rides in the text; the rows ARE everything that matched.
  for (const file of fileResults) file.total = file.count

  return { fileResults, warning, hint, returned, total }
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

  const warning = strOrNullField(o, 'warning')
  const rawText = strOrNullField(o, '_raw')
  if (fileResults.length === 0 && rawText !== null && rawText !== '') {
    const text = parseSearchText(rawText)
    return {
      pattern: strOrNullField(o, 'pattern'),
      path: strOrNullField(o, 'path'),
      warning: warning ?? text.warning,
      error: null,
      fileResults: text.fileResults,
      success: true,
      returned: text.returned,
      total: text.total,
      truncated: text.hint !== null,
      outputTruncated: false,
      truncatedHint: text.hint,
    }
  }

  return {
    pattern: strOrNullField(o, 'pattern'),
    path: strOrNullField(o, 'path'),
    warning,
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
