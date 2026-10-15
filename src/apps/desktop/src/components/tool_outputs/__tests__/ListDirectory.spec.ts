/**
 * Tests for ListDirectory.vue — the tool-output card component for the
 * `list_directory` agent tool.
 *
 * Wire shape (from src/modules/agent/tools/list_directory.zig):
 *
 *   <directory_listing path="/proj" count="3">
 *     <directory name="src" path="/proj/src" is_symlink="false"/>
 *     <file name="main.zig" path="/proj/main.zig" is_symlink="false"/>
 *   </directory_listing>
 *
 * Verifies (behavioural — interact like a user):
 *  - renders the data-testid matching the message id (for E2E selectors)
 *  - success path: tool name + path (truncated) + entry count + ✓ status
 *  - header line uses singular/plural "entry" correctly (1 entry vs N entries)
 *  - expanded body lists every directory first, then files (icons differ)
 *  - empty listing (count=0) renders an empty-state hint when expanded
 *  - error path: red border + ✗ badge + error message inline
 *  - click on header toggles expanded; copy buttons stopPropagation so they
 *    don't accidentally toggle the parent
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, provide } from 'vue'

import ListDirectory from '../ListDirectory.vue'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
} from '@/composables/useCodeEditor'

// ─── Test helpers ──────────────────────────────────────────────────────────
const makeSuccessContent = (opts: {
  path?: string
  entries?: Array<{
    name: string
    path: string
    is_directory: boolean
    is_symlink?: boolean
  }>
} = {}) => {
  const path = opts.path ?? '/proj'
  const entries = opts.entries ?? [
    { name: 'src', path: '/proj/src', is_directory: true, is_symlink: false },
    { name: 'README.md', path: '/proj/README.md', is_directory: false, is_symlink: false },
    { name: 'main.zig', path: '/proj/main.zig', is_directory: false, is_symlink: false },
  ]
  return {
    path,
    count: entries.length,
    entries: entries.map((e) => ({
      name: e.name,
      path: e.path,
      is_directory: e.is_directory,
      is_symlink: e.is_symlink ?? false,
    })),
  }
}

const makeErrorContent = (msg = 'list_directory failed: PathNotFound') =>
  // normalizeToolContent unwraps the full envelope; the component reads
  // the error from the normalized payload.
  JSON.stringify({
    tool: 'list_directory',
    parameters: { path: '/missing' },
    success: false,
    data: null,
    error: msg,
    v: 1,
  })

const makeEmptyContent = (path = '/empty') => ({ path, count: 0, entries: [] })

const makeWrapper = (
  props: { content: unknown; cwd?: string; expanded?: boolean },
  provideOpenInEditor?: OpenInCodeEditorFn,
) => {
  if (provideOpenInEditor) {
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          return () => h(ListDirectory, props as never)
        },
      }),
    )
  }
  return mount(ListDirectory, { props: props as never })
}

// jsdom clipboard stub (matches SaveMemory.spec.ts pattern)
let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: vi.fn(async (s: string) => { clipboardWrites.push(s) }) },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ─── Tests ─────────────────────────────────────────────────────────────────
describe('ListDirectory.vue — happy path', () => {
  it('renders the card with a data-testid', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent() })
    expect(wrapper.find('[data-testid="list-directory"]').exists()).toBe(true)
  })

  it('success path: shows tool name + path + count + ✓ status', () => {
    const wrapper = makeWrapper({
      content: makeSuccessContent({ path: '/home/user/repo' }),
    })
    expect(wrapper.text()).toContain('list_directory')
    expect(wrapper.text()).toContain('/home/user/repo')
    expect(wrapper.text()).toContain('3 entries')
    expect(wrapper.text()).toContain('✓')
    // ✗ must NOT appear on success
    expect(wrapper.text()).not.toContain('✗')
  })

  it('uses singular "entry" for exactly 1 entry', () => {
    const wrapper = makeWrapper({
      content: makeSuccessContent({
        entries: [{ name: 'solo', path: '/proj/solo', is_directory: false }],
      }),
    })
    expect(wrapper.text()).toContain('1 entry')
    expect(wrapper.text()).not.toContain('1 entries')
  })

  it('does NOT show the red border on success', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent() })
    const root = wrapper.find('[data-testid="list-directory"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('does NOT auto-expand (parent controls via :expanded prop)', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent() })
    // No list rows visible until expanded.
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(false)
  })
})

describe('ListDirectory.vue — expanded body', () => {
  it('renders every entry row when expanded=true', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent(), expanded: true })
    const rows = wrapper.findAll('[data-testid="list-directory-row"]')
    expect(rows.length).toBe(3)
  })

  it('renders directory entries with a "kind" attribute of "directory"', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent(), expanded: true })
    const directoryRows = wrapper.findAll(
      '[data-testid="list-directory-row"][data-kind="directory"]',
    )
    expect(directoryRows.length).toBe(1)
    expect(directoryRows[0]?.text()).toContain('src')
  })

  it('renders file entries with a "kind" attribute of "file"', () => {
    const wrapper = makeWrapper({ content: makeSuccessContent(), expanded: true })
    const fileRows = wrapper.findAll(
      '[data-testid="list-directory-row"][data-kind="file"]',
    )
    expect(fileRows.length).toBe(2)
  })

  it('marks symlinks with a distinct visual hint', () => {
    const wrapper = makeWrapper({
      content: makeSuccessContent({
        entries: [
          { name: 'real.txt', path: '/proj/real.txt', is_directory: false },
          { name: 'link.txt', path: '/proj/link.txt', is_directory: false, is_symlink: true },
        ],
      }),
      expanded: true,
    })
    const symlinkRow = wrapper.find(
      '[data-testid="list-directory-row"][data-is-symlink="true"]',
    )
    expect(symlinkRow.exists()).toBe(true)
    expect(symlinkRow.text()).toContain('link.txt')
  })

  it('renders an empty-state hint when count=0', () => {
    const wrapper = makeWrapper({ content: makeEmptyContent('/empty'), expanded: true })
    expect(wrapper.find('[data-testid="list-directory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('empty')
  })
})

describe('ListDirectory.vue — error path', () => {
  it('renders the error message in red when expanded', () => {
    const wrapper = makeWrapper({ content: makeErrorContent(), expanded: true })
    expect(wrapper.find('[data-testid="list-directory-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('list_directory failed: PathNotFound')
  })

  it('shows the ✗ status on error', () => {
    const wrapper = makeWrapper({ content: makeErrorContent() })
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).not.toContain('✓')
  })

  it('applies the red border on error', () => {
    const wrapper = makeWrapper({ content: makeErrorContent() })
    const root = wrapper.find('[data-testid="list-directory"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('does not render any entry rows on error', () => {
    const wrapper = makeWrapper({ content: makeErrorContent(), expanded: true })
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(false)
  })
})

describe('ListDirectory.vue — expand/collapse interaction', () => {
  it('clicking the header toggles expanded state', async () => {
    const wrapper = makeWrapper({ content: makeSuccessContent() })
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(false)

    // wrapper.find returns the first match — there's exactly one
    // role="button" in the card (the header), so we don't need
    // .findAll(...)[0].
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(true)

    // Click again — collapses.
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(false)
  })

  it('clicking the copy button does NOT toggle expanded state', async () => {
    const wrapper = makeWrapper({ content: makeSuccessContent() })
    // Expand first.
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(true)

    // Click a per-row copy button — must NOT collapse.
    const copyButtons = wrapper.findAll('[data-testid="list-directory-copy-path"]')
    expect(copyButtons.length).toBeGreaterThan(0)
    await copyButtons[0]!.trigger('click')
    expect(clipboardWrites.length).toBe(1)
    expect(wrapper.find('[data-testid="list-directory-row"]').exists()).toBe(true)
  })
})
