import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'

// ─── list_directory ───────────────────────────────────────────────────────── Parses the JSON
// `data` payload produced by `execute_list_directory` + `toJSON` in
// `src/modules/agent/tools/list_directory.zig`: {"path":"/proj","count":3,"entries":[.
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
