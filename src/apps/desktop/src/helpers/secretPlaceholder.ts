export const SECRET_PLACEHOLDER_PREFIX = '{' + '{SECRETS:'
export const SECRET_PLACEHOLDER_SUFFIX = '}' + '}'

export const SECRET_SUGGESTION_LIMIT = 8

export interface PlaceholderQuery {
  query: string
  start: number
  end: number
}

const CLOSES_THE_QUERY = /[}\s]/

export function placeholderQueryAt(text: string, caret: number): PlaceholderQuery | null {
  const at = Math.max(0, Math.min(caret, text.length))
  const start = text.lastIndexOf(SECRET_PLACEHOLDER_PREFIX, at)
  if (start < 0) return null

  const typed_start = start + SECRET_PLACEHOLDER_PREFIX.length
  if (typed_start > at) return null

  const typed = text.slice(typed_start, at)
  if (CLOSES_THE_QUERY.test(typed)) return null
  return { query: typed, start, end: at }
}

export function matchSecretNames(
  names: readonly string[],
  query: string,
  limit: number = SECRET_SUGGESTION_LIMIT,
): string[] {
  if (limit <= 0) return []
  const needle = query.trim().toLowerCase()
  if (needle.length === 0) return names.slice(0, limit)

  const prefixed: string[] = []
  const contains: string[] = []
  for (const name of names) {
    const lower = name.toLowerCase()
    if (lower.startsWith(needle)) prefixed.push(name)
    else if (lower.includes(needle)) contains.push(name)
  }
  return [...prefixed, ...contains].slice(0, limit)
}

export function applySecretPlaceholder(
  text: string,
  caret: number,
  name: string,
): { text: string; caret: number } | null {
  const hit = placeholderQueryAt(text, caret)
  if (!hit || name.length === 0) return null

  let consumed_to = hit.end
  if (text.startsWith(SECRET_PLACEHOLDER_SUFFIX, consumed_to)) {
    consumed_to += SECRET_PLACEHOLDER_SUFFIX.length
  }

  const inserted = SECRET_PLACEHOLDER_PREFIX + name + SECRET_PLACEHOLDER_SUFFIX
  const next = text.slice(0, hit.start) + inserted + text.slice(consumed_to)
  return { text: next, caret: hit.start + inserted.length }
}
