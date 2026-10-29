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
  // The `_multiline` flag is preserved for back-compat with the original public signature but is
  // currently a no-op (the implementation already supports multiline inner content via `indexOf`
  // matching the first `<tag>` / `</tag>` pair, which works for both single-line and multi-line.
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
