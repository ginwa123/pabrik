/** One `<skill name="…">` entry of the `<slash_skills>` envelope that
 * `expandSlashSkills` appends to a `/skill-` message: the body the model
 * received, plus its size. This module is pure — no DOM, no state, no throw. */
export interface InvokedSkill {
  name: string
  body: string
  /** UTF-8 byte length of `body` — the unit the server's own accounting uses. */
  bytes: number
  /** Body lines, for the card's per-row "N ln" badge. */
  lines: number
}

/** The result of splitting one message: the human's own text plus the entries. */
export interface SkillEnvelopeSplit {
  /** True only when a well-formed trailing envelope carried at least one skill. */
  hasEnvelope: boolean
  /** The message with the envelope removed; verbatim when there is none. */
  text: string
  skills: InvokedSkill[]
  /** Sum of every entry's bytes — what this turn actually paid for. */
  bytes: number
  /** `bytes / 4`: the character heuristic the composer shows, not a tokenizer. */
  tokens: number
}

const ENVELOPE_TAG = '<slash_skills>'
/** Trailing block only — the server appends it, so text after it is not ours. */
const ENVELOPE_RE = /\n\n<slash_skills>\s*\n?([\s\S]*?)<\/slash_skills>\s*$/
const ENTRY_RE = /<skill name="([^"]*)">([\s\S]*?)<\/skill>/g
const BYTES_PER_TOKEN = 4

const plain = (content: string): SkillEnvelopeSplit => ({
  hasEnvelope: false,
  text: content,
  skills: [],
  bytes: 0,
  tokens: 0,
})

/** Cheap guard for a template `v-if`: one `indexOf`, no parse. */
export function hasSkillEnvelope(content: string | null | undefined): boolean {
  return typeof content === 'string' && content.includes(ENVELOPE_TAG)
}

/** Split one message into the human's text and the skills the server loaded.
 * Anything surprising (a tag that is not a trailing envelope, junk between the
 * entries) falls back to the verbatim text, so the bubble never loses a word. */
export function splitSkillEnvelope(content: string): SkillEnvelopeSplit {
  if (!hasSkillEnvelope(content)) return plain(content)
  const match = ENVELOPE_RE.exec(content)
  if (!match || match.index === undefined) return plain(content)
  const skills = parseEntries(match[1] ?? '')
  if (skills === null || skills.length === 0) return plain(content)
  const bytes = skills.reduce((sum, skill) => sum + skill.bytes, 0)
  return {
    hasEnvelope: true,
    text: content.slice(0, match.index),
    skills,
    bytes,
    tokens: Math.round(bytes / BYTES_PER_TOKEN),
  }
}

/** The entries of one envelope body, or null when the block holds anything
 * that is not an entry — a truncated write or a body carrying a closing tag. */
function parseEntries(inner: string): InvokedSkill[] | null {
  const out: InvokedSkill[] = []
  let consumed = 0
  for (const match of inner.matchAll(ENTRY_RE)) {
    const at = match.index ?? 0
    if (inner.slice(consumed, at).trim() !== '') return null
    consumed = at + match[0].length
    const name = (match[1] ?? '').trim()
    if (name === '') return null
    const body = match[2] ?? ''
    out.push({ name, body, bytes: utf8Bytes(body), lines: body.split('\n').length })
  }
  return inner.slice(consumed).trim() === '' ? out : null
}

function utf8Bytes(text: string): number {
  return new TextEncoder().encode(text).length
}

/** Bytes as `13.0 KB` (1000 and up) or `812 B`. */
export function formatBytes(bytes: number): string {
  if (bytes >= 1000) return `${(bytes / 1000).toFixed(1)} KB`
  return `${bytes} B`
}

/** The ÷4 estimate as `≈3.3k tok` or `≈437 tok`. */
export function formatTokenEstimate(bytes: number): string {
  const tokens = Math.round(bytes / BYTES_PER_TOKEN)
  if (tokens >= 1000) return `≈${(tokens / 1000).toFixed(1)}k tok`
  return `≈${tokens} tok`
}

/** The card header's one-glance cost: `13.0 KB · ≈3.3k tok`. */
export function formatSkillCost(bytes: number): string {
  return `${formatBytes(bytes)} · ${formatTokenEstimate(bytes)}`
}
