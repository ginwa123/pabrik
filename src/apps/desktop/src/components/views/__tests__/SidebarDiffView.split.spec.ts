/** SidebarDiffView's three view controls, as BEHAVIOUR: - `mode`      — 'unified' (default, today's
 * render) vs 'split' - `collapsed` — header only, driven from outside so it survives a body unmount
 * - `wholeFile` — the file's full context, fetched through `wholeFileDiff` (mocked here. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'
import SplitDiffTable from '../chat_right_sidebar/SplitDiffTable.vue'
import { clearWholeFileDiffCache } from '../chat_right_sidebar/wholeFileDiff'
import type { ParsedDiffLine } from '../chat_right_sidebar/parseUnifiedDiff'
import * as api from '../../../api'

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, getGitWholeFileDiff: vi.fn() }
})

const LINES: ParsedDiffLine[] = [
  { type: 'hunk', content: '@@ -24,3 +24,2 @@ type plan struct {', lineIndex: 0 },
  { type: 'context', content: 'IsBalanced bool', oldLineNum: 24, newLineNum: 24, lineIndex: 1 },
  { type: 'remove', content: 'gone []uuid.UUID', oldLineNum: 25, lineIndex: 2 },
  { type: 'remove', content: 'extra bool', oldLineNum: 26, lineIndex: 3 },
  { type: 'add', content: 'kept []uuid.UUID', newLineNum: 25, lineIndex: 4 },
  { type: 'context', content: '}', oldLineNum: 27, newLineNum: 26, lineIndex: 5 },
]

function mountView(extra: Record<string, unknown> = {}) {
  return mount(SidebarDiffView, {
    props: {
      path: 'helper.go',
      lines: LINES,
      added: 1,
      removed: 2,
      staged: false,
      loading: false,
      error: null,
      cwd: '/repo',
      showBack: false,
      ...extra,
    },
  })
}

beforeEach(() => {
  clearWholeFileDiffCache()
  vi.mocked(api.getGitWholeFileDiff).mockReset()
})
afterEach(() => {
  vi.restoreAllMocks()
})

describe('SidebarDiffView — split render', () => {
  it('stays unified by default (no mode prop = today’s render)', () => {
    const wrapper = mountView()
    expect(wrapper.find('[data-testid="sidebar-diff-split"]').exists()).toBe(false)
    expect(wrapper.find('.diff-wrap table').exists()).toBe(true)
  })

  it('renders the side-by-side table with a Before/After strip and five columns per row', () => {
    const wrapper = mountView({ mode: 'split' })
    const table = wrapper.findComponent(SplitDiffTable)
    expect(table.exists()).toBe(true)
    const heads = table.findAll('.split-heads div').map((d) => d.text())
    expect(heads).toEqual(['Before (old)', 'After (new)'])
    // colgroup is what keeps the two gutters at 42px under table-layout:fixed
    expect(table.findAll('colgroup col')).toHaveLength(5)
    const changed = table.findAll('tr[data-changed="true"]')
    expect(changed).toHaveLength(2)
    for (const row of changed) expect(row.findAll('td')).toHaveLength(5)
  })

  it('pairs 2 removals with 1 insertion, giving the unpaired side a FILLER (never a shifted number)', () => {
    const wrapper = mountView({ mode: 'split' })
    const changed = wrapper.findAll('tr[data-changed="true"]')
    // row 0: old 25 | new 25 ; row 1: old 26 | filler
    const first = changed[0]!.findAll('td').map((td) => td.text().trim())
    expect(first[0]).toBe('25')
    expect(first[1]).toContain('gone []uuid.UUID')
    expect(first[3]).toBe('25')
    expect(first[4]).toContain('kept []uuid.UUID')
    const second = changed[1]!.findAll('td').map((td) => td.text().trim())
    expect(second[0]).toBe('26')
    expect(second[1]).toContain('extra bool')
    expect(second[3]).toBe('')
    // The filler cell carries the striped class — an empty box, not a line.
    expect(changed[1]!.findAll('td.split-blank').length).toBeGreaterThan(0)
  })

  it('tints changed rows with the theme red/green, never a hardcoded grey', () => {
    const wrapper = mountView({ mode: 'split' })
    const changed = wrapper.findAll('tr[data-changed="true"]')
    // Row 0 pairs a removal with an insertion: both sides carry their tint.
    const first = changed[0]!.findAll('td')
    expect(first[0]!.attributes('style')).toContain('var(--color-red)')
    expect(first[1]!.attributes('style')).toContain('var(--color-red)')
    expect(first[3]!.attributes('style')).toContain('var(--color-green)')
    expect(first[4]!.attributes('style')).toContain('var(--color-green)')
    // Row 1 is a lone removal: the old side is tinted, the new side is the
    // untinted striped filler — it must not borrow either tint.
    const second = changed[1]!.findAll('td')
    expect(second[0]!.attributes('style')).toContain('var(--color-red)')
    expect(second[1]!.attributes('style')).toContain('var(--color-red)')
    expect(second[3]!.attributes('style') ?? '').not.toContain('var(--color-red)')
    expect(second[3]!.attributes('style') ?? '').not.toContain('var(--color-green)')
    expect(second[4]!.attributes('style') ?? '').not.toContain('var(--color-red)')
    expect(second[4]!.attributes('style') ?? '').not.toContain('var(--color-green)')
  })

  it('keeps the hunk header text in the full-width row', () => {
    const wrapper = mountView({ mode: 'split' })
    expect(wrapper.get('[data-testid="split-hunk"]').text()).toContain('@@ -24,3 +24,2 @@')
  })
})

describe('SidebarDiffView — collapse', () => {
  it('renders the header only when collapsed', () => {
    const wrapper = mountView({ collapsed: true })
    expect(wrapper.find('[data-testid="sidebar-diff-selected"]').exists()).toBe(true)
    expect(wrapper.find('.diff-wrap').exists()).toBe(false)
    expect(
      wrapper.find('[data-testid="sidebar-diff-toggle-collapse"]').attributes('aria-expanded'),
    ).toBe('false')
  })

  it('emits toggle-collapse from the header chevron', async () => {
    const wrapper = mountView()
    await wrapper.get('[data-testid="sidebar-diff-toggle-collapse"]').trigger('click')
    expect(wrapper.emitted('toggle-collapse')).toHaveLength(1)
  })
})

describe('SidebarDiffView — whole-file scope', () => {
  it('does not fetch unless the scope is asked for', () => {
    mountView()
    expect(api.getGitWholeFileDiff).not.toHaveBeenCalled()
  })

  it('fetches once and renders the whole file’s lines, changes still marked', async () => {
    vi.mocked(api.getGitWholeFileDiff).mockResolvedValue({
      diffs: [
        {
          path: 'helper.go',
          staged: false,
          diff_content: [
            'diff --git a/helper.go b/helper.go',
            '--- a/helper.go',
            '+++ b/helper.go',
            '@@ -1,4 +1,4 @@',
            ' package plan',
            '-old line',
            '+new line',
            ' tail',
            '',
          ].join('\n'),
        },
      ],
    } as never)

    const wrapper = mountView({ wholeFile: true })
    await flushPromises()

    expect(api.getGitWholeFileDiff).toHaveBeenCalledTimes(1)
    expect(api.getGitWholeFileDiff).toHaveBeenCalledWith('/repo', 'helper.go', false)
    // 'package plan' only exists in the whole-file body.
    expect(wrapper.text()).toContain('package plan')
    expect(wrapper.find('[data-testid="sidebar-diff-whole-file-notice"]').exists()).toBe(false)
  })

  it('renders the refusal notice AND keeps the hunks when the server refuses a too-large file', async () => {
    vi.mocked(api.getGitWholeFileDiff).mockResolvedValue({
      diffs: [{ path: 'helper.go', staged: false, diff_content: '' }],
      whole_file_refused: true,
    } as never)

    const wrapper = mountView({ wholeFile: true })
    await flushPromises()

    const notice = wrapper.get('[data-testid="sidebar-diff-whole-file-notice"]')
    expect(notice.text()).toContain('too large')
    // Refusing to serve the file must not cost the user their diff.
    expect(wrapper.text()).toContain('extra bool')
    expect(wrapper.find('[data-testid="sidebar-diff-whole-file-open"]').exists()).toBe(true)
  })

  it('an untracked file is already whole — locked scope, and NO request', async () => {
    const wrapper = mountView({ untracked: true, wholeFile: true })
    await flushPromises()
    expect(api.getGitWholeFileDiff).not.toHaveBeenCalled()
    expect(wrapper.get('[data-testid="sidebar-diff-scope-whole"]').attributes('title')).toContain(
      'already is the whole file',
    )
    expect(
      wrapper.get('[data-testid="sidebar-diff-scope-diff"]').attributes('disabled'),
    ).toBeDefined()
  })

  it('surfaces a failed fetch instead of pretending the file has no changes', async () => {
    vi.mocked(api.getGitWholeFileDiff).mockRejectedValue(new Error('boom'))
    const wrapper = mountView({ wholeFile: true })
    await flushPromises()
    const notice = wrapper.get('[data-testid="sidebar-diff-whole-file-notice"]')
    expect(notice.text()).toContain('boom')
    expect(wrapper.find('[data-testid="sidebar-diff-whole-file-retry"]').exists()).toBe(true)
  })
})
