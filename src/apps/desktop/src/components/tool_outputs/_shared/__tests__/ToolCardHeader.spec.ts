/** Tests for ToolCardHeader.vue — the shared header for tool-output cards. */
import { mount } from '@vue/test-utils'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, provide } from 'vue'

import ToolCardHeader from '../ToolCardHeader.vue'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
} from '@/composables/useCodeEditor'

const StubClipboard = {
  writeText: vi.fn(),
}

beforeAll(() => {
  // jsdom doesn't expose navigator.clipboard by default
  Object.defineProperty(globalThis.navigator, 'clipboard', {
    value: StubClipboard,
    writable: true,
    configurable: true,
  })
})

// Minimal prop shape — just what each test sets. Use a Partial type
// via the casting below for ergonomic call-sites.
type HeaderProps = {
  toolName: string
  primary: string | null
  primaryTitle?: string | null
  primaryClass?: string
  success: boolean
  expanded: boolean
  expandable: boolean
  showCopy?: boolean
  showOpenInEditor?: boolean
  copyValue?: string | null
  cwd?: string
  inlineTag?: string | null
  inlineTagClass?: string
  rightMeta?: string | null
}

const makeWrapper = (props: HeaderProps, provideOpenInEditor?: OpenInCodeEditorFn) => {
  if (provideOpenInEditor) {
    // Wrap in a Parent that provides the editor handler, then mounts ToolCardHeader inline.
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          // Cast to any: ToolCardHeader's prop types are exhaustive; tests pass
          // a subset. vue-tsc can't unify Record<string, unknown> with h()'s
          // second arg without an explicit cast.
          return () => h(ToolCardHeader, { ...props } as never)
        },
      }),
    )
  }
  return mount(ToolCardHeader, { props })
}

describe('ToolCardHeader', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    StubClipboard.writeText.mockReset()
  })

  it('renders the tool name, primary field, and success badge', () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
    })
    expect(wrapper.text()).toContain('read_file')
    expect(wrapper.text()).toContain('/foo/bar.ts')
    expect(wrapper.text()).toContain('✓')
  })

  it('renders the failure badge when success=false', () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: false,
      expanded: false,
      expandable: true,
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('renders "unknown" when primary is null', () => {
    wrapper = makeWrapper({
      toolName: 'write_file',
      primary: null,
      success: true,
      expanded: false,
      expandable: true,
    })
    expect(wrapper.text()).toContain('unknown')
  })

  it('emits update:expanded on header click when expandable=true', async () => {
    wrapper = mount(ToolCardHeader, {
      props: {
        toolName: 'read_file',
        primary: '/foo/bar.ts',
        success: true,
        expanded: false,
        expandable: true,
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    const events = wrapper.emitted('update:expanded')
    expect(events).toEqual([[true]])
  })

  it('does NOT emit update:expanded on click when expandable=false', async () => {
    wrapper = mount(ToolCardHeader, {
      props: {
        toolName: 'remove_file',
        primary: '/foo/bar.ts',
        success: true,
        expanded: false,
        expandable: false,
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    const events = wrapper.emitted('update:expanded')
    expect(events).toBeUndefined()
  })

  it('copies the primary value when copy button is clicked', async () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/abs/path/file.ts',
      success: true,
      expanded: false,
      expandable: true,
    })
    const buttons = wrapper.findAll('button')
    const copyBtn = buttons.find((b) => b.text() === '⎘')
    expect(copyBtn).toBeTruthy()
    await copyBtn!.trigger('click')
    expect(StubClipboard.writeText).toHaveBeenCalledWith('/abs/path/file.ts')
  })

  it('copies the copyValue prop (not primary) when copyValue is set', async () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/abs/path/file.ts',
      copyValue: 'custom-value-to-copy',
      success: true,
      expanded: false,
      expandable: true,
    })
    const copyBtn = wrapper
      .findAll('button')
      .find((b) => b.text() === '⎘')
    await copyBtn!.trigger('click')
    expect(StubClipboard.writeText).toHaveBeenCalledWith('custom-value-to-copy')
  })

  it('hides copy button when showCopy=false', () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
      showCopy: false,
    })
    const copyBtn = wrapper
      .findAll('button')
      .find((b) => b.text() === '⎘')
    expect(copyBtn).toBeUndefined()
  })

  it('shows open-in-editor button when cwd is set and primary exists', () => {
    const openInEditor = vi.fn() as OpenInCodeEditorFn
    wrapper = makeWrapper(
      {
        toolName: 'read_file',
        primary: '/abs/path/file.ts',
        success: true,
        expanded: false,
        expandable: true,
        cwd: '/abs/path',
      },
      openInEditor,
    )
    const editorBtn = wrapper.find('button[title="Open in code editor"]')
    expect(editorBtn.exists()).toBe(true)
  })

  it('hides open-in-editor button when showOpenInEditor=false', () => {
    wrapper = makeWrapper({
      toolName: 'add_skill',
      primary: 'my-skill',
      success: true,
      expanded: false,
      expandable: true,
      cwd: '/abs/path',
      showOpenInEditor: false,
    })
    const editorBtn = wrapper.find('button[title="Open in code editor"]')
    expect(editorBtn.exists()).toBe(false)
  })

  it('hides open-in-editor button when cwd is null', () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
      cwd: undefined,
    })
    const editorBtn = wrapper.find('button[title="Open in code editor"]')
    expect(editorBtn.exists()).toBe(false)
  })

  it('calls openInEditor with the right args when editor button is clicked', async () => {
    const openInEditor = vi.fn() as OpenInCodeEditorFn
    wrapper = makeWrapper(
      {
        toolName: 'read_file',
        primary: '/abs/path/file.ts',
        success: true,
        expanded: false,
        expandable: true,
        cwd: '/abs/path',
      },
      openInEditor,
    )
    const editorBtn = wrapper.find('button[title="Open in code editor"]')
    await editorBtn.trigger('click')
    expect(openInEditor).toHaveBeenCalledWith({
      filePath: '/abs/path/file.ts',
      cwd: '/abs/path',
    })
  })

  it('renders inline tag when provided', () => {
    wrapper = makeWrapper({
      toolName: 'remove_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
      inlineTag: '(recursive)',
    })
    expect(wrapper.text()).toContain('(recursive)')
  })

  it('renders rightMeta when provided', () => {
    wrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
      rightMeta: '42L',
    })
    expect(wrapper.text()).toContain('42L')
  })

  it('shows + when collapsed and - when expanded (expandable only)', () => {
    const collapsedWrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: false,
      expandable: true,
    })
    expect(collapsedWrapper.text()).toContain('+')
    collapsedWrapper.unmount()

    const expandedWrapper = makeWrapper({
      toolName: 'read_file',
      primary: '/foo/bar.ts',
      success: true,
      expanded: true,
      expandable: true,
    })
    expect(expandedWrapper.text()).toContain('−')
  })
})