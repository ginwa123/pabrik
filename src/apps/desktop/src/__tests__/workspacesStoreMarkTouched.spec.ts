/**
 * Tests for the kanban notification icon's frontend stamp hook
 * (plan: docs/plans/2026-07-26-kanban-task-notification-icon.md,
 * Chunk 7).
 *
 * When `workspacesStore.setActiveTask(taskId)` activates a task,
 * the store MUST fire-and-forget `api.markTaskHumanTouched` with
 * the parent workspace_id + item_id so the kanban card's
 * "AI finished — awaiting review" dot flips to the green
 * "reviewed" checkmark the moment the user opens the chat.
 *
 * Why this lives in the store, not the component
 * ────────────────────────────────────────────────
 * The store is the canonical owner of the active-task state
 * transition (it also handles expand-parent-workspace logic). All
 * call sites (kanban click, sidebar click, search, deep link)
 * route through `setActiveTask`. Wiring the mark call HERE
 * (not in AppLayout.vue) means every consumer gets the stamp for
 * free — no missed wire if a future caller forgets the component.
 *
 * Why fire-and-forget, not await
 * ──────────────────────────────
 * The user already waited for the kanban card to update — the
 * stamp is best-effort metadata. Awaiting the PUT would block
 * the UI on a network call that the user doesn't care about.
 * Failures log a warning but don't surface as toasts.
 *
 * Why we test the store, not AppLayout
 * ────────────────────────────────────
 * AppLayout.vue delegates to the store's setActiveTask; testing
 * the store directly is faster (no full component mount), more
 * focused (only the store's wire), and matches the project's
 * "store actions are the canonical wiring point" convention.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem, type Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeWorkspaceWithTask(): Workspace {
  const task: Task = {
    id: 'task_1',
    name: 'Test task',
  }
  const item: WorkspaceItem = {
    id: 'item_1',
    name: 'Sprint board',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [task],
  }
  return {
    id: 'ws_1',
    name: 'Test ws',
    icon: '',
    expanded: true,
    items: [item],
  }
}

describe('workspacesStore.setActiveTask — kanban notification icon stamp (Chunk 7)', () => {
  let markSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Spy on the new API function. We accept any resolved/rejected
    // promise — the store fires-and-forgets.
    markSpy = vi
      .spyOn(api, 'markTaskHumanTouched')
      .mockResolvedValue({ success: true })
  })

  afterEach(() => {
    markSpy.mockRestore()
    vi.restoreAllMocks()
  })

  it('calls api.markTaskHumanTouched when setActiveTask activates a task', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithTask()]

    store.setActiveTask('task_1')
    await nextTick() // let the fire-and-forget microtask queue settle

    expect(markSpy).toHaveBeenCalledTimes(1)
    expect(markSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_1')
  })

  it('does NOT call markTaskHumanTouched when setActiveTask(null) clears the active task', async () => {
    // Clearing the active task (closing the chat, navigating away) is NOT a "human touch" — the
    // user isn't engaging with the task anymore. We must not stamp in this branch, otherwise
    // closing a chat would silently mark every task as "reviewed".
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithTask()]
    store.setActiveTask('task_1') // first activate, fires mark
    await nextTick()
    expect(markSpy).toHaveBeenCalledTimes(1)

    markSpy.mockClear()
    store.setActiveTask(null) // clear — must NOT fire
    await nextTick()
    expect(markSpy).not.toHaveBeenCalled()
  })

  it('re-fires markTaskHumanTouched when setActiveTask is called with the SAME task twice', async () => {
    // Re-activating the same task fires the mark again. The
    // backend is idempotent (re-stamping is harmless — the
    // column is just a monotonic timestamp) and the SSE event
    // `human_touched` is also idempotent (the kanban view re-
    // fetches the same state). The cost is one extra PUT per
    // re-click, which is acceptable.
    //
    // Earlier we tried to gate this with `wasActive = activeTaskId
    // .value === taskId` (an early-return guard) but that broke
    // the legitimate "user changes activeWorkspaceItem, then
    // re-activates the task to update the parent" flow (see the
    // AppLayout.kanban.spec.ts test 'does NOT render <KanbanView>
    // when the active task's parent is a different workspace
    // item'). The fix is to let the loop always run; the parent-
    // finding logic is the source of truth, not the
    // activeTaskId comparison.
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithTask()]

    store.setActiveTask('task_1')
    await nextTick()
    expect(markSpy).toHaveBeenCalledTimes(1)

    markSpy.mockClear()
    store.setActiveTask('task_1') // same task — re-fires
    await nextTick()
    expect(markSpy).toHaveBeenCalledTimes(1)
  })

  it('does NOT call markTaskHumanTouched for an unknown task_id', async () => {
    // Defensive: if a deep-link or search-result passes an id that
    // doesn't match any loaded task, we silently no-op without
    // sending a malformed PUT (the backend would 404 on it).
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithTask()]

    store.setActiveTask('task_nonexistent')
    await nextTick()
    expect(markSpy).not.toHaveBeenCalled()
  })
})