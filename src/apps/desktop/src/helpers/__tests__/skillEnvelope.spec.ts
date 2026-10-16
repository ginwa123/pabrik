/** Behaviour of the `<slash_skills>` parser: what the human typed, what the
 * server appended, and the exact numbers the transcript card puts on screen.
 * The envelope shape is the one `slash_skill_expand.zig` writes. */
import { describe, expect, it } from 'vitest'

import {
  formatBytes,
  formatSkillCost,
  formatTokenEstimate,
  hasSkillEnvelope,
  splitSkillEnvelope,
} from '../skillEnvelope'

const BODY_ONE = [
  '# Deterministic Unit Tests',
  '',
  '- test behaviour',
  '- inject hidden inputs',
].join('\n')
const BODY_TWO = 'No comments unless the why is non-obvious.'

/** Exactly the block the server appends: a blank line, the tag, one line per
 * entry, then the closing tag — nothing after it. */
const append = (text: string, entries: Array<[string, string]>): string => {
  const block = entries.map(([name, body]) => `<skill name="${name}">${body}</skill>`).join('\n')
  return `${text}\n\n<slash_skills>\n${block}\n</slash_skills>`
}

describe('splitSkillEnvelope', () => {
  it('leaves a message with no envelope exactly as it was typed', () => {
    const typed = 'fix the login bug\n/not-a-skill-token'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
    expect(split.skills).toEqual([])
    expect(split.bytes).toBe(0)
    expect(split.tokens).toBe(0)
  })

  it('splits the human text from the skills the server appended', () => {
    const typed = '/skill-behavior-unit-tests /skill-no-comments'
    const split = splitSkillEnvelope(
      append(typed, [
        ['behavior-unit-tests', BODY_ONE],
        ['no-comments', BODY_TWO],
      ]),
    )
    expect(split.hasEnvelope).toBe(true)
    expect(split.text).toBe(typed)
    expect(split.skills.map((s) => s.name)).toEqual(['behavior-unit-tests', 'no-comments'])
    expect(split.bytes).toBe(BODY_ONE.length + BODY_TWO.length)
    expect(split.tokens).toBe(Math.round((BODY_ONE.length + BODY_TWO.length) / 4))
  })

  it('keeps the order and the size of each entry', () => {
    const split = splitSkillEnvelope(
      append('/skill-b /skill-a', [
        ['b', BODY_TWO],
        ['a', BODY_ONE],
      ]),
    )
    const [first, second] = split.skills
    expect(first?.name).toBe('b')
    expect(first?.body).toBe(BODY_TWO)
    expect(first?.bytes).toBe(BODY_TWO.length)
    expect(first?.lines).toBe(1)
    expect(second?.name).toBe('a')
    expect(second?.lines).toBe(4)
  })

  it('counts bytes, not characters, for a non-ASCII body', () => {
    const body = 'é🙂'
    const split = splitSkillEnvelope(append('/skill-x', [['x', body]]))
    expect(body.length).toBe(3)
    expect(split.skills[0]?.bytes).toBe(6)
    expect(split.bytes).toBe(6)
  })

  it('renders the human text when the envelope carries more than one skill', () => {
    const split = splitSkillEnvelope(
      append('ship it', [
        ['one', BODY_ONE],
        ['two', BODY_TWO],
        ['three', 'x'],
      ]),
    )
    expect(split.skills).toHaveLength(3)
    expect(split.text).toBe('ship it')
  })

  it('leaves a message alone when the tag is not a trailing block', () => {
    const typed = 'then the model says <slash_skills> and reads the body below'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
  })

  it('leaves a message alone when prose follows the closing tag', () => {
    const typed = append('/skill-x', [['x', BODY_ONE]]) + '\nand then I asked for more'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
  })

  it('leaves a message alone when the block carries no entry', () => {
    const typed = '/skill-x\n\n<slash_skills>\n</slash_skills>'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
  })

  it('gives up rather than lose a body that holds a closing tag', () => {
    const typed = append('/skill-x', [['x', `text </skill> more text`]])
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
  })

  it('gives up when junk sits between two entries', () => {
    const typed =
      '/skill-x\n\n<slash_skills>\n<skill name="x">a</skill>\nnot an entry\n<skill name="y">b</skill>\n</slash_skills>'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(false)
    expect(split.text).toBe(typed)
  })

  it('reads an envelope with no trailing newline', () => {
    const typed = '/skill-x\n\n<slash_skills>\n<skill name="x">a</skill></slash_skills>'
    const split = splitSkillEnvelope(typed)
    expect(split.hasEnvelope).toBe(true)
    expect(split.text).toBe('/skill-x')
    expect(split.skills[0]?.body).toBe('a')
  })
})

describe('hasSkillEnvelope', () => {
  it('is false for undefined, null and empty content', () => {
    expect(hasSkillEnvelope(undefined)).toBe(false)
    expect(hasSkillEnvelope(null)).toBe(false)
    expect(hasSkillEnvelope('')).toBe(false)
  })

  it('is true for the tag anywhere in the message, so the card can decide', () => {
    expect(hasSkillEnvelope(append('/skill-x', [['x', 'a']]))).toBe(true)
    // True here too: the guard is cheap on purpose, the parse is what falls back.
    expect(hasSkillEnvelope('what is <slash_skills>?')).toBe(true)
  })
})

describe('the size labels the card shows', () => {
  it('writes bytes under a kilobyte and kilobytes above it', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(999)).toBe('999 B')
    expect(formatBytes(1000)).toBe('1.0 KB')
    expect(formatBytes(13020)).toBe('13.0 KB')
  })

  it('writes the ÷4 estimate in tokens, thousands above a thousand', () => {
    expect(formatTokenEstimate(400)).toBe('≈100 tok')
    expect(formatTokenEstimate(996)).toBe('≈249 tok')
    expect(formatTokenEstimate(13020)).toBe('≈3.3k tok')
  })

  it('joins both into the header cost line', () => {
    expect(formatSkillCost(13020)).toBe('13.0 KB · ≈3.3k tok')
    expect(formatSkillCost(812)).toBe('812 B · ≈203 tok')
  })
})
