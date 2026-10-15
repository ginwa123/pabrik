/**
 * Component tests for the kanban task notification icon — the orange
 * "AI finished — awaiting review" dot and the green "reviewed"
 * checkmark on <WorkspaceItemTaskCard>.
 *
 * Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md (Chunk 6)
 *
 * Card states (single branch — per-task routine branches were
 * deleted in Migration 084, so all task types share these):
 *   1. AI running → elapsed time pill (the circle spinner was removed).
 *   2. needs_human_review=true, not running → ORANGE PULSING DOT.
 *   3. needs_human_review=false AND last_finish_reason='stop',
 *      not running → GREEN CHECKMARK.
 *   4. AI never ran (last_finish_reason='' or undefined) → no icon.
 *   5. finish_reason != 'stop' (e.g. 'tool_calls', 'length') → no icon
 *      even if needs_human_review was true by some bug — the SQL
 *      predicate guards this, but the UI also defensively gates.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import WorkspaceItemTaskCard from '../components/workspace/WorkspaceItemTaskCard.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function mountCard(
  task: Task,
  options: { processing?: Record<string, boolean>; activity?: Record<string, WorkerActivity> } = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref(options.processing ?? {})
  const workerActivity = ref<Record<string, WorkerActivity>>(options.activity ?? {})
  const workerNow = ref(Date.now())
  const wrapper = mount(WorkspaceItemTaskCard, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
    },
    global: { provide: { processingState, workerActivity, workerNow } },
  })
  return wrapper
}

describe('WorkspaceItemTaskCard — kanban task notification icon (Chunk 6)', () => {
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

  // ─────────────────────────────────────────────────────────────────
  // State 2: orange "awaiting review" dot
  // ─────────────────────────────────────────────────────────────────

  it('renders the orange needs-review dot when needs_human_review=true and not running', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'Done by AI',
      last_finish_reason: 'stop',
      needs_human_review: true,
    })
    const dot = wrapper.find('[data-testid="task-needs-review"]')
    expect(dot.exists()).toBe(true)
    // Tooltip explains the state for screen-reader / hover users.
    expect(dot.attributes('title')).toContain('awaiting')
  })

  it('shows the orange dot alongside the time pill when the worker is active', () => {
    // AI is mid-turn AND a previous turn finished with stop awaiting review.
    // The spinner is gone, so both markers show: the dot (review state)
    // and the elapsed pill (activity state).
    const now = Date.now()
    wrapper = mountCard(
      {
        id: 't1',
        name: 'Running again',
        last_finish_reason: 'stop',
        needs_human_review: true,
      },
      {
        processing: { t1: true },
        activity: {
          t1: { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
        },
      },
    )
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(true)
    // No spinner element exists anymore; the time pill is the marker.
    expect(wrapper.find('[data-testid="task-spinner"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-card-elapsed-chip"]').exists()).toBe(true)
  })

  // ─────────────────────────────────────────────────────────────────
  // State 3: green "reviewed" checkmark
  // ─────────────────────────────────────────────────────────────────

  it('renders the green reviewed checkmark when finish_reason=stop AND needs_human_review=false AND not running', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'Reviewed',
      last_finish_reason: 'stop',
      needs_human_review: false,
    })
    const check = wrapper.find('[data-testid="task-reviewed"]')
    expect(check.exists()).toBe(true)
    expect(check.attributes('title')).toContain('Reviewed')
    // The orange dot and the spinner must NOT be present — only the
    // checkmark for this terminal state.
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-spinner"]').exists()).toBe(false)
  })

  // ─────────────────────────────────────────────────────────────────
  // State 4: never ran (no last_finish_reason)
  // ─────────────────────────────────────────────────────────────────

  it('renders nothing when last_finish_reason is missing AND needs_human_review is false (default empty task)', () => {
    wrapper = mountCard({ id: 't1', name: 'Brand new' })
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-reviewed"]').exists()).toBe(false)
  })

  it('renders nothing when last_finish_reason="" AND needs_human_review=false (legacy task, never chatted)', () => {
    // Backwards compat: backend COALESCE'd NULL last_finish_reason
    // to ''. The UI must treat '' the same as missing.
    wrapper = mountCard({
      id: 't1',
      name: 'Legacy',
      last_finish_reason: '',
      needs_human_review: false,
    })
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-reviewed"]').exists()).toBe(false)
  })

  // ─────────────────────────────────────────────────────────────────
  // State 5: defensive — finish_reason != 'stop' must never paint
  // the dot, even if needs_human_review somehow became true
  // (e.g. cache stale during a session-status flip).
  // ─────────────────────────────────────────────────────────────────

  it('renders nothing when finish_reason=tool_calls even if needs_human_review is true (defensive)', () => {
    // The SQL predicate COALESCE(s.last_finish_reason,'')='stop' guarantees this in normal flow,
    // but the UI also gates on it so a stale React prop doesn't paint a phantom dot during a state
    // transition.
    wrapper = mountCard({
      id: 't1',
      name: 'Mid-tool',
      last_finish_reason: 'tool_calls',
      needs_human_review: true,
    })
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-reviewed"]').exists()).toBe(false)
  })

  // ───────────────────────────────────────────────────────────────── Static-contract: the orange
  // dot must use the project's palette — matches the existing yellow-spinner so the card doesn't
  // introduce a third colour. ─────────────────────────────────────────────────────────────────

  it('orange dot uses rgb(251, 146, 60) (orange-400, matches existing palette)', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'X',
      last_finish_reason: 'stop',
      needs_human_review: true,
    })
    const dot = wrapper.find('[data-testid="task-needs-review"]')
    // jsdom normalises inline rgb(...) per project memory `frontend-jsdom-normalizes-hex-colors`.
    // We assert the inline-style bg colour contains the literal rgb() form (NOT the hex #fb923c —
    // that would mean the browser never saw the literal).
    const style = dot.attributes('style') ?? ''
    expect(style).toMatch(/background-?color\s*:\s*rgb\(\s*251\s*,\s*146\s*,\s*60\s*\)/i)
  })

  // ─────────────────────────────────────────────────────────────────
  // Static-contract: the icon renders in the single branch for all
  // task types (per-task routine branches were deleted in
  // Migration 084 — there is no separate routine branch anymore).
  // ─────────────────────────────────────────────────────────────────

  it('renders the orange dot on legacy routine-typed cards (single branch now)', () => {
    wrapper = mountCard({
      id: 't1',
      name: 'Daily sync',
      task_type: 'routine' as never,
      last_finish_reason: 'stop',
      needs_human_review: true,
    })
    expect(wrapper.find('[data-testid="task-needs-review"]').exists()).toBe(true)
  })

  it('DOES render the green checkmark on memory cards (memory shares the standard branch)', () => {
    // Memory tasks render via the standard-branch template (the `v-if="isRoutine"` is false for
    // memory, so memory goes into the `v-else` branch). The notification icon therefore applies to
    // memory cards too — there's no separate memory branch affordance for AI-finished state.
    wrapper = mountCard({
      id: 't1',
      name: 'project-notes',
      task_type: 'memory',
      last_finish_reason: 'stop',
      needs_human_review: false,
    })
    expect(wrapper.find('[data-testid="task-reviewed"]').exists()).toBe(true)
  })
})
