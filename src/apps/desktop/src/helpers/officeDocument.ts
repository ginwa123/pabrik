export const MARKDOWN_FORMAT = 'markdown'
export const OFFICE_FORMAT = 'office'

/** Which Univer product renders an office document. */
export type OfficeKind = 'doc' | 'sheet'

/** The stored body of an office document: the kind plus its Univer snapshot. */
export interface OfficeBody {
  kind: OfficeKind
  snapshot: Record<string, unknown>
}

/** What an office document with no body opens as. */
export const DEFAULT_OFFICE_KIND: OfficeKind = 'sheet'

export function isOfficeFormat(format: string | null | undefined): boolean {
  return format === OFFICE_FORMAT
}

export function isOfficeKind(value: unknown): value is OfficeKind {
  return value === 'doc' || value === 'sheet'
}

/** The body to store for a `kind` document holding `snapshot`. */
export function serializeOfficeBody(kind: OfficeKind, snapshot: unknown): string {
  return JSON.stringify({ kind, snapshot })
}

/**
 * The office body a stored document holds; `null` when the body is not an envelope.
 */
export function parseOfficeBody(body: string | null | undefined): OfficeBody | null {
  if (!body) return { kind: DEFAULT_OFFICE_KIND, snapshot: {} }

  let parsed: unknown
  /* eslint-disable local/no-try-catch, local/no-silent-fallback-catch -- JSON.parse has no non-throwing form, and the caller renders the null */
  try {
    parsed = JSON.parse(body)
  } catch {
    return null
  }
  /* eslint-enable local/no-try-catch, local/no-silent-fallback-catch */
  if (!isPlainObject(parsed)) return null
  if (!isOfficeKind(parsed.kind)) return null
  if (!isPlainObject(parsed.snapshot)) return null
  return { kind: parsed.kind, snapshot: parsed.snapshot }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
