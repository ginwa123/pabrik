import { tryUnwrapToolOutput } from './unwrapToolOutput'

/** Render a tool result's payload as readable text for the EXPANDED body of ChatView's generic tool
 * fallback. */
export const TOOL_PAYLOAD_PREVIEW_MAX = 20_000

function cap(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  const dropped = text.length - maxChars
  return `${text.slice(0, maxChars)}\n… truncated (${dropped} more characters)`
}

export function toolPayloadPreview(
  content: unknown,
  maxChars: number = TOOL_PAYLOAD_PREVIEW_MAX,
): string {
  if (typeof content !== 'string') return ''
  const raw = content.trim()
  if (raw === '') return ''

  // `tryUnwrapToolOutput` swallows its own `JSON.parse` failure and answers
  // `null`; the fallback below is the same bytes the caller already had, not
  // a hidden failure, so there is nothing to log.
  const unwrapped = tryUnwrapToolOutput(raw)
  if (unwrapped === null) return cap(raw, maxChars)
  if (!unwrapped.success) {
    const message = (unwrapped.error ?? 'tool failed').trim()
    return cap(message || 'tool failed', maxChars)
  }
  if (unwrapped.data === null || unwrapped.data === undefined) return cap(raw, maxChars)
  // `data` came out of JSON.parse, so it is acyclic and free of BigInt —
  // `JSON.stringify` here cannot throw.
  return cap(JSON.stringify(unwrapped.data, null, 2), maxChars)
}
