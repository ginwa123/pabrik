/** SkillInvocationCard renders the `<slash_skills>` envelope the server appends
 * to a `/skill-` message: the human's words stay primary, the bodies collapse
 * behind one header. Purely presentational, so only the clipboard is stubbed. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'

import SkillInvocationCard from '../SkillInvocationCard.vue'

const BODY_ONE = [
  '# Deterministic Unit Tests',
  '',
  '- test behaviour',
  '- inject hidden inputs',
].join('\n')
const BODY_TWO = 'No comments unless the why is non-obvious.'

const OUTLINED_BODY = [
  '# Skill',
  'intro line',
  '## When to Use',
  'load it when asked',
  '### Deeper',
  'a nested note',
  '## Core practices',
  'body',
].join('\n')

const append = (text: string, entries: Array<[string, string]>): string => {
  const block = entries.map(([name, body]) => `<skill name="${name}">${body}</skill>`).join('\n')
  return `${text}\n\n<slash_skills>\n${block}\n</slash_skills>`
}

const TYPED = '/skill-behavior-unit-tests /skill-no-comments'
const TWO_SKILLS = append(TYPED, [
  ['behavior-unit-tests', BODY_ONE],
  ['no-comments', BODY_TWO],
])

const clipboardWrites: string[] = []

describe('SkillInvocationCard', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  const mountCard = (content: string) => {
    wrapper = mount(SkillInvocationCard, { props: { content } })
    return wrapper
  }

  const openCard = async (w: ReturnType<typeof mount>) => {
    const head = w.find('[data-testid="sic-head"]')
    if (!head.exists()) throw new Error('expected the card header')
    await head.trigger('click')
    return w
  }

  const mountAndOpen = async (content: string) => openCard(mountCard(content))

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    clipboardWrites.length = 0
    vi.restoreAllMocks()
  })

  it("keeps the human's own text and never prints the envelope", () => {
    const text = mountCard(TWO_SKILLS).text()
    expect(text).toContain(TYPED)
    expect(text).not.toContain('<slash_skills>')
    expect(text).not.toContain('<skill name=')
    expect(text).not.toContain(BODY_ONE)
  })

  it('summarises the invocation: count, cost and rendered lines', () => {
    const w = mountCard(TWO_SKILLS)
    expect(w.find('[data-testid="sic-count"]').text()).toBe('2 skills')
    // 67 B (BODY_ONE, 4 lines) + 42 B (BODY_TWO) = 109 B, ÷4 ≈ 27 tokens
    expect(w.find('[data-testid="sic-cost"]').text()).toBe('109 B · ≈27 tok')
    expect(w.find('[data-testid="sic-lines"]').text()).toBe('5 lines')
    expect(w.find('[data-testid="sic-human"]').text()).toBe(TYPED)
  })

  it('starts collapsed and lists one row per skill once opened', async () => {
    const w = mountCard(TWO_SKILLS)
    expect(w.find('[data-testid="sic-body"]').exists()).toBe(false)
    await openCard(w)
    const rows = w.findAll('[data-testid="sic-row"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]?.text()).toContain('behavior-unit-tests')
    expect(rows[1]?.text()).toContain('no-comments')
    expect(rows[0]?.text()).toContain('67 B · 4 ln')
  })

  it('opens a row on click and closes it again', async () => {
    const w = await mountAndOpen(TWO_SKILLS)
    const head = w.findAll('[data-testid="sic-row-head"]')[0]
    if (!head) throw new Error('expected a row header')
    expect(w.findAll('[data-testid="sic-row-body"]')).toHaveLength(0)
    await head.trigger('click')
    expect(w.findAll('[data-testid="sic-row-body"]')).toHaveLength(1)
    expect(w.find('[data-testid="sic-body-text"]').text()).toContain('test behaviour')
    await head.trigger('click')
    expect(w.findAll('[data-testid="sic-row-body"]')).toHaveLength(0)
  })

  it('outlines the body from its own headings', async () => {
    const w = await mountAndOpen(append('/skill-x', [['x', OUTLINED_BODY]]))
    const head = w.findAll('[data-testid="sic-row-head"]')[0]
    if (!head) throw new Error('expected a row header')
    await head.trigger('click')
    const items = w.findAll('[data-testid="sic-outline"] li')
    expect(items.map((i) => i.text())).toEqual(['When to Use', 'Deeper', 'Core practices'])
  })

  it('clamps a long body to a dozen lines and offers the rest', async () => {
    const long = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join('\n')
    const w = await mountAndOpen(append('/skill-x', [['x', long]]))
    const head = w.findAll('[data-testid="sic-row-head"]')[0]
    if (!head) throw new Error('expected a row header')
    await head.trigger('click')
    const preview = w.find('[data-testid="sic-body-text"]').text()
    expect(preview.split('\n')).toHaveLength(13)
    expect(preview).toContain('line 12')
    expect(preview).not.toContain('line 13')
    const showAll = w.find('[data-testid="sic-show-all"]')
    expect(showAll.text()).toBe('Show all 30 lines')
    await showAll.trigger('click')
    expect(w.find('[data-testid="sic-body-text"]').text()).toContain('line 30')
    expect(w.find('[data-testid="sic-show-all"]').text()).toBe('Show less')
  })

  it('copies a body and says so', async () => {
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value: {
        writeText: vi.fn(async (s: string) => {
          clipboardWrites.push(s)
        }),
      },
    })
    const w = await mountAndOpen(append('/skill-x', [['no-comments', BODY_TWO]]))
    const head = w.findAll('[data-testid="sic-row-head"]')[0]
    if (!head) throw new Error('expected a row header')
    await head.trigger('click')
    const copy = w.find('[data-testid="sic-copy"]')
    expect(copy.text()).toBe('Copy body')
    await copy.trigger('click')
    expect(clipboardWrites).toEqual([BODY_TWO])
    expect(w.find('[data-testid="sic-copy"]').text()).toBe('Copied')
  })

  it('falls back to the whole message when the envelope cannot be parsed', () => {
    const raw = append(TYPED, [['x', 'a']]) + '\nand one more thought'
    const w = mountCard(raw)
    expect(w.find('[data-testid="sic-head"]').exists()).toBe(false)
    const fallback = w.find('[data-testid="sic-fallback"]')
    expect(fallback.exists()).toBe(true)
    expect(fallback.text()).toBe(raw)
  })

  it('renders a plain message as its own text', () => {
    const w = mountCard('just a normal message')
    expect(w.find('[data-testid="sic-fallback"]').text()).toBe('just a normal message')
    expect(w.find('[data-testid="sic-head"]').exists()).toBe(false)
  })
})
