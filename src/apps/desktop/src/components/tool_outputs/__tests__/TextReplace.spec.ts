/**
 * Tests for TextReplace.vue — chunks 5+6.
 *
 * Verifies:
 *  - renders the shared ToolCardHeader with the parsed `path` and the success/failure badge
 *  - has `data-testid="text-replace-card"` for E2E selectors
 *  - on success with a diff, expanding renders the shared `<DiffView>` and a click on a
 *    line number forwards `jump-to-line` to the injected editor handler with the
 *    exact (path, cwd, line) triple
 *  - silently no-ops the jump when cwd is missing (graceful fallback)
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, provide } from 'vue'

import TextReplace from '../TextReplace.vue'
import { OPEN_IN_CODE_EDITOR_KEY, type OpenInCodeEditorFn } from '@/composables/useCodeEditor'

// ────────────────────────────────────────────────────────────────────────
// Test helpers
// ────────────────────────────────────────────────────────────────────────
const makeContent = (opts: { path?: string; success?: boolean; error?: string } = {}) => {
  const path = opts.path ?? '/repo/src/foo.ts'
  const success = opts.success ?? true
  if (!success) {
    return {
      path,
      error: opts.error ?? 'string not found',
    }
  }
  return {
    path,
    before: 'line1\nline2',
    after: 'line1\nLINE2-EDITED',
    unified: '@@ -2 +2 @@\n-line2\n+LINE2-EDITED',
    lines_changed: 1,
    error: null,
  }
}

const makeWrapper = (
  props: { content: unknown; cwd?: string; expanded?: boolean },
  provideOpenInEditor?: OpenInCodeEditorFn,
) => {
  if (provideOpenInEditor) {
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          return () => h(TextReplace, props as never)
        },
      }),
    )
  }
  return mount(TextReplace, { props })
}

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
beforeAll(() => {
  // jsdom 29 dropped localStorage from default globals — install a stub.
  // TextReplace itself doesn't read localStorage, but the DiffView child does.
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })
})

describe('TextReplace', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the data-testid and the shared header with the path + success badge', () => {
    wrapper = makeWrapper({ content: makeContent({ path: '/repo/src/foo.ts' }) })
    const card = wrapper.find('[data-testid="text-replace-card"]')
    expect(card.exists()).toBe(true)
    expect(card.text()).toContain('text_replace')
    expect(card.text()).toContain('/repo/src/foo.ts')
    expect(card.text()).toContain('✓')
  })

  it('renders the failure badge + error message on success=false', async () => {
    wrapper = makeWrapper({
      content: makeContent({ success: false, error: 'string not found' }),
      expanded: true,
    })
    expect(wrapper.text()).toContain('✗')
    // Error is rendered inside the body only when expanded.
    expect(wrapper.text()).toContain('Error:')
    expect(wrapper.text()).toContain('string not found')
  })

  it('renders the diff and forwards jump-to-line to the injected editor handler', async () => {
    const calls: { filePath: string; cwd: string; line?: number }[] = []
    const openFn: OpenInCodeEditorFn = vi.fn(async (opts) => {
      calls.push(opts)
    })

    wrapper = makeWrapper(
      { content: makeContent({ path: '/repo/src/foo.ts' }), cwd: '/repo' },
      openFn,
    )
    await wrapper.setProps({ expanded: true })

    // Click an after-side line number (the edited line is line 2).
    // Vue Test Utils' `.find()` only matches single-attribute selectors;
    // combine multiple attributes via `.findAll(...)[0]`.
    const afterLineRows = wrapper.findAll('[data-side="after"][data-line="2"]')
    expect(afterLineRows.length).toBe(1)
    const afterLineRow = afterLineRows[0]!
    await afterLineRow.element
      .querySelector('span:not([data-bg])')!
      .dispatchEvent(new MouseEvent('click', { bubbles: true }))

    // Verify the editor handler was called with the right args.
    expect(calls).toHaveLength(1)
    expect(calls[0]).toEqual({
      filePath: '/repo/src/foo.ts',
      cwd: '/repo',
      line: 2,
    })
  })

  it('does NOT forward jump-to-line when cwd is missing (silent no-op)', async () => {
    const calls: { filePath: string; cwd: string; line?: number }[] = []
    const openFn: OpenInCodeEditorFn = vi.fn(async (opts) => {
      calls.push(opts)
    })

    wrapper = makeWrapper(
      // cwd omitted — TextReplace should not call the handler even if
      // the line-number click registers.
      { content: makeContent({ path: '/repo/src/foo.ts' }) },
      openFn,
    )
    await wrapper.setProps({ expanded: true })

    const afterLineRows = wrapper.findAll('[data-side="after"][data-line="2"]')
    expect(afterLineRows.length).toBe(1)
    await afterLineRows[0]!.element
      .querySelector('span:not([data-bg])')!
      .dispatchEvent(new MouseEvent('click', { bubbles: true }))

    expect(calls).toHaveLength(0)
  })

  it('does NOT forward jump-to-line when no editor handler is provided (no inject)', async () => {
    wrapper = makeWrapper({
      content: makeContent({ path: '/repo/src/foo.ts' }),
      cwd: '/repo',
    })
    await wrapper.setProps({ expanded: true })

    const afterLineRows = wrapper.findAll('[data-side="after"][data-line="2"]')
    expect(afterLineRows.length).toBe(1)
    // Click should NOT throw and NOT call any handler.
    await afterLineRows[0]!.element
      .querySelector('span:not([data-bg])')!
      .dispatchEvent(new MouseEvent('click', { bubbles: true }))
    // No assertions on emitted events — just that nothing crashed.
    expect(wrapper.exists()).toBe(true)
  })

  it('passes a derived language to DiffView so zig output is colorized', async () => {
    const { default: DiffView } = await import('../_shared/DiffView.vue')
    wrapper = makeWrapper({
      content: {
        path: '/repo/src/main.zig',
        before: 'const x = 1',
        after: 'const x = 2',
        unified: null,
        lines_changed: 1,
        error: null,
      },
      expanded: true,
    })
    const diff = wrapper.findComponent(DiffView)
    expect(diff.exists()).toBe(true)
    expect(diff.props('language')).toBe('zig')
    expect(wrapper.html()).toContain('tok-keyword')
  })
})
