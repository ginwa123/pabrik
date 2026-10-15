/** Code color in the diff review. `SidebarDiffView` used to render every code line through
 * `v-html="escapeDiffHtml(line.content)"` — escaped, but monochrome. */

/** These tests assert the behaviour that replaced it: every rendered line is split into `tok-*`
 * spans by the shared highlighter, in BOTH the unified and the split render, while the row
 * background stays the source of truth for added/removed. */

/** The plaintext case is asserted too, because that is the contract that makes this change safe: an
 * unknown extension must render exactly as it did before (one `tok-plain` span per line, no color). */
import { describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'
import type { ParsedDiffLine } from '../chat_right_sidebar/parseUnifiedDiff'

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual }
})

const TS_LINES: ParsedDiffLine[] = [
  { type: 'hunk', content: '@@ -1,3 +1,3 @@', lineIndex: 0 },
  { type: 'context', content: 'const kept = 1', oldLineNum: 1, newLineNum: 1, lineIndex: 1 },
  { type: 'remove', content: 'const gone = 2', oldLineNum: 2, lineIndex: 2 },
  { type: 'add', content: 'const added = 3', newLineNum: 2, lineIndex: 3 },
  { type: 'context', content: 'run()', oldLineNum: 3, newLineNum: 3, lineIndex: 4 },
]

function mountView(extra: Record<string, unknown> = {}) {
  return mount(SidebarDiffView, {
    props: {
      path: 'src/demo.ts',
      lines: TS_LINES,
      added: 1,
      removed: 1,
      staged: false,
      loading: false,
      error: null,
      cwd: '/repo',
      showBack: false,
      ...extra,
    },
  })
}

describe('SidebarDiffView — code color (unified)', () => {
  it('tokenizes every code line, not just the changed ones', () => {
    const wrapper = mountView()
    expect(wrapper.findAll('.tok-keyword').map((s) => s.text())).toEqual([
      'const',
      'const',
      'const',
    ])
    expect(wrapper.findAll('.tok-number').map((s) => s.text())).toEqual(['1', '2', '3'])
  })

  it('keeps the line text intact — highlighting only splits it', () => {
    const wrapper = mountView()
    for (const line of TS_LINES) {
      expect(wrapper.text()).toContain(line.content)
    }
  })

  it('keeps the +/− change sign glued to the code it marks', () => {
    const wrapper = mountView()
    // The sign is its own span and the code is now one span per token, so
    // this also pins the whitespace contract: a newline/indent between the
    // two inline spans must NOT reach the rendered line (Vue's condensed
    // whitespace drops it), or every diff row would gain a stray space.
    expect(wrapper.text()).toContain('+const added = 3')
    expect(wrapper.text()).toContain('−const gone = 2')
  })

  it('renders an unknown extension as plain text — no color, same text', () => {
    const wrapper = mountView({ path: 'notes.log' })
    expect(wrapper.findAll('.tok-keyword')).toHaveLength(0)
    expect(wrapper.findAll('.tok-number')).toHaveLength(0)
    expect(wrapper.findAll('.tok-plain').length).toBeGreaterThan(0)
    expect(wrapper.text()).toContain('const gone = 2')
  })

  it('never injects markup from the diff content (tokens are text nodes)', () => {
    const evil = '<img src=x onerror="alert(1)"><script>bad()</script>'
    const wrapper = mountView({
      path: 'a.ts',
      lines: [{ type: 'add', content: evil, newLineNum: 1, lineIndex: 0 }],
    })
    expect(wrapper.find('img').exists()).toBe(false)
    expect(wrapper.find('script').exists()).toBe(false)
    expect(wrapper.text()).toContain(evil)
  })
})

describe('SidebarDiffView — code color (split)', () => {
  it('tokenizes both sides of a changed row', () => {
    const wrapper = mountView({ mode: 'split' })
    const changed = wrapper.findAll('tr[data-changed="true"]')
    expect(changed.length).toBeGreaterThan(0)
    const oldCell = changed[0]!.get('td[data-side="old"]')
    const newCell = changed[0]!.get('td[data-side="new"]')
    expect(oldCell.find('.tok-keyword').text()).toBe('const')
    expect(newCell.find('.tok-keyword').text()).toBe('const')
    expect(oldCell.text()).toContain('const gone = 2')
    expect(newCell.text()).toContain('const added = 3')
  })

  it('renders an unknown extension as plain text in split view too', () => {
    const wrapper = mountView({ mode: 'split', path: 'blob.bin' })
    expect(wrapper.findAll('.tok-keyword')).toHaveLength(0)
    expect(wrapper.findAll('.tok-plain').length).toBeGreaterThan(0)
    expect(wrapper.text()).toContain('const gone = 2')
  })
})
