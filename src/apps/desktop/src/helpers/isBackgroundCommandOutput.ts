/** isBackgroundCommandOutput — detect + parse the session-queue envelope the background-process
 * watcher/cron inserts when a detached `command` finishes. THREE shapes are recognised, and they
 * are tried newest-first: 1. */
import { Effect, Either, Data } from 'effect'
import {
  extractBool,
  extractTag,
} from '../components/tool_outputs/_shared/toolOutputParser'

export interface ParsedBackgroundCommandOutput {
  /** digits in `<pid>` — e.g. "12345" */
  pid: string
  /** unescaped `<command>` — e.g. "sleep 10" */
  command: string
  /** unescaped `<stdout>` (legacy: text between the fences), trimmed */
  body: string
  /** `<truncated>` (legacy rows: always false) */
  truncated: boolean
  /** unescaped `<log_path>` when truncated, else null */
  logPath: string | null
}

/** XML envelope — non-greedy so a body containing tags can't overrun. */
const BACKGROUND_XML_RE = /<background_command>([\s\S]*?)<\/background_command>/

/** A candidate JSON envelope: an object whose first key is `pid`. Cheap and deliberately narrow. It
 * keeps `JSON.parse` off the hot path of ordinary chat history, and lets the predicate answer
 * without parsing, so a user message that merely contains `{` is not misdetected. */
const JSON_ENVELOPE_RE = /^\s*\{\s*"pid"\s*:/

/**  * Failure of the JSON branch. A tagged error so the failure channel has a type instead of `unknown`
 * — `local/no-try-catch` bans the `try`/`catch` spelling, and an `Effect` keeps the failure in the
 * signature (same reasoning as `sync/SyncError.ts`). */
class BackgroundEnvelopeJsonError extends Data.TaggedError('BackgroundEnvelopeJsonError')<{
  reason: string
}> {}

/**  * Parse the JSON envelope without a `try`/`catch`. `Effect.try` moves a throw into the error
 * channel and `Effect.either` turns it into a VALUE, so `runSync` here cannot throw: the failure is
 * a `Left`, which is `null` to the caller. Same idiom as `helpers/prStatusCache.ts`. */
function parseJsonEnvelope(content: string): ParsedBackgroundCommandOutput | null {
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: () => JSON.parse(content) as unknown,
        catch: () => new BackgroundEnvelopeJsonError({ reason: 'not valid JSON' }),
      }),
    ),
  )
  if (Either.isLeft(outcome)) return null
  return shapeFromJson(outcome.right)
}

/**  * Map a parsed value onto the card's fields, or `null` when it is not our envelope after all. The
 * wire names are the BACKEND's (`stdout`); `body` is the card's name for the same thing. */
function shapeFromJson(value: unknown): ParsedBackgroundCommandOutput | null {
  if (typeof value !== 'object' || value === null) return null
  const obj = value as Record<string, unknown>
  // `pid` is the discriminator: a JSON object without it is some other row.
  if (typeof obj.pid !== 'number' && typeof obj.pid !== 'string') return null
  if (typeof obj.command !== 'string' || typeof obj.stdout !== 'string') return null
  return {
    pid: String(obj.pid),
    command: obj.command,
    body: obj.stdout.trim(),
    truncated: obj.truncated === true,
    logPath: typeof obj.log_path === 'string' ? obj.log_path : null,
  }
}



/** Legacy prose prefix emitted by the pre-XML `buildCompletionMessage`. */
const LEGACY_PREFIX = 'This is an output from background command (pid '

/** Legacy fence matcher — tolerates 3, 4, or 5-quote fences. */
const LEGACY_FENCE_RE = /"{3,5}/g

/**  * Escape the 5 XML metacharacters on serialization. Mirrors `llm_history.zig xmlEscape`: `&` MUST
 * be replaced first, otherwise the later replacements would double-escape their own `&`-prefixed
 * entities. */
function escapeXml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

export function isBackgroundCommandOutput(content: string): boolean {
  if (JSON_ENVELOPE_RE.test(content)) return true
  if (BACKGROUND_XML_RE.test(content)) return true
  return content.startsWith(LEGACY_PREFIX)
}

export function parseBackgroundCommandOutput(content: string): ParsedBackgroundCommandOutput | null {
  // Newest shape first. A no-op for the older two (the regex does not match),
  // and for anything that is not a JSON envelope.
  if (JSON_ENVELOPE_RE.test(content)) {
    const fromJson = parseJsonEnvelope(content)
    // `null` means "looked like ours, was not" — fall through rather than
    // returning, so the older shapes still get their attempt.
    if (fromJson !== null) return fromJson
  }

  const xml = content.match(BACKGROUND_XML_RE)
  if (xml) {
    const inner = xml[1] ?? ''
    const pid = extractTag(inner, 'pid')
    const command = extractTag(inner, 'command')
    const body = extractTag(inner, 'stdout')
    if (pid === null || command === null || body === null) return null
    return {
      pid,
      command,
      body: body.trim(),
      truncated: extractBool(inner, 'truncated'),
      logPath: extractTag(inner, 'log_path'),
    }
  }
  return parseLegacyProse(content)
}

/**  * Legacy prose fallback: `This is an output from background command (pid {d}, command \`{s}\`):` +
 * first-to-last `"{3,5}` fence slice. The body passes through verbatim (trimmed) — the real
 * envelope never had a header line inside the fences. */
function parseLegacyProse(content: string): ParsedBackgroundCommandOutput | null {
  if (!content.startsWith(LEGACY_PREFIX)) return null
  // Real envelope: `(pid {d}, command \`{s}\`)` — the closing paren comes
  // after the command, so only anchor on `(pid {digits}`.
  const pidMatch = content.match(/\(pid (\d+)/)
  if (!pidMatch) return null
  const pid = pidMatch[1]!
  const afterPid = content.slice((pidMatch.index ?? 0) + pidMatch[0].length)
  const openTick = afterPid.indexOf('`')
  if (openTick === -1) return null
  const closeTick = afterPid.indexOf('`', openTick + 1)
  if (closeTick === -1) return null
  const command = afterPid.slice(openTick + 1, closeTick)
  const fences = [...content.matchAll(LEGACY_FENCE_RE)]
  if (fences.length < 2) return null
  const first = fences[0]!
  const last = fences[fences.length - 1]!
  const bodyStart = (first.index ?? 0) + first[0].length
  const bodyEnd = last.index ?? content.length
  if (bodyEnd < bodyStart) return null
  return { pid, command, body: content.slice(bodyStart, bodyEnd).trim(), truncated: false, logPath: null }
}

/**  * Re-emit a parsed background completion as the foreground shell XML envelope. `command`/`stdout`
 * are XML-escaped; `stderr` is empty (the background logger merges streams); `truncated` comes from
 * the envelope. */
export function backgroundToShellXml(parsed: ParsedBackgroundCommandOutput): string {
  return (
    `<command>${escapeXml(parsed.command)}</command>` +
    `<stdout>${escapeXml(parsed.body)}</stdout>` +
    `<stderr></stderr>` +
    `<exit_code></exit_code>` +
    `<truncated>${parsed.truncated}</truncated>` +
    `<timeout>false</timeout>` +
    `<stdout_lines></stdout_lines>` +
    `<stderr_lines></stderr_lines>`
  )
}
