/**
 * Component tests for <WorkspaceItemTaskCard> — the bordered kanban-
 * card variant of the per-task UI.
 *
 * History:
 *   - Pre-2026-07-02: these tests lived in workspaceItemTaskVariant
 *     .spec.ts as the "card-ux-v2" and "card-ux-v3" describe blocks.
 *     They targeted <WorkspaceItemTask variant="card"> (the pre-split
 *     component with a `variant` prop).
 *   - 2026-07-02: <WorkspaceItemTask> split into
 *     <WorkspaceItemTaskRow> + <WorkspaceItemTaskCard>. The card
 *     variant's behavior moved to this file (renamed from
 *     workspaceItemTaskVariant.spec.ts); the row-only tests moved
 *     to workspaceItemTask.spec.ts. The variant prop is gone — the
 *     component's variant is now structural (Row vs Card file).
 *
 * This file covers:
 *   1. The Card component's data-attribute contract (data-task-card
 *      always present, data-task-row never).
 *   2. The richer card-ux-v2 layout (description preview, meta row,
 *      last-updated time, type badge).
 *   3. The Jira-style type-accent (card-ux-v3) left-edge stripe.
 *   4. The static-contract invariant: WorkspaceItem.vue (the only
 *      sidebar consumer) MUST NOT import <WorkspaceItemTaskCard> — the
 *      sidebar list uses the Row variant; Card is kanban-only.
 *
 * Plan: docs/plans/2026-07-01-change-task-to-card-kanban.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, nextTick, type Ref } from 'vue'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import WorkspaceItemTaskCard from '../components/workspace/WorkspaceItemTaskCard.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function mountCard(task: Task, props: Partial<{ dropIndicator: 'above' | 'below' | null }> = {}) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItemTaskCard, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      ...props,
    },
    global: { provide: { processingState } },
  })
  return wrapper
}

describe('WorkspaceItemTaskCard data-attribute contract', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('always renders data-task-card (Card component contract)', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-task-card]').exists()).toBe(true)
  })

  it('never renders data-task-row (Card component contract)', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-task-row]').exists()).toBe(false)
  })

  it('renders description when description is non-empty', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha', description: 'A note about Alpha' })
    const desc = wrapper.find('[data-testid="task-description"]')
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('A note about Alpha')
  })

  it('hides description line when description is empty', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })

  it('hides description line when description is undefined', () => {
    // explicitly pass undefined — the production ref to an unset
    // description is JS-undefined, NOT empty string.
    wrapper = mountCard({ id: 't1', name: 'Alpha', description: undefined })
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })

  it('renders the task name', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.text()).toContain('Alpha')
  })

  // The hover action strip (pin / rename / details / delete) was removed
  // in favour of the card's right-click context menu. These assert the
  // strip stays gone — a regression that re-adds a button costs ~100px of
  // a 280px column and truncates the task name back to ~150px.
  //
  // Plan: docs/superpowers/plans/2026-09-25-kanban-card-context-menu-move-to-column.md
  it('renders NO hover action buttons in the top row', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    // The two that carried a test id...
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="view-task-detail-btn"]').exists()).toBe(false)
    // ...and the rename / delete buttons, which never had one. The top
    // row is the first child div; its only <button> descendants would
    // be the action strip.
    const topRow = wrapper.find('[data-task-id="t1"]').element.children[0] as HTMLElement
    expect(topRow.querySelectorAll('button').length).toBe(0)
  })

  it('keeps the pin INDICATOR (state, not an action) when pinned', async () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha', is_pinned: true })
    await nextTick()
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    // The pin toggle is gone; the indicator is not.
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(false)
  })

  it('emits selectTask when clicked', async () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    // Trigger click on the root button via the data-task-id selector
    // (works regardless of variant since it is on the root <button>).
    await wrapper.find('[data-task-id="t1"]').trigger('click')
    expect(wrapper.emitted('selectTask')).toBeTruthy()
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])
  })
})

/**
 * Card-ux-v2 tests: the richer card layout (description with
 * line-clamp-2 + meta row with last-updated time and task-type
 * badge).
 */
describe('WorkspaceItemTaskCard card-ux-v2 (richer card layout)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('description uses line-clamp-2 (modernized) in card variant', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha', description: 'A long note' })
    const desc = wrapper.find('[data-testid="task-description"]')
    expect(desc.exists()).toBe(true)
    // card-ux-v2: 2-line clamp is more minimalist than the previous
    // 3-line clamp. Verified by checking the class string.
    expect(desc.classes().join(' ')).toContain('line-clamp-2')
    // Regression guard: confirm we removed the 1-line `truncate` class
    // (the legacy v1 had it; v2 uses line-clamp-2).
    expect(desc.classes().join(' ')).not.toContain('truncate')
  })

  it('meta row is hidden when card has no meta (no time, no pin, no type badge)', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-testid="task-meta"]').exists()).toBe(false)
  })

  it('meta row renders last-updated "just now" for an updatedAt of NOW', () => {
    // Pin Date.now() to a known instant, then supply a task whose
    // updatedAt is the same instant. The formatter should report
    // "just now" (within the < 45s threshold).
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    wrapper = mountCard({ id: 't1', name: 'Alpha', updatedAt: now })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('just now')
    vi.useRealTimers()
  })

  it('meta row renders "5m ago" for an updatedAt 5 minutes in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 5 * 60_000)
    wrapper = mountCard({ id: 't1', name: 'Alpha', updatedAt: past })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('5m ago')
    vi.useRealTimers()
  })

  it('meta row renders "3h ago" for an updatedAt 3 hours in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 3 * 60 * 60_000)
    wrapper = mountCard({ id: 't1', name: 'Alpha', updatedAt: past })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('3h ago')
    vi.useRealTimers()
  })

  it('meta row renders "2d ago" for an updatedAt 2 days in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 2 * 24 * 60 * 60_000)
    wrapper = mountCard({ id: 't1', name: 'Alpha', updatedAt: past })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('2d ago')
    vi.useRealTimers()
  })

  it('meta row renders "yesterday" for an updatedAt exactly 1 day in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 24 * 60 * 60_000)
    wrapper = mountCard({ id: 't1', name: 'Alpha', updatedAt: past })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('yesterday')
    vi.useRealTimers()
  })

  it('meta row falls back to createdAt when updatedAt is missing', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const created = new Date(now.getTime() - 10 * 60_000) // 10 min ago
    wrapper = mountCard({ id: 't1', name: 'Alpha', createdAt: created })
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('10m ago')
    vi.useRealTimers()
  })

  it('meta row is hidden when neither updatedAt nor createdAt is set', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-testid="task-meta-updated"]').exists()).toBe(false)
  })

  it('pinned indicator appears in TOP row (not meta row) when is_pinned is true', () => {
    // card-ux-v2: pin indicator moved from the meta row (which is
    // now reserved for "time + type label" only) to the top row,
    // sitting right after the task name. This keeps the meta row
    // minimal while still surfacing the pinned state in a visible
    // location (the top row is the natural reading order).
    wrapper = mountCard({ id: 't1', name: 'Alpha', is_pinned: true })
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    // Meta-row pin pill was REMOVED in card-ux-v2 — the top-row
    // indicator is the canonical surface for the pinned state.
    expect(wrapper.find('[data-testid="task-meta-pinned"]').exists()).toBe(false)
  })

  it('pinned indicator is absent from top row when is_pinned is false', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha', is_pinned: false })
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(false)
  })

  it('no routine type badge renders for legacy task_type="routine" (deleted Migration 084)', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'Daily sync',
      // Legacy wire value — the backend normalizes these to 'standard' (Migration 084), but an old
      // cached payload could still carry it. `as never` keeps tsc honest about the narrowed Task
      // union while testing the runtime behavior.
      task_type: 'routine' as never,
    })
    expect(wrapper.find('[data-testid="task-meta-type-routine"]').exists()).toBe(false)
  })

  it('memory type badge renders in meta row for task_type="memory"', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'project-notes',
      task_type: 'memory',
    })
    const badge = wrapper.find('[data-testid="task-meta-type-memory"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('memory')
  })

  it('no type badge renders for standard (default) tasks', () => {
    wrapper = mountCard({ id: 't1', name: 'Standard' })
    expect(wrapper.find('[data-testid^="task-meta-type-"]').exists()).toBe(false)
  })

  it('meta row renders time + type (no pin) when all set', () => {
    // card-ux-v2: the meta row is now reserved for time + type label
    // only — the pinned state is shown in the TOP row instead, so
    // this card meta row has 2 elements (time + type) not 3.
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 30 * 60_000) // 30m ago
    wrapper = mountCard({
      id: 't1',
      name: 'All-meta',
      updatedAt: past,
      is_pinned: true,
      task_type: 'memory',
    })
    expect(wrapper.find('[data-testid="task-meta-updated"]').text()).toBe('30m ago')
    expect(wrapper.find('[data-testid="task-meta-type-memory"]').exists()).toBe(true)
    // Pin indicator is in the TOP row now, not the meta row.
    expect(wrapper.find('[data-testid="task-meta-pinned"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    vi.useRealTimers()
  })
})

/**
 * card-ux-v3 tests: the Jira-style left-edge accent for task
 * type. A thin (3px) colored stripe down the left edge of the
 * card reflects the task's type:
 *   - memory  → blue   (rgb(96, 165, 250))
 *   - standard → no stripe
 * (The violet routine stripe was deleted in Migration 084.)
 *
 * Implemented as an inset box-shadow on the card root so the
 * layout doesn't shift. The accent is COMBINED with the
 * dropIndicator box-shadow (via cardBoxShadow computed) so the
 * pre-existing pinned-region drop indicator still works.
 */
describe('WorkspaceItemTaskCard card-ux-v3 (Jira-style type accent)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  function rootStyleFor(task: Task, dropIndicator?: 'above' | 'below' | null) {
    const props = dropIndicator !== undefined ? { dropIndicator } : {}
    return mountCard(task, props).find('[data-task-id]').attributes('style') ?? ''
  }

  it('legacy routine card has NO violet accent (deleted Migration 084)', () => {
    const style = rootStyleFor({
      id: 't1',
      name: 'Daily sync',
      task_type: 'routine' as never,
    })
    // No violet stripe — routine tasks render as standard cards now.
    expect(style).not.toContain('rgb(167, 139, 250)') // violet-400
  })

  it('memory card has a blue left accent', () => {
    const style = rootStyleFor({
      id: 't1',
      name: 'project-notes',
      task_type: 'memory',
    })
    expect(style).toContain('inset 3px 0 0 0')
    expect(style).toContain('rgb(96, 165, 250)') // blue-400
  })

  it('standard card has NO type accent (and a transparent border)', () => {
    const style = rootStyleFor({ id: 't1', name: 'Standard' })
    expect(style).not.toContain('inset 3px 0 0 0')
  })

  it('type accent is combined with dropIndicator box-shadow (both layered)', () => {
    // When BOTH the type accent AND the dropIndicator apply, the resulting box-shadow must contain
    // BOTH inset values (the drop indicator first, the type accent second). This is the Jira-style
    // layered shadow pattern.
    const style = rootStyleFor(
      {
        id: 't1',
        name: 'project-notes',
        task_type: 'memory',
      },
      'above',
    )
    // Both layered inset values should be present in the style.
    expect(style).toContain('inset 0 2px 0 0') // dropIndicator (above)
    expect(style).toContain('inset 3px 0 0 0') // type accent
    expect(style).toContain('rgb(96, 165, 250)') // blue-400 accent
  })
})

/**
 * Static-contract test: WorkspaceItem.vue (the only non-KanbanCard
 * consumer) MUST import the Row variant, not the Card. The Card is
 * exclusively used by the kanban tree (KanbanCard → KanbanColumn).
 * If someone accidentally swaps the import, the sidebar list would
 * render as a kanban card and the layout would break.
 *
 * History: pre-split, this guard asserted that WorkspaceItem.vue did
 * NOT pass `variant="card"` to <WorkspaceItemTask>. After the split
 * the variant prop is gone — the consumer is now structurally
 * different (Row vs Card file). The new assertion checks the import
 * shape instead.
 */
describe('WorkspaceItem.vue — task component invariant', () => {
  const SIDEBAR_PATH = resolve(__dirname, '..', 'components', 'workspace', 'WorkspaceItem.vue')

  it('does not import <WorkspaceItemTaskCard> (Card is kanban-only)', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    // Anchored on the import-from path so we don't trip over type
    // defs or comments mentioning the variant concept.
    expect(source).not.toMatch(/from\s+['"].*WorkspaceItemTaskCard\.vue['"]/)
  })

  it('imports <WorkspaceItemTaskRow> for the sidebar list', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    expect(source).toMatch(/from\s+['"].*WorkspaceItemTaskRow\.vue['"]/)
  })

  it('renders <WorkspaceItemTaskRow> (sanity: the contract test is testing the right file)', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    expect(source).toContain('<WorkspaceItemTaskRow')
  })
})

/**
 * card-ux-v6 tests: the 3D layered-shadow card (replaces the v5
 * visible border). The card now uses a layered box-shadow for
 * depth — outer drop shadow + inset bevel highlight — instead of a
 * 1px gray border. The card root also carries `w-full` so every
 * card in a column has the same width regardless of content length
 * (constant-width contract).
 *
 * History: card-ux-v4 had `border border-transparent` (cards
 * disappeared into the column); card-ux-v5 added a visible 1px
 * gray border (working, but the user wanted a 3D look); card-ux-v6
 * replaces the border with shadow to get the "card floating on
 * the board" feel without a hard outline.
 */
describe('WorkspaceItemTaskCard card-ux-v6 (3D shadow + constant width)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('card root has w-full class (constant-width contract)', () => {
    // Without w-full, the <button> would default to inline-block and size to its content. With
    // w-full every card spans the full width of the parent column's cards area, regardless of how
    // long the task name is.
    wrapper = mountCard({ id: 't1', name: 'A short task' })
    expect(wrapper.find('[data-task-card]').classes()).toContain('w-full')

    // Even with a very long title, width stays constant (truncate
    // handles the text overflow).
    const longWrapper = mountCard({
      id: 't2',
      name: 'a-very-long-task-name-that-would-normally-blow-out-the-width',
    })
    expect(longWrapper.find('[data-task-card]').classes()).toContain('w-full')
  })

  it('card root does NOT carry a 1px border (v6 replaces border with shadow)', () => {
    // Regression guard: card-ux-v6 deliberately removed the visible
    // border. A future refactor that re-adds `border` (e.g.
    // copy-paste from v5) would fail this test.
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    const classes = wrapper.find('[data-task-card]').classes()
    expect(classes).not.toContain('border')
    expect(classes).not.toContain('border-[--color-border]')
  })

  it('card has a 3D layered box-shadow at idle (outer drop + inset bevel)', () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    const style = wrapper.find('[data-task-card]').attributes('style') ?? ''
    // Outer drop shadow — the "lift" off the column.
    expect(style).toContain('0 1px 3px 0 rgba(0, 0, 0, 0.5)')
    // Second drop shadow for the soft halo.
    expect(style).toContain('0 1px 2px -1px rgba(0, 0, 0, 0.4)')
    // Inset 1px bevel highlight — the "edge of the card" without
    // a hard outline. White at 6% opacity is enough to read as a
    // bevel in dark mode without becoming a visible line.
    expect(style).toContain('inset 0 0 0 1px rgba(255, 255, 255, 0.06)')
  })

  it('card has a card-bg color at idle (paired with the shadow for the 3D surface)', () => {
    // Without a card-bg, the v6 shadow would float on the column bg with no surface to "lift off
    // of". Setting backgroundColor to --semantic-card-bg at idle gives the card a tangible surface
    // for the shadow to render against.
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    const style = wrapper.find('[data-task-card]').attributes('style') ?? ''
    expect(style).toContain('--semantic-card-bg')
  })

  it('card swaps to the hover shadow when mouseenter fires', async () => {
    wrapper = mountCard({ id: 't1', name: 'Alpha' })
    const card = wrapper.find('[data-task-card]')

    // Idle: base shadow with `0 1px 3px 0 rgba(0, 0, 0, 0.5)`.
    expect(card.attributes('style') ?? '').toContain('0 1px 3px 0 rgba(0, 0, 0, 0.5)')

    // Hover: bigger outer drop shadow `0 4px 6px -1px rgba(0, 0, 0, 0.55)`.
    await card.trigger('mouseenter')
    expect(card.attributes('style') ?? '').toContain('0 4px 6px -1px rgba(0, 0, 0, 0.55)')
    // And the brighter bevel highlight (0.10 vs 0.06).
    expect(card.attributes('style') ?? '').toContain('inset 0 0 0 1px rgba(255, 255, 255, 0.1)')

    // Mouseleave: back to base.
    await card.trigger('mouseleave')
    expect(card.attributes('style') ?? '').toContain('0 1px 3px 0 rgba(0, 0, 0, 0.5)')
  })

  it('3D shadow coexists with the Jira-style type accent (memory card)', () => {
    // The v6 base shadow must layer cleanly with the v3 type accent — they're both box-shadows on
    // the same element, so they stack via the multi-value comma syntax. Memory cards should show
    // BOTH the outer drop shadow AND the blue left stripe.
    wrapper = mountCard({
      id: 't1',
      name: 'project-notes',
      task_type: 'memory',
    })
    const style = wrapper.find('[data-task-card]').attributes('style') ?? ''
    // 3D base shadow.
    expect(style).toContain('0 1px 3px 0 rgba(0, 0, 0, 0.5)')
    // Jira-style blue left stripe (type accent).
    expect(style).toContain('inset 3px 0 0 0 rgb(96, 165, 250)')
  })
})
