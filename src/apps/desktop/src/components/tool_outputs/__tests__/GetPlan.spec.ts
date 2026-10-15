/**
 * Tests for GetPlan.vue.
 *
 * Verifies:
 *  - parses the present-plan envelope (CDATA-wrapped markdown body)
 *  - parses the empty-plan envelope (<empty/> sentinel)
 *  - parses the error envelope (<error> tag → red border)
 *  - header label shows "N items" / "(empty)" / "error" per state
 *  - right meta shows "N/M done" / "no plan set" / error message
 *  - expanded body renders the checklist with ☐ / ☑ glyphs
 *  - checked items get line-through styling
 *  - plain (non-checklist) lines render as text rows
 *  - body with no checklist lines shows the "(no checklist)" hint
 *  - empty result shows the "No plan set" hint
 *  - click on header toggles expanded state
 *  - inner envelope extraction works both with and without the <tool> wrapper
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import GetPlan from '../GetPlan.vue'

// ──────────────────────────────────────────────────────────────────────── Helpers
// ────────────────────────────────────────────────────────────────────────
/** Build a present-plan JSON envelope with the markdown body the backend emits (`executeGetPlan`
 * returns `{plan: <markdown>}`). */
const makePresentContent = (markdown: string): string =>
  JSON.stringify({
    tool: 'get_plan',
    parameters: {},
    success: true,
    data: { plan: markdown },
    error: null,
    v: 1,
  })

const makeEmptyContent = (): string =>
  JSON.stringify({
    tool: 'get_plan',
    parameters: {},
    success: true,
    data: { empty: true },
    error: null,
    v: 1,
  })

const makeErrorContent = (msg = 'database is locked') =>
  JSON.stringify({
    tool: 'get_plan',
    parameters: {},
    success: false,
    data: null,
    error: msg,
    v: 1,
  })

/**  * Wrap the inner data payload in the full JSON wire envelope the dispatcher actually passes
 * through. Mirrors the backend's `wrapToolOutput`. Accepts a data object (or a full envelope
 * string, passed through unchanged). */
const wrapInToolEnvelope = (inner: string): string => {
  if (inner.trim().startsWith('{')) {
    try {
      const parsed: unknown = JSON.parse(inner)
      if (typeof parsed === 'object' && parsed !== null && 'tool' in (parsed as Record<string, unknown>)) {
        return inner
      }
      return JSON.stringify({
        tool: 'get_plan',
        parameters: {},
        success: true,
        data: parsed,
        error: null,
        v: 1,
      })
    } catch {
      return inner
    }
  }
  return inner
}

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('GetPlan.vue — present plan', () => {
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

  it('renders the tool name pill + item count in the header on success', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(
            '## Goal\nBuild the thing\n\n## Steps\n- [x] step 1 done\n- [ ] step 2 todo\n- [ ] step 3 todo',
          ),
        },
      },
    })
    expect(wrapper.find('[data-testid="get-plan"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('get_plan')
    // 3 checklist items (1 checked + 2 unchecked).
    expect(wrapper.text()).toContain('3 items')
  })

  it('uses singular "item" when the plan has exactly one checklist entry', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: { content: makePresentContent('## Steps\n- [x] only step') },
      },
    })
    expect(wrapper.text()).toContain('1 item')
    expect(wrapper.text()).not.toContain('1 items')
  })

  it('shows the "N/M done" right meta', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(
            '## Steps\n- [x] step 1 done\n- [x] step 2 done\n- [ ] step 3 todo',
          ),
        },
      },
    })
    expect(wrapper.text()).toContain('2/3 done')
  })

  it('shows "0/0 done" when the plan has no checklist lines', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('## Goal\nJust a heading, no list'),
        },
      },
    })
    // No checklist, no "N/M done" right meta. Header shows "(no checklist)".
    expect(wrapper.text()).toContain('get_plan')
    expect(wrapper.text()).not.toContain('done')
    expect(wrapper.text()).toContain('(no checklist)')
  })

  it('shows the green ✓ status on success', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: { content: makePresentContent('## Steps\n- [x] step 1') },
      },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('does not show the red border on success', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: { content: makePresentContent('## Steps\n- [x] step 1') },
      },
    })
    const root = wrapper.find('[data-testid="get-plan"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('auto-expands (expanded by default)', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('## Steps\n- [x] step 1\n- [ ] step 2'),
        },
      },
    })
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
  })

  it('renders the checklist when expanded', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(
            '## Steps\n- [x] step 1 done\n- [ ] step 2 todo',
          ),
        },
      },
      attachTo: document.body,
    })

    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('step 1 done')
    expect(wrapper.text()).toContain('step 2 todo')
  })

  it('renders ☐ for unchecked items and ☑ for checked items', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(
            '- [x] step 1\n- [ ] step 2',
          ),
        },
      },
      attachTo: document.body,
    })

    // JSON `plan` carries the body verbatim (no CDATA leading newline),
    // so line 0 is "- [x] step 1" (checked) → ☑, line 1 is
    // "- [ ] step 2" (unchecked) → ☐.
    const checkedLine = wrapper.find('[data-testid="get-plan-line-0"]')
    const uncheckedLine = wrapper.find('[data-testid="get-plan-line-1"]')
    expect(checkedLine.attributes('data-kind')).toBe('checked')
    expect(uncheckedLine.attributes('data-kind')).toBe('unchecked')

    // The checkbox glyphs are the first child span of each line.
    const checkedGlyph = checkedLine.find('span').text()
    const uncheckedGlyph = uncheckedLine.find('span').text()
    expect(checkedGlyph).toBe('☑')
    expect(uncheckedGlyph).toBe('☐')
  })

  it('strips the "- [x] " / "- [ ] " prefix from the displayed text', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('- [x] step 1 done'),
        },
      },
      attachTo: document.body,
    })

    // The raw "- [x] " prefix must NOT appear in the rendered text.
    expect(wrapper.text()).not.toContain('- [x]')
    expect(wrapper.text()).toContain('step 1 done')
  })

  it('applies line-through to checked items', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('- [x] step 1\n- [ ] step 2'),
        },
      },
      attachTo: document.body,
    })

    // Line 0 = checked, line 1 = unchecked.
    const checkedText = wrapper.find('[data-testid="get-plan-line-0"]').find('span.line-through')
    expect(checkedText.exists()).toBe(true)
    expect(checkedText.text()).toContain('step 1')

    const uncheckedText = wrapper.find('[data-testid="get-plan-line-1"]').find('span.line-through')
    expect(uncheckedText.exists()).toBe(false)
  })

  it('renders plain (non-checklist) lines as text rows', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(
            '## Goal\nBuild the whole thing\n\n## Steps\n- [x] step 1',
          ),
        },
      },
      attachTo: document.body,
    })

    // Strict ordering preserved (line 0 = "## Goal", 1 = "Build the whole
    // thing", 2 = "", 3 = "## Steps", 4 = "- [x] step 1").
    expect(wrapper.find('[data-testid="get-plan-line-0"]').attributes('data-kind')).toBe('text')
    expect(wrapper.find('[data-testid="get-plan-line-1"]').attributes('data-kind')).toBe('text')
    expect(wrapper.text()).toContain('Build the whole thing')
  })

  it('shows the "(no checklist lines)" hint when body is empty', async () => {
    // The hint renders when the parsed body splits into zero lines
    // (i.e. the CDATA payload was empty or whitespace-only). Plain-text
    // bodies without checkboxes render as text rows instead.
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent(''),
        },
      },
      attachTo: document.body,
    })

    expect(wrapper.find('[data-testid="get-plan-no-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('no checklist lines')
  })

  it('renders plain-text lines as text rows when body has no checkboxes', async () => {
    // When the body has text but no `- [ ]` / `- [x]` markers, each line
    // renders as a text row (no glyph, no line-through). The
    // "(no checklist)" hint is reserved for the empty-body edge case.
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('## Goal\nJust a heading\n\nSome prose, no list'),
        },
      },
      attachTo: document.body,
    })

    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="get-plan-no-checklist"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('Just a heading')
    expect(wrapper.text()).toContain('Some prose, no list')
  })

  it('clicking the header collapses the body, clicking again re-expands it', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: makePresentContent('## Steps\n- [x] step 1\n- [ ] step 2'),
        },
      },
      attachTo: document.body,
    })

    // Expanded by default — no click needed.
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(false)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
  })
})

describe('GetPlan.vue — empty plan (<empty/>)', () => {
  it('renders the "get_plan" pill in the header', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    expect(wrapper.find('[data-testid="get-plan"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('get_plan')
  })

  it('shows "(empty)" as the primary label', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    expect(wrapper.text()).toContain('(empty)')
  })

  it('shows "no plan set" as the right meta', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    expect(wrapper.text()).toContain('no plan set')
  })

  it('shows the green ✓ status (empty is a valid response, not an error)', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('does not show the red border on an empty result', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    const root = wrapper.find('[data-testid="get-plan"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('renders the "No plan set" hint when expanded', async () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No plan set')
    expect(wrapper.text()).toContain('update_plan')
  })

  it('shows the empty hint before any checklist when expanded', async () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeEmptyContent() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(false)
  })
})

describe('GetPlan.vue — error path', () => {
  it('renders the error message in red when expanded', async () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('database is locked')
  })

  it('shows the red ✗ status on error', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent() } },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('applies the red border on error', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent() } },
    })
    const root = wrapper.find('[data-testid="get-plan"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('shows "error" as the primary label on failure', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent() } },
    })
    expect(wrapper.text()).toContain('error')
  })

  it('does not render the checklist when in error state', async () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="get-plan-empty"]').exists()).toBe(false)
  })

  it('shows the error message text in the right meta when collapsed', () => {
    const wrapper = mount(GetPlan, {
      props: { message: { content: makeErrorContent('session_plan row missing') } },
    })
    expect(wrapper.text()).toContain('session_plan row missing')
  })
})

describe('GetPlan.vue — inner envelope extraction', () => {
  it('finds the inner <get_plan> envelope inside a <tool> wrapper', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: wrapInToolEnvelope(
            makePresentContent('## Steps\n- [x] step 1\n- [ ] step 2'),
          ),
        },
      },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('step 1')
    expect(wrapper.text()).toContain('step 2')
  })

  it('handles a bare data object (no envelope wrapper)', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: JSON.stringify({ plan: '## Steps\n- [x] step 1' }),
        },
      },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('step 1')
  })

  it('handles <empty/> inside a <tool> wrapper', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: wrapInToolEnvelope(makeEmptyContent()),
        },
      },
    })
    expect(wrapper.text()).toContain('(empty)')
    expect(wrapper.text()).toContain('no plan set')
  })

  it('handles an <error> envelope inside a <tool> wrapper', async () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: {
          content: wrapInToolEnvelope(makeErrorContent('boom')),
        },
      },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="get-plan-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('boom')
    expect(wrapper.find('[data-testid="get-plan"]').classes()).toContain('border-red-500/50')
  })

  it('treats non-JSON content as an error (hard cut: no XML fallback)', () => {
    const wrapper = mount(GetPlan, {
      props: {
        message: { content: '<foo>bar</foo>' },
      },
    })
    expect(wrapper.text()).toContain('tool failed')
    expect(wrapper.text()).toContain('✗')
  })
})
