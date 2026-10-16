/** Tests for SaveMemory.vue. */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import SaveMemory from '../SaveMemory.vue'

// ────────────────────────────────────────────────────────────────────────
// jsdom clipboard stub (matches ReadWorkspaceSession.spec.ts pattern)
// ────────────────────────────────────────────────────────────────────────
let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: {
      writeText: vi.fn(async (s: string) => {
        clipboardWrites.push(s)
      }),
    },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
const makeSuccessContent = (
  opts: {
    id?: string
    created_at?: string
    updated_at?: string
  } = {},
) => {
  const id = opts.id ?? 'mem_aabbccdd11223344'
  const created = opts.created_at ?? '2026-08-06 10:00:00'
  const updated = opts.updated_at ?? '2026-08-06 10:05:00'
  return { id, created_at: created, updated_at: updated }
}

const makeErrorContent = (msg = 'content exceeds the 1 MiB per-memory cap') => ({ error: msg })

const makeEmptyContent = () => ({})

// The saved note. `executeSaveMemory` deliberately does NOT echo the body
// back (1 KiB–1 MiB would blow the LLM's context), so the card reads
// `content` / `tags` from the tool-call args in `parameters`.
const BODY = 'The user prefers dark mode for the editor and pnpm over npm.'
const TAGS = 'preferences||user'

const makeParams = (content: string, tags: string | null = TAGS) =>
  JSON.stringify(tags === null ? { content } : { content, tags })

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('SaveMemory.vue — happy path', () => {
  it('renders the tool name pill + the id in the header on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('save_memory')
    expect(wrapper.find('[data-testid="save-memory-header-id"]').text()).toBe(
      'mem_aabbccdd11223344',
    )
    expect(wrapper.text()).toContain('✓')
  })

  it('shows the green ✓ status on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('does not show the red border on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    const root = wrapper.find('[data-testid="save-memory"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('renders the copy-id button on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-copy-id"]').exists()).toBe(true)
  })

  it('hides copy-id button on error (no id to copy)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-copy-id"]').exists()).toBe(false)
  })

  it('does NOT auto-expand (parent controls via :expanded prop)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-body"]').exists()).toBe(false)
  })

  it('never renders timestamps as rows — they live in the hover title', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-created-at-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="save-memory-updated-at-row"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('2026-08-06 10:00:00')
    expect(wrapper.text()).not.toContain('2026-08-06 10:05:00')

    const title = wrapper.find('[data-testid="save-memory-header-label"]').attributes('title')
    expect(title).toContain('saved 2026-08-06 10:00:00')
  })
})

describe('SaveMemory.vue — error path', () => {
  it('renders the error message in red when expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('content exceeds the 1 MiB per-memory cap')
  })

  it('shows the red ✗ status on error', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('applies the red border on error', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    const root = wrapper.find('[data-testid="save-memory"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('shows "error" in the header label on failure', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-header-label"]').text()).toBe('error')
    expect(wrapper.text()).not.toContain('mem_')
  })

  it('does not render the stored body when in error state', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent(), parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(false)
  })
})

describe('SaveMemory.vue — expand/collapse interaction', () => {
  it('clicking the header toggles expanded state', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="save-memory-body"]').exists()).toBe(false)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="save-memory-body"]').exists()).toBe(true)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="save-memory-body"]').exists()).toBe(false)
  })

  it('clicking the copy-id button does NOT toggle expanded state', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })

    await wrapper.find('[data-testid="save-memory-copy-id"]').trigger('click')
    expect(clipboardWrites).toEqual(['mem_aabbccdd11223344'])
    // Body still collapsed (the click was stopPropagation'd inside the
    // copy handler, so it didn't bubble to the header).
    expect(wrapper.find('[data-testid="save-memory-body"]').exists()).toBe(false)

    wrapper.unmount()
  })
})

describe('SaveMemory.vue — empty envelope edge case', () => {
  it('renders an empty-state hint when there is no body', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeEmptyContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('no content in envelope')
  })

  it('still shows ✓ status on an empty envelope (no error tag)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeEmptyContent() },
    })
    expect(wrapper.text()).toContain('✓')
  })
})

// ────────────────────────────────────────────────────────────────────────
// The saved body.
// ────────────────────────────────────────────────────────────────────────
describe('SaveMemory.vue — saved body', () => {
  it('renders the note body from the tool-call args when expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })

  it('hides the body until the card is expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').exists()).toBe(false)
  })

  it('reads the body from XML-shaped parameters too', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: `<content>${BODY}</content><tags>preferences||user</tags>`,
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })

  it('prefers data.content over the call args when the backend echoes it', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: { ...makeSuccessContent(), content: 'body from result envelope' },
        parameters: makeParams(BODY),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(
      'body from result envelope',
    )
  })

  it('shows a size + line-count badge for the body', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams('line one\nline two'),
        expanded: true,
      },
    })
    const badge = wrapper.find('[data-testid="save-memory-content-size"]').text()
    expect(badge).toContain('B · 2 lines')
  })

  it('hides content from the Arguments block so it is not repeated', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    // The Arguments <details> keeps `tags` but must not re-print the body.
    const argsBlock = wrapper.find('details')
    expect(argsBlock.exists()).toBe(true)
    expect(argsBlock.text()).not.toContain(BODY)
    expect(argsBlock.text()).toContain('preferences')
  })

  it('copies the full body without collapsing the card', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    await wrapper.find('[data-testid="save-memory-copy-content"]').trigger('click')
    expect(clipboardWrites).toEqual([BODY])
    // The click was stopPropagation'd — the card is still expanded.
    expect(wrapper.find('[data-testid="save-memory-content"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('clips an over-long body for display but still copies all of it', async () => {
    const long = 'x'.repeat(25000)
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(long), expanded: true },
      attachTo: document.body,
    })
    const rendered = wrapper.find('[data-testid="save-memory-content"]').text()
    expect(rendered).toHaveLength(20000)
    const note = wrapper.find('[data-testid="save-memory-content-clipped"]')
    expect(note.exists()).toBe(true)
    expect(note.text()).toContain('5,000 more characters not shown')

    await wrapper.find('[data-testid="save-memory-copy-content"]').trigger('click')
    expect(clipboardWrites).toEqual([long])
    wrapper.unmount()
  })

  it('renders no content row when the args carry no body', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: '{}', expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(false)
  })

  it('shows the body of a still-running call (result envelope empty)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: '', parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-running"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })
})

// ────────────────────────────────────────────────────────────────────────
// Id + tags: header only, in both states.
// ────────────────────────────────────────────────────────────────────────
describe('SaveMemory.vue — id + tags live in the header', () => {
  it('shows the id and the tags on ONE header line, in the collapsed state', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    // Both halves live in the same element → one line.
    expect(header.find('[data-testid="save-memory-header-id"]').exists()).toBe(true)
    expect(header.find('[data-testid="save-memory-header-tags"]').exists()).toBe(true)
    // The chips are in the header, so they need no expansion.
    expect(header.find('[data-testid="save-memory-tag-0"]').text()).toBe('preferences')
    expect(header.find('[data-testid="save-memory-tag-1"]').text()).toBe('user')
  })

  it('keeps the same header when expanded — the body adds only the note', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    expect(header.find('[data-testid="save-memory-header-id"]').exists()).toBe(true)
    expect(header.find('[data-testid="save-memory-header-tags"]').exists()).toBe(true)

    // The expanded body must NOT repeat the header's two facts. (The
    // Arguments <details> legitimately still lists the raw `tags` — check
    // the chips, not the string, so that block is out of scope.)
    const body = wrapper.find('[data-testid="save-memory-body"]')
    expect(body.text()).not.toContain('mem_aabbccdd11223344')
    expect(body.findAll('[data-testid^="save-memory-tag-"]')).toHaveLength(0)
    expect(body.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })

  it('splits tags sent with the | separator the LLM often uses', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams(BODY, 'demo|tool-test|pabrik'),
      },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    expect(header.find('[data-testid="save-memory-tag-0"]').text()).toBe('demo')
    expect(header.find('[data-testid="save-memory-tag-2"]').text()).toBe('pabrik')
  })

  it('collapses a long tag list to 3 chips + a +N chip', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams(BODY, 'a||b||c||d||e'),
      },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    expect(header.findAll('[data-testid^="save-memory-tag-"]')).toHaveLength(3)
    expect(header.find('[data-testid="save-memory-header-tags-more"]').text()).toBe('+2')
    // Nothing is lost — the hover title lists every tag.
    const title = header.attributes('title') ?? ''
    expect(title).toContain('Tags: a, b, c, d, e')
  })

  it('omits the tag chips entirely when no tags were sent', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY, null) },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    expect(header.find('[data-testid="save-memory-header-tags"]').exists()).toBe(false)
    expect(header.find('[data-testid="save-memory-header-id"]').exists()).toBe(true)
  })

  it('shows the tags with no fabricated id when the result envelope has no id', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: {}, parameters: makeParams(BODY) },
    })
    const header = wrapper.find('[data-testid="save-memory-header-label"]')
    // The id slot still renders (it is a fixed part of the layout) but
    // falls back to "unknown" — it must not invent a mem_* id.
    expect(header.find('[data-testid="save-memory-header-id"]').text()).toBe('unknown')
    expect(header.find('[data-testid="save-memory-header-tags"]').exists()).toBe(true)
  })

  it('does NOT preview the body in the header (expanding is for that)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    expect(wrapper.find('[data-testid="save-memory-header-label"]').text()).not.toContain(BODY)
  })

  it('leaves the header as the bare id when there is no body and no tags', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-header-label"]').text()).toBe(
      'mem_aabbccdd11223344',
    )
  })

  it('puts the full id, the note and the timestamp in the hover title', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    const title = wrapper.find('[data-testid="save-memory-header-label"]').attributes('title')
    expect(title).toContain('mem_aabbccdd11223344')
    expect(title).toContain(BODY)
    expect(title).toContain('saved 2026-08-06 10:00:00')
  })
})
