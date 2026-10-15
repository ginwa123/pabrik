/** extractParam — shared helper for pulling a named parameter out of a
 * tool-call `parameters` string.
 * Tries XML `<tag>…</tag>` first, then JSON `{"tag": value}` fallback.
 * Returns `null` for missing / empty / unparseable input. Pure function. */
export function extractParam(parameters: string | null | undefined, tag: string): string | null {
  if (!parameters || !tag) return null
  try {
    const m = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(parameters)
    if (m && m[1] && m[1].trim() !== '') return m[1]
  } catch {}
  try {
    const obj = JSON.parse(parameters) as Record<string, unknown>
    const v: unknown = obj?.[tag]
    if (typeof v === 'string' && v.trim() !== '') return v
    if (v != null) return String(v)
  } catch {}
  return null
}
