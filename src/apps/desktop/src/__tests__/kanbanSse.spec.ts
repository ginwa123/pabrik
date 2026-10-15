/**
 * Unit tests for the bus-backed kanbanSse Pinia store (Chunk 10 of
 * docs/superpowers/plans/2026-06-30-unify-frontend-sse.md).
 *
 * The store no longer opens its own EventSource — it subscribes via
 * `useSseBus().on('kanban', ...)`. Tests:
 *   - install the bus via `installSseBus` + swap in a stub global
 *     client (so we never touch the network in tests)
 *   - drive kanban events via `__dispatchSseBus('kanban', event)` —
 *     the bus test injection point routes the event through the
 *     same `dispatch()` function production uses
 *   - assert the workspace-id filter drops events for other workspaces
 *   - assert the kanban_column / kanban_task dispatch logic calls
 *     `workspacesStore.fetchKanbanColumns` / `fetchKanbanTasks`
 *   - assert `closeKanbanSse` detaches the listener so events after
 *     close are NOT delivered
 *   - assert `setActiveWorkspaceId` updates the filter (without
 *     re-subscribing) — a 2nd call with a different workspaceId
 *     changes the filter on subsequent events
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'

import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useKanbanSseStore } from '../stores/kanbanSse'
import {
  useWorkspacesStore,
  registerRecentLocalMutations,
  RECENT_MUTATION_TTL_MS,
  _clearRecentLocalMutationsForTests,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/** Test-only stub SseClient. Tracks state-listener callbacks so tests
 * can drive the bus's `state` ShallowRef transitions to exercise
 * the `onConnected → fetchInitialKanban` watcher. */
function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('useKanbanSseStore (bus-backed)', () => {
  let app: VueApp
  let stubClient: SseClient

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Install the bus BEFORE initKanbanSse runs — kanbanSseStore calls `useSseBus()` inside
    // initKanbanSse, which throws if the bus hasn't been installed. Replace the underlying
    // SseClient with a stub so we never open a network EventSource in tests.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    stubClient = makeStubClient('connecting')
    __setSseBusGlobalClient(stubClient)
  })

  afterEach(() => {
    // Detach the bus listener so events don't fire into a store whose Pinia is gone —
    // `__resetSseBus` closes the global client which also tears down internal state, but explicit
    // closeKanbanSse covers the case where a test crashed before reaching close.
    try {
      useKanbanSseStore().closeKanbanSse()
    } catch {
      // store not activated in this test → no-op
    }
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: KanbanColumnEvent | KanbanTaskEvent): void {
    __dispatchSseBus('kanban', event)
  }

  it('initKanbanSse subscribes to bus.on(kanban) without opening its own EventSource', async () => {
    // Spy on the global SseClient's close call so we can assert no NEW EventSource was opened by
    // the kanbanSse store. The bus already opened one (in installSseBus, replaced by the stub in
    // beforeEach) — we just verify the store didn't open another.
    const stubCloseSpy = vi.spyOn(stubClient, 'close')

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // The store must NOT close the bus's global client on init.
    expect(stubCloseSpy).not.toHaveBeenCalled()
  })

  it('initKanbanSse is idempotent — second call does NOT add a second listener', async () => {
    // Spy on workspacesStore.fetchKanbanColumns and count how many
    // times it fires per dispatched event. If initKanbanSse added a
    // second listener, the count would double.
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')
    await store.initKanbanSse('ws_1') // 2nd call — should NOT re-subscribe

    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse detaches the bus listener — events after close are dropped', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // First event — listener is wired up, fetch fires.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    store.closeKanbanSse()

    // Second event — listener detached, fetch must NOT fire again.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_2',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse is a no-op when no subscription is active', () => {
    // Activating the store alone (no init) must not throw.
    const store = useKanbanSseStore()
    expect(() => store.closeKanbanSse()).not.toThrow()
  })

  it('triggers fetchKanbanColumns on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (moved action)', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    // Task events refresh TASKS, not columns. fetchKanbanColumns must NOT be called — that would be
    // wasted HTTP traffic (and would mask a future bug where the column handler accidentally picks
    // up task events).
    expect(fetchColumnsSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      undefined,
      undefined,
      undefined,
    )
  })

  it('skips fetchKanbanTasks on self-echo moved events (local-mutation dedupe)', async () => {
    // Drag-and-drop via moveTaskToColumn registers the task id in
    // recentLocalMutations; when the backend fans the `moved` SSE
    // event back to the mover, the handler mirrors + returns WITHOUT
    // the tasks?limit=100 refetch. Remote moves (no registration)
    // still refetch (see the moved test above).
    _clearRecentLocalMutationsForTests()
    try {
      const ws = useWorkspacesStore()
      const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()
      const fetchAllSpy = vi.spyOn(ws, 'fetchKanbanTasksForAllColumns').mockResolvedValue()

      const store = useKanbanSseStore()
      await store.initKanbanSse('ws_1')

      registerRecentLocalMutations(['task_self'], Date.now() + RECENT_MUTATION_TTL_MS)
      const event: KanbanTaskEvent = {
        action: 'moved',
        workspace_id: 'ws_1',
        item_id: 'item_1',
        task_id: 'task_self',
        new_column_id: 'col_done',
        new_position: 0,
      }
      dispatch(event)

      expect(fetchTasksSpy).not.toHaveBeenCalled()
      expect(fetchAllSpy).not.toHaveBeenCalled()
    } finally {
      _clearRecentLocalMutationsForTests()
    }
  })

  it('uses refreshTask (1 row) for remote moved events when the task is cached', async () => {
    // Fast path: the task is already in the local store and the board is on the default view (no
    // search, no custom sort), so the mirror + in-array slot carry the move and one GET confirms
    // server truth — no blind tasks?limit=100 column fetch.
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_1',
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [
              {
                id: 'task_1',
                name: 'cached',
                kanban_column_id: 'col_src',
                kanban_position: 0,
              },
            ],
          },
        ],
      },
    ]
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()
    const fetchAllSpy = vi.spyOn(ws, 'fetchKanbanTasksForAllColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    dispatch({
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    })

    expect(refreshSpy).toHaveBeenCalledTimes(1)
    expect(refreshSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_1')
    expect(fetchTasksSpy).not.toHaveBeenCalled()
    expect(fetchAllSpy).not.toHaveBeenCalled()
  })

  it('falls back to fetchKanbanTasks for moved events when the task is not cached', async () => {
    // The event beat the initial load (or is for an untracked task):
    // the fresh page materializes the missing row, so the full
    // column fetch stays.
    const ws = useWorkspacesStore()
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    dispatch({
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_uncached',
      new_column_id: 'col_done',
      new_position: 0,
    })

    expect(refreshSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      undefined,
      undefined,
      undefined,
    )
  })

  it('falls back to fetchKanbanTasks for cached moved events while searching', async () => {
    // The mirror bypasses the backend q filter, so a cached move
    // during an active search still refetches with q forwarded.
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_1',
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [
              {
                id: 'task_1',
                name: 'cached',
                kanban_column_id: 'col_src',
                kanban_position: 0,
              },
            ],
          },
        ],
      },
    ]
    ws.activeSearchQueries.set('item_1', 'design')
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    dispatch({
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    })

    expect(refreshSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      'design',
      undefined,
      undefined,
    )
  })

  it('falls back to fetchKanbanTasks for cached moved events under a custom sort', async () => {
    // Array order no longer matches the view's order, so the
    // single-row splice can't place the card — refetch with the
    // active sort forwarded.
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_1',
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [
              {
                id: 'task_1',
                name: 'cached',
                kanban_column_id: 'col_src',
                kanban_position: 0,
              },
            ],
          },
        ],
      },
    ]
    ws.activeSortBy.set('item_1', 'name')
    ws.activeSortDirection.set('item_1', 'desc')
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    dispatch({
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    })

    expect(refreshSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      undefined,
      'name',
      'desc',
    )
  })

  it('triggers fetchKanbanTasks on kanban_task events (assigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'assigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_new',
      new_column_id: 'col_1',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_1',
      100,
      undefined,
      undefined,
      undefined,
      undefined,
    )
  })

  it('triggers fetchKanbanTasksForAllColumns on unassigned (no new_column_id)', async () => {
    // Per-column pagination (Option B, 2026-08-06): unassign events
    // have `new_column_id: null` (the task is being detached from any
    // column). We don't know which column it WAS in (the SSE payload
    // doesn't carry the source column id), so conservatively refetch
    // ALL columns via fetchKanbanTasksForAllColumns. For move/assign
    // events with a non-null new_column_id, the single-column
    // fetchKanbanTasks fires (see the moved/assigned tests above).
    const ws = useWorkspacesStore()
    const fetchAllColumnsSpy = vi.spyOn(ws, 'fetchKanbanTasksForAllColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'unassigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: null,
      new_position: null,
    }
    dispatch(event)

    expect(fetchAllColumnsSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      100,
      undefined,
      undefined,
      undefined,
    )
    expect(fetchTasksSpy).not.toHaveBeenCalled()
  })

  it('human_touched: NO refetch — patches needs_human_review in place (chatview-open api-spam fix)', async () => {
    // REGRESSION (2026-08-24): opening a task's chatview fires
    // PUT .../tasks/:id/touched → backend emits kanban_task SSE
    // action=human_touched with new_column_id=null. Pre-fix, that
    // fell into the unassign branch and fired fetchKanbanTasksForAllColumns
    // → one tasks?limit=100 per column (7 calls, ~5 MB on a 270-task
    // board) EVERY time the user opened a chat. The wire payload
    // already carries the after-state (needs_human_review: false),
    // so the handler must patch locally and fetch NOTHING.
    const ws = useWorkspacesStore()
    const fetchAllColumnsSpy = vi.spyOn(ws, 'fetchKanbanTasksForAllColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const applyTouchedSpy = vi.spyOn(ws, 'applyHumanTouched')

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'human_touched',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: null,
      new_position: null,
      needs_human_review: false,
    }
    dispatch(event)

    expect(fetchAllColumnsSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).not.toHaveBeenCalled()
    expect(fetchColumnsSpy).not.toHaveBeenCalled()
    expect(applyTouchedSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_1', false)
  })

  it('forwards the active q to fetchKanbanTasks on kanban_task events (Chunk 7)', async () => {
    // CONTRACT (kanban task search, plan
    // docs/superpowers/plans/2026-07-30-kanban-task-search.md Chunk 7):
    // When the SSE handler triggers a task refetch, it MUST forward
    // the active q from activeSearchQueries so a remote move/edit
    // during a search doesn't reset the user's narrowed view to the
    // unfiltered list.
    const ws = useWorkspacesStore()
    // Seed the activeSearchQueries for item_1.
    ws.activeSearchQueries.set('item_1', 'design')

    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      'design',
      undefined,
      undefined,
    )
  })

  // ─── Active sort forwarding (kanban-sort-by plan Chunk 3) ───
  // The SSE handler refetches tasks on kanban_task events. When the
  // user has picked a sort (e.g. name desc), the refetch MUST use
  // the same sort — otherwise the user's view silently reverts to
  // updated_at desc and the just-received event lands in the wrong
  // visual order. The handler reads activeSortBy +
  // activeSortDirection (written by fetchKanbanTasks on the most
  // recent user-initiated fetch) and forwards them.
  it('forwards the active sort to fetchKanbanTasks on kanban_task events', async () => {
    const ws = useWorkspacesStore()
    // Seed both maps for the matching item id. activeSortDirection is
    // intentionally a separate Map (rather than a tuple Map value)
    // to mirror the activeSearchQueries pattern in the same store.
    ws.activeSortBy.set('item_1', 'name')
    ws.activeSortDirection.set('item_1', 'desc')

    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    // 7-arg signature: (ws, item, limit, cursor, q, sortBy, direction).
    expect(fetchTasksSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'col_done',
      100,
      undefined,
      undefined,
      'name',
      'desc',
    )
  })

  it('forwards sortBy=undefined / direction=undefined when no active sort is recorded', async () => {
    // The default case (no user-picked sort) — loadMoreTasks + SSE refetches both default to
    // undefined so the api layer applies its back-compat 'updated_at' / 'desc' default. This keeps
    // the existing pre-fix behaviour intact.
    const ws = useWorkspacesStore()
    // Don't seed the maps.
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    const lastCall = fetchTasksSpy.mock.calls[fetchTasksSpy.mock.calls.length - 1]!
    expect(lastCall[4]).toBeUndefined() // q
    expect(lastCall[5]).toBeUndefined() // sortBy
    expect(lastCall[6]).toBeUndefined() // direction
  })

  it('forwards q=undefined to fetchKanbanTasks when no search active (Chunk 7)', async () => {
    const ws = useWorkspacesStore()
    // No q set in activeSearchQueries.
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    const lastCall = fetchTasksSpy.mock.calls[fetchTasksSpy.mock.calls.length - 1]!
    expect(lastCall[4]).toBeUndefined() // q = undefined
  })

  it('triggers fetchKanbanColumns (NOT fetchKanbanTasks) on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchColumnsSpy).toHaveBeenCalledWith('ws_1', 'item_1')
    // Column events must NOT trigger task fetches — they're a
    // different shape of mutation (rename / reorder / add / delete
    // columns don't change task positions).
    expect(fetchTasksSpy).not.toHaveBeenCalled()
  })

  it('ignores events for other workspaces (filter is per-store)', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Event for a DIFFERENT workspace — the store's filter drops it
    // before reaching the workspacesStore fetch call. The bus's
    // kanban channel is global (the backend fans out kanban events
    // to every connected client), so the client-side filter is what
    // keeps each workspace's kanban state scoped.
    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_OTHER',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('setActiveWorkspaceId updates the filter without re-subscribing', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Switch to ws_2 — the same bus listener now filters by 'ws_2'.
    // Calling setActiveWorkspaceId is idempotent w.r.t. the listener
    // (it updates the ref'd filter, doesn't detach/re-attach).
    await store.setActiveWorkspaceId('ws_2')

    // ws_1 event — must be dropped (filter is now 'ws_2').
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).not.toHaveBeenCalled()

    // ws_2 event — must trigger the fetch.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_2',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledWith('ws_2', 'item_1')
  })

  it('fetches initial kanban columns on bus state transition to "open"', async () => {
    // The bus's global stub is in 'connecting' state at the start of the test (set in beforeEach).
    // initKanbanSse watches bus state and triggers fetchInitialKanban on 'open' (with immediate:
    // true covering the fast path where the bus is already 'open' at registration time).
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    // Seed the workspaces store with a kanban item so the fetch
    // passes the "active item is kanban in the active workspace"
    // guard in fetchInitialKanban.
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_1',
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [],
          },
        ],
      },
    ]
    ws.setActiveWorkspaceItem('item_1')

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Drive the state transition to 'open'.
    emitStubState(stubClient, 'open')

    // The watch is async (Vue default) so we need to drain a
    // microtask before asserting on the call count.
    await nextTick()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
