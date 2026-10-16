/** Inline comment threads on the sidebar diff. - Saved comments render as thread rows docked after
 * their lines, survive remount via localStorage, support Edit (reopen box at the exact range) and
 * Delete, and escape message HTML. - Clicking a diff row opens the box. */
import { describe, expect, it, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'
import DiffCommentBox, { buildDraftKey } from '../chat_right_sidebar/DiffCommentBox.vue'
import type { ParsedDiffLine } from '../chat_right_sidebar/parseUnifiedDiff'
import { makeLocalStorageStub } from '../../../__tests__/helpers'

const CWD = '/repo'
const PATH = 'src/reviewed.ts'

// Lines spanning 17-30. The seeded 20-26 range anchors its thread after
// the new-26 row; 28/29 sit outside it.
const LINES: ParsedDiffLine[] = [
  { type: 'hunk', content: '@@ -17,14 +17,14 @@', lineIndex: 0 },
  { type: 'context', content: 'ctx-17', oldLineNum: 17, newLineNum: 17, lineIndex: 1 },
  { type: 'context', content: 'ctx-18', oldLineNum: 18, newLineNum: 18, lineIndex: 2 },
  { type: 'context', content: 'ctx-19', oldLineNum: 19, newLineNum: 19, lineIndex: 3 },
  { type: 'remove', content: 'old-20', oldLineNum: 20, lineIndex: 4 },
  { type: 'add', content: 'new-21', newLineNum: 21, lineIndex: 5 },
  { type: 'add', content: 'new-22', newLineNum: 22, lineIndex: 6 },
  { type: 'context', content: 'ctx-23', oldLineNum: 23, newLineNum: 23, lineIndex: 7 },
  { type: 'remove', content: 'old-24', oldLineNum: 24, lineIndex: 8 },
  { type: 'context', content: 'ctx-25', oldLineNum: 25, newLineNum: 25, lineIndex: 9 },
  { type: 'add', content: 'new-26', newLineNum: 26, lineIndex: 10 },
  { type: 'context', content: 'ctx-27', oldLineNum: 27, newLineNum: 27, lineIndex: 11 },
  { type: 'add', content: 'new-28', newLineNum: 28, lineIndex: 12 },
  { type: 'remove', content: 'old-29', oldLineNum: 29, lineIndex: 13 },
  { type: 'context', content: 'ctx-30', oldLineNum: 30, newLineNum: 30, lineIndex: 14 },
]

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
}

function seed(cwd: string, path: string, start: number, end: number, message: string): void {
  localStorage.setItem(
    buildDraftKey(cwd, path, start, end),
    JSON.stringify({ message, savedAt: 1 }),
  )
}

function mountView() {
  return mount(SidebarDiffView, {
    props: {
      path: PATH,
      lines: LINES,
      added: 4,
      removed: 3,
      staged: false,
      loading: false,
      error: null,
      cwd: CWD,
    },
  })
}

function rowByText(wrapper: ReturnType<typeof mountView>, text: string) {
  const row = wrapper.findAll('tr').find((r) => r.text().includes(text))
  if (row == null) throw new Error(`expected a row containing ${text}`)
  return row
}

beforeEach(() => {
  installStorage()
})

describe('SidebarDiffView row clicks', () => {
  it('clicking a row reopens the box with the saved draft', async () => {
    // Clicking new-22 opens a +-3 context window over rows 3..9, i.e.
    // lines 19-25 — seed that deterministic key so the draft reloads.
    seed(CWD, PATH, 19, 25, 'window draft nineteen twenty-five')
    const wrapper = mountView()
    await rowByText(wrapper, 'new-22').trigger('click')
    await flushPromises()
    const box = wrapper.findComponent(DiffCommentBox)
    expect(box.exists()).toBe(true)
    expect(box.props('startLine')).toBe(19)
    expect(box.props('endLine')).toBe(25)
    expect((box.get('[data-testid=diff-comment-input]').element as HTMLTextAreaElement).value).toBe(
      'window draft nineteen twenty-five',
    )
  })
})

describe('SidebarDiffView inline comment threads', () => {
  function seedFull(start: number, end: number, message: string, context: string): void {
    localStorage.setItem(
      buildDraftKey(CWD, PATH, start, end),
      JSON.stringify({ message, savedAt: 1234567890, context }),
    )
  }

  it('renders a thread row after the last covered table row', () => {
    seed(CWD, PATH, 20, 26, 'thread body twenty-six')
    const wrapper = mountView()
    const threads = wrapper.findAll('[data-testid="diff-comment-thread"]')
    expect(threads).toHaveLength(1)
    expect(threads[0]!.text()).toContain('Comment on lines 20–26')
    expect(threads[0]!.get('[data-testid="diff-comment-message"]').text()).toBe(
      'thread body twenty-six',
    )
    const rows = wrapper.findAll('tr')
    const idx26 = rows.findIndex((r) => r.text().includes('new-26'))
    const idxThread = rows.findIndex((r) => r.attributes('data-testid') === 'diff-comment-thread')
    expect(idx26).toBeGreaterThanOrEqual(0)
    expect(idxThread).toBe(idx26 + 1)
  })

  it('Edit/Delete links use an explicit readable color', () => {
    seed(CWD, PATH, 20, 26, 'readable links')
    const wrapper = mountView()
    for (const tid of ['diff-comment-edit', 'diff-comment-delete']) {
      const style = wrapper.get(`[data-testid="${tid}"]`).attributes('style') ?? ''
      expect(style).toContain('--color-blue')
    }
  })

  it('skips threads with no matching row', () => {
    seed(CWD, PATH, 100, 110, 'stale note')
    const wrapper = mountView()
    expect(wrapper.findAll('[data-testid="diff-comment-thread"]')).toHaveLength(0)
  })

  it('survives remount', () => {
    seed(CWD, PATH, 20, 26, 'persistent note')
    expect(mountView().findAll('[data-testid="diff-comment-thread"]')).toHaveLength(1)
    expect(mountView().find('[data-testid="diff-comment-message"]').text()).toBe('persistent note')
  })

  it('Edit swaps the thread card to the editor in place, no popup', async () => {
    seedFull(20, 26, 'saved thread text', 'saved ctx lines')
    const wrapper = mountView()
    await wrapper.get('[data-testid="diff-comment-edit"]').trigger('click')
    await flushPromises()
    const thread = wrapper.get('[data-testid="diff-comment-thread"]')
    const box = thread.findComponent(DiffCommentBox)
    expect(box.exists()).toBe(true)
    expect(box.props('startLine')).toBe(20)
    expect(box.props('endLine')).toBe(26)
    expect((box.get('[data-testid=diff-comment-input]').element as HTMLTextAreaElement).value).toBe(
      'saved thread text',
    )
    expect(thread.find('[data-testid="diff-comment-cancel"]').exists()).toBe(true)
  })

  it('Cancel closes the editor without changing the thread', async () => {
    seedFull(20, 26, 'keep me', 'saved ctx lines')
    const wrapper = mountView()
    await wrapper.get('[data-testid="diff-comment-edit"]').trigger('click')
    await flushPromises()
    const box = wrapper.findComponent(DiffCommentBox)
    await box.get('[data-testid=diff-comment-input]').setValue('changed mind')
    await wrapper.get('[data-testid="diff-comment-cancel"]').trigger('click')
    await flushPromises()
    expect(wrapper.findComponent(DiffCommentBox).exists()).toBe(false)
    expect(wrapper.get('[data-testid="diff-comment-message"]').text()).toBe('keep me')
  })

  it('Save from inline edit updates the thread and closes the editor', async () => {
    seedFull(20, 26, 'before edit', 'saved ctx lines')
    const wrapper = mountView()
    await wrapper.get('[data-testid="diff-comment-edit"]').trigger('click')
    await flushPromises()
    const box = wrapper.findComponent(DiffCommentBox)
    await box.get('[data-testid=diff-comment-input]').setValue('after edit')
    await box.get('[data-testid=diff-comment-save]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('comment-saved')).toHaveLength(1)
    expect(wrapper.findComponent(DiffCommentBox).exists()).toBe(false)
    expect(wrapper.get('[data-testid="diff-comment-message"]').text()).toBe('after edit')
  })

  it('Delete removes the thread', async () => {
    seed(CWD, PATH, 20, 26, 'doomed note')
    const wrapper = mountView()
    expect(wrapper.findAll('[data-testid="diff-comment-thread"]')).toHaveLength(1)
    await wrapper.get('[data-testid="diff-comment-delete"]').trigger('click')
    await flushPromises()
    expect(wrapper.findAll('[data-testid="diff-comment-thread"]')).toHaveLength(0)
    expect(localStorage.getItem(buildDraftKey(CWD, PATH, 20, 26))).toBeNull()
  })

  it('save closes the popup and renders the thread without remount', async () => {
    const wrapper = mountView()
    await rowByText(wrapper, 'new-28').trigger('click')
    await flushPromises()
    const box = wrapper.findComponent(DiffCommentBox)
    expect(box.exists()).toBe(true)
    await box.get('[data-testid=diff-comment-input]').setValue('fresh thread 28')
    await box.get('[data-testid=diff-comment-save]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('comment-saved')).toHaveLength(1)
    expect(wrapper.findComponent(DiffCommentBox).exists()).toBe(false)
    const threads = wrapper.findAll('[data-testid="diff-comment-thread"]')
    expect(threads).toHaveLength(1)
    expect(threads[0]!.get('[data-testid="diff-comment-message"]').text()).toBe('fresh thread 28')
  })

  it('Copy writes the formatted markdown to the clipboard', async () => {
    seedFull(20, 26, 'copy me out', 'ctx lines here')
    const written: string[] = []
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      value: {
        writeText: (t: string) => {
          written.push(t)
          return Promise.resolve()
        },
      },
      writable: true,
      configurable: true,
    })
    const wrapper = mountView()
    await wrapper.get('[data-testid="diff-comment-copy"]').trigger('click')
    await flushPromises()
    expect(written).toHaveLength(1)
    expect(written[0]).toContain('## Code Review')
    expect(written[0]).toContain('src/reviewed.ts')
    expect(written[0]).toContain('copy me out')
    expect(wrapper.find('[data-testid="diff-comment-copied"]').exists()).toBe(true)
  })

  it('escapes message HTML', () => {
    seed(CWD, PATH, 20, 26, '<img src=x onerror=alert(1)>')
    const wrapper = mountView()
    const html = wrapper.get('[data-testid="diff-comment-message"]').html()
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img')
  })
})
