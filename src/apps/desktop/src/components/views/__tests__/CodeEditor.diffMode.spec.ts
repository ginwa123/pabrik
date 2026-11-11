/** The code editor's diff view has two layouts — Unified and Split — and the choice sticks. */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import CodeEditor from '../CodeEditor.vue'

const store: Record<string, string> = {}

const stubLocalStorage = () => {
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => (k in store ? store[k] : null),
    setItem: (k: string, v: string) => {
      store[k] = String(v)
    },
    removeItem: (k: string) => {
      delete store[k]
    },
    clear: () => {
      for (const k in store) delete store[k]
    },
    key: () => null,
    length: 0,
  })
}

const DIFF = [
  'diff --git a/sample.ts b/sample.ts',
  '--- a/sample.ts',
  '+++ b/sample.ts',
  '@@ -1,3 +1,3 @@',
  ' keep',
  '-old',
  '+new',
].join('\n')

const mountDiff = () =>
  mount(CodeEditor, {
    props: {
      filePath: '/w/sample.ts',
      fileName: 'sample.ts',
      cwd: '/w',
      content: 'keep\nnew\n',
      diffText: DIFF,
      blame: [],
      initialDiff: true,
    },
  })

describe('CodeEditor diff layout', () => {
  beforeEach(() => {
    stubLocalStorage()
    localStorage.clear()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('opens on Unified and renders the hunks', () => {
    const wrapper = mountDiff()

    expect(wrapper.find('[data-testid="code-diff-mode"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="code-diff-view"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-diff-split"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="code-diff-view"]').text()).toContain('new')
  })

  it('switches to Split and renders the side-by-side table', async () => {
    const wrapper = mountDiff()

    await wrapper.get('[data-testid="code-diff-mode-split"]').trigger('click')

    expect(wrapper.find('[data-testid="sidebar-diff-split"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="code-diff-view"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="sidebar-diff-split"]').text()).toContain('Before (old)')
    expect(wrapper.get('[data-testid="sidebar-diff-split"]').text()).toContain('After (new)')
  })

  it('remembers the choice for the next diff', async () => {
    const first = mountDiff()
    await first.get('[data-testid="code-diff-mode-split"]').trigger('click')
    expect(localStorage.getItem('pabrik.centerdiff.mode')).toBe('split')

    const second = mountDiff()
    expect(second.find('[data-testid="sidebar-diff-split"]').exists()).toBe(true)
    expect(second.find('[data-testid="code-diff-view"]').exists()).toBe(false)
  })

  it('goes back to Unified when asked', async () => {
    localStorage.setItem('pabrik.centerdiff.mode', 'split')
    const wrapper = mountDiff()
    expect(wrapper.find('[data-testid="sidebar-diff-split"]').exists()).toBe(true)

    await wrapper.get('[data-testid="code-diff-mode-unified"]').trigger('click')

    expect(wrapper.find('[data-testid="code-diff-view"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-diff-split"]').exists()).toBe(false)
    expect(localStorage.getItem('pabrik.centerdiff.mode')).toBe('unified')
  })

  it('hides the layout toggle while the file itself is showing', async () => {
    const wrapper = mountDiff()
    expect(wrapper.find('[data-testid="code-diff-mode"]').exists()).toBe(true)

    await wrapper.get('[data-testid="code-diff-toggle"]').trigger('click')

    expect(wrapper.find('[data-testid="code-diff-mode"]').exists()).toBe(false)
    expect(wrapper.findAll('[data-testid="code-line"]').length).toBeGreaterThan(0)
  })
})
