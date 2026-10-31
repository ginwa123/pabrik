/** The `ask_user` block the agent writes as the last thing in a message:
 * `<ask_user>{"question":"…","options":["a","b"]}</ask_user>`. The turn that carries it ends
 * with `finish_reason=awaiting_user`, and the answer rewrites the block in place. */
export type AskUserStatus = 'pending' | 'answered' | 'skipped' | 'abandoned'

export interface AskUserQuestion {
  /** `settled` means the block carries a status this build does not know. */
  status: AskUserStatus | 'settled'
  rawStatus: string
  question: string
  header: string
  options: string[]
  allowFreeText: boolean
  multiSelect: boolean
  recommended: string
  answer: string
  answersCount: number
}

export const ASK_USER_OPEN = '<ask_user>'
export const ASK_USER_CLOSE = '</ask_user>'

const asRecord = (v: unknown): Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {}

const str = (o: Record<string, unknown>, key: string): string => {
  const v = o[key]
  if (typeof v === 'string') return v
  if (v === null || v === undefined) return ''
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

const truthy = (v: unknown, fallback: boolean): boolean => {
  if (v === null || v === undefined) return fallback
  return v === true || v === 'true'
}

const toStatus = (raw: string): AskUserStatus | 'settled' => {
  const trimmed = raw.trim()
  if (trimmed === '' || trimmed === 'pending') return 'pending'
  if (trimmed === 'answered' || trimmed === 'skipped' || trimmed === 'abandoned') return trimmed
  return 'settled'
}

/** The span of the last block in `content`, or null. */
export const findAskUserSpan = (
  content: string | undefined | null,
): { start: number; end: number } | null => {
  if (!content) return null
  const close = content.lastIndexOf(ASK_USER_CLOSE)
  if (close === -1) return null
  const start = content.lastIndexOf(ASK_USER_OPEN, close)
  if (start === -1) return null
  return { start, end: close + ASK_USER_CLOSE.length }
}

/** The question a message carries, or null when it carries none (or a broken one). */
export const parseAskUserBlock = (
  content: string | undefined | null,
): AskUserQuestion | null => {
  const span = findAskUserSpan(content)
  if (!span || !content) return null

  const body = content.slice(span.start + ASK_USER_OPEN.length, span.end - ASK_USER_CLOSE.length)
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  }
  // eslint-disable-next-line local/no-try-catch, local/no-silent-fallback-catch -- a block that is not JSON is not a question: null is the caller's "no question" answer, which renders no card and leaves the raw text in the message
  catch {
    return null
  }
  const obj = asRecord(parsed)
  const question = str(obj, 'question').trim()
  if (question === '') return null

  const optionsRaw = obj.options
  const rawStatus = str(obj, 'status')

  return {
    status: toStatus(rawStatus),
    rawStatus,
    question: str(obj, 'question'),
    header: str(obj, 'header'),
    options: Array.isArray(optionsRaw) ? optionsRaw.map((v) => String(v)) : [],
    allowFreeText: truthy(obj.allow_free_text, true),
    multiSelect: truthy(obj.multi_select, false),
    recommended: str(obj, 'recommended'),
    answer: str(obj, 'answer'),
    answersCount: Number.parseInt(str(obj, 'answers_count'), 10) || 0,
  }
}

const stripCompleteBlocks = (content: string): string => {
  let out = content
  for (;;) {
    const close = out.indexOf(ASK_USER_CLOSE)
    if (close === -1) return out
    const start = out.lastIndexOf(ASK_USER_OPEN, close)
    if (start === -1) return out
    out = out.slice(0, start) + out.slice(close + ASK_USER_CLOSE.length)
  }
}

/** The index where a marker that is still being streamed begins, or -1. */
const partialMarkerStart = (content: string): number => {
  const lt = content.lastIndexOf('<')
  if (lt === -1) return -1
  const tail = content.slice(lt)
  return ASK_USER_OPEN.startsWith(tail) ? lt : -1
}

/** The message as it should read: the block is data, not prose. */
export const stripAskUserBlock = (content: string | undefined | null): string => {
  if (!content) return ''
  return stripCompleteBlocks(content).trimEnd()
}

/** Same, plus a marker the token stream has not finished writing yet. */
export const stripAskUserBlockPartial = (content: string | undefined | null): string => {
  if (!content) return ''
  const complete = stripCompleteBlocks(content)
  const open = complete.lastIndexOf(ASK_USER_OPEN)
  if (open !== -1) return complete.slice(0, open).trimEnd()
  const partial = partialMarkerStart(complete)
  if (partial !== -1) return complete.slice(0, partial).trimEnd()
  return complete.trimEnd()
}
