/** Behavioural tests for `CodeViewerStage` — the code viewer's three states, shared by both hosts
 * (ChatView's center column and AppLayout's full-surface overlay) so they can never drift apart. */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import CodeViewerStage from '../CodeViewerStage.vue'
import type { FolderEntry } from '../../../api'

const FILE: FolderEntry = {
  path: '/w/src/sample.ts',
  name: 'sample.ts',
  is_directory: false,
  is_symlink: false,
}

function mountStage(props: Record<string, unknown> = {}) {
  return mount(CodeViewerStage, {
    props: {
      file: FILE,
      content: "const x = 'MARKER'\n",
      loading: false,
      error: null,
      cwd: '/w',
      line: null,
      ...props,
    },
  })
}

describe('CodeViewerStage — loading', () => {
  it('shows the spinner and no file while loading', () => {
    const w = mountStage({ loading: true })

    expect(w.find('[data-testid="code-viewer-loading"]').exists()).toBe(true)
    expect(w.find('[data-testid="code-editor"]').exists()).toBe(false)
  })
})

describe('CodeViewerStage — error', () => {
  it('shows the message (never a silent blank) and closes on demand', async () => {
    const w = mountStage({ loading: false, error: 'No working directory' })

    expect(w.find('[data-testid="code-viewer-error"]').text()).toContain('No working directory')
    expect(w.find('[data-testid="code-editor"]').exists()).toBe(false)

    await w.get('[data-testid="code-viewer-error-close"]').trigger('click')
    expect(w.emitted('close')).toHaveLength(1)
  })

  it('an error wins over stale content', () => {
    const w = mountStage({ error: 'Failed to read file' })
    // The file view is not mounted at all — a late read response can
    // never paint over the error message.
    expect(w.find('[data-testid="code-editor"]').exists()).toBe(false)
    expect(w.find('[data-testid="code-viewer-error"]').exists()).toBe(true)
  })
})

describe('CodeViewerStage — file', () => {
  it('renders the file with line numbers and syntax tokens', () => {
    const w = mountStage()

    const body = w.get('[data-testid="code-editor-body"]')
    expect(body.text()).toContain('MARKER')
    expect(w.findAll('[data-testid="code-line"]')).toHaveLength(1)
    expect(w.get('[data-testid="code-line-number"]').text()).toBe('1')
    expect(w.findAll('.tok-keyword').length).toBeGreaterThan(0)
  })

  it('forwards the file, content, cwd and line to the viewer', () => {
    const w = mountStage({ content: 'a\nb\nc\n', line: 2 })
    expect(w.findAll('[data-testid="code-line"]')).toHaveLength(3)
    const target = w.find('[data-testid="code-line"][data-line="2"]')
    expect(target.attributes('data-target')).toBe('true')
  })

  it('closes through the viewer header', async () => {
    const w = mountStage()
    await w.get('[data-testid="code-editor-close"]').trigger('click')
    expect(w.emitted('close')).toHaveLength(1)
  })

  it('emits close exactly once per click (no double-wiring)', async () => {
    const w = mountStage({ error: 'boom' })
    await w.get('[data-testid="code-viewer-error-close"]').trigger('click')
    expect(w.emitted('close')).toHaveLength(1)
  })

  it('renders an empty file with an explicit empty state', () => {
    const w = mountStage({ content: '' })
    expect(w.find('[data-testid="code-editor-empty"]').exists()).toBe(true)
    expect(w.findAll('[data-testid="code-line"]')).toHaveLength(0)
  })
})
