import { boolField, numOrNullField, strField, strOrNullField, unwrapDataRecord } from './internal'

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
