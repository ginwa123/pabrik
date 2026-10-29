import { boolField, strOrNullField, unwrapDataRecord } from './internal'

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

/** `set_pull_request` result. */
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
