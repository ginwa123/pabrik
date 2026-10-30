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
