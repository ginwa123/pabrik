/** parseAgentErrorHeadline — single source of truth for parsing agentic-loop error/retry diagnostic
 * content into a headline + retry label. */
export interface ParsedAgentError {
  /** retry label like "3/10" — null when the content is a bail diagnostic (no [Retry N/M] prefix) */
  retryLabel: string | null
  /** "StreamInterrupted (callDynamicAgentNew)" or similar — null only on empty content */
  headline: string | null
}

export function parseAgentErrorHeadline(content: string): ParsedAgentError {
  const retryMatch = content.match(/\[Retry (\d+\/\d+)\]/)
  const retryLabel = retryMatch ? retryMatch[1]! : null
  const reason = content.match(/Reason for last retry:\s*(.+?)\.?\s*$/m)
  if (reason) return { retryLabel, headline: reason[1]!.trim() || null }
  const stripped = content.replace(/\[Retry \d+\/\d+\]\s*/, '')
  const firstLine = stripped.split('\n')[0] ?? stripped
  const m = firstLine.match(/^(.*?)\.\s*(Retrying|$)/)
  return { retryLabel, headline: (m ? m[1]! : firstLine).trim() || null }
}
