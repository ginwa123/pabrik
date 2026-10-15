/** Tests for the workspaces store's session-events handling. The backend cascade for task rename
 * emits a `session.updated` event on /api/sessions/stream. */
/** After the unify-frontend-sse migration (Chunk 6), the workspaces store receives session events
 * through the global sseBus (opened once by App.vue) rather than opening its own EventSource. */
/** We use the bus's test injection point (`__dispatchSseBus`) to drive events deterministically.
 * task.id == session_id (per AppLayout.vue:651 `:chat-id="activeTask.id"`), so the lookup is a
 * straight equality match on task.id. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import type { SessionEvent } from '../api'

/**  * Test-only stub SseClient. We don't drive state transitions from these tests (the bus's `state`
 * ShallowRef is not asserted here), but the install path requires a real-looking client — see
 * sseBus.spec.ts / App.spec.ts for the same helper. */
function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

describe('useWorkspacesStore session events (via sseBus)', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Install the bus BEFORE the store's `init()` is called — `installSessionEventHandlers` invokes
    // `useSseBus()` which throws if the bus hasn't been installed yet. Replace the underlying
    // SseClient so we never touch the network in tests.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    // Stub the workspaces/items API so init() doesn't hit the
    // network. The same stub pattern is used by
    // workspacesStoreInit.spec.ts and workspacesStoreTaskTypes.spec.ts.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  /**    * Install the bus-backed handlers AND seed the store. Order matters: `init()` resets
   * `workspaces.value` to `[]` on completion (or to the fetched list), so we seed AFTER the install
   * call returns. */
  async function setupHandlersAndSeed() {
    const ws = useWorkspacesStore()
    await ws.init()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_a',
            name: 'A',
            item_type: 'folder',
            tasks: [{ id: 'task_1', name: 'Original' }],
          },
        ],
      },
    ]
    return ws
  }

   
  function dispatch(event: SessionEvent) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    __dispatchSseBus('session', event as any)
  }

  it('installs a session handler on init (idempotent — second init does not double-register)', async () => {
    const ws = useWorkspacesStore()
    // First init — installs the handler, resets workspaces.value to [].
    await ws.init()
    // Second init — must NOT double-register the handler. The install flag is closure-scoped inside
    // the store, so a second init() in the same store IS the no-op path (the flag is already true).
    await ws.init()
    // Seed after the second init so the handler has data to mutate.
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [{ id: 'item_a', name: 'A', item_type: 'folder', tasks: [{ id: 'task_1', name: 'Original' }] }],
      },
    ]

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'Renamed',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Renamed')
  })

  it('updates a matching task name on session.updated', async () => {
    const ws = await setupHandlersAndSeed()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New Name from SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('New Name from SSE')
  })

  it('keeps navigationStore.activeChatName in sync when the updated task is the active one', async () => {
    const nav = useNavigationStore()
    nav.setActiveChatName('Original')
    const ws = await setupHandlersAndSeed()
    ws.setActiveTask('task_1')

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'Renamed via SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(nav.activeChatName).toBe('Renamed via SSE')
  })

  it('does NOT touch navigationStore when the updated task is not the active one', async () => {
    const nav = useNavigationStore()
    const ws = await setupHandlersAndSeed()
    ws.setActiveTask('other_task')
    // Re-apply the header AFTER setActiveTask — as of 2026-07-14,
    // workspacesStore.setActiveTask calls clearActiveChat on the
    // navigation store (see the regression test below for the
    // rationale), so we need to set the header explicitly here to
    // isolate the "SSE event handler ignores non-active task" contract.
    nav.setActiveChatName('Other Task Header')

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'Renamed via SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    // Active header stays put.
    expect(nav.activeChatName).toBe('Other Task Header')
  })

  it('leaves the task name unchanged when no task matches the event id', async () => {
    const ws = await setupHandlersAndSeed()

    dispatch({
      action: 'updated',
      id: 'nonexistent_task',
      name: 'Irrelevant',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
  })

  it('removes a task on session.deleted', async () => {
    const ws = await setupHandlersAndSeed()

    expect(ws.workspaces[0]!.items[0]!.tasks).toHaveLength(1)
    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })
    expect(ws.workspaces[0]!.items[0]!.tasks).toHaveLength(0)
  })

  it('clears activeTaskId when the deleted task was active', async () => {
    const ws = await setupHandlersAndSeed()
    ws.setActiveTask('task_1')

    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })
    expect(ws.activeTaskId).toBeNull()
  })

  // Regression: switching from a chat to a task used to leave the
  // navigation store's `activeChatId` populated with the prior chat's
  // id. The next SSE session_created event (broadcast on every
  // /api/llm/session POST — session_create.zig:230-240) drives
  // ChatsList.loadChats, which finds the orphan activeChatId in
  // navigation.sessionId, emits a `navigate chat-<old_id>`, and the
  // AppLayout drops the user out of the task they were just typing
  // into and back into the prior chat. Mirrors the navigation
  // store's own setActiveTask (navigation.ts:123-132), which has
  // always cleared activeChatId on every set.
  it('setActiveTask clears navigationStore.activeChatId on non-null taskId', async () => {
    const ws = await setupHandlersAndSeed()
    const nav = useNavigationStore()
    // Simulate "user was viewing a chat, then clicks a task". navigationStore.setActiveChat
    // prepends `chat-` to the session id passed in, so passing 'old_session' yields activeChatId
    // === 'chat-old_session'.
    nav.setActiveChat('old_session', 'Old Chat')
    expect(nav.activeChatId).toBe('chat-old_session')

    ws.setActiveTask('task_1')

    expect(nav.activeChatId).toBe('')
    expect(nav.activeChatName).toBe('')
    expect(ws.activeTaskId).toBe('task_1')
  })

  it('setActiveTask(null) does NOT clear navigationStore.activeChatId', async () => {
    // REGRESSION (2026-07-16, `view=chat&session=X` showed welcome page
    // instead of <ChatView>): the unconditional `clearActiveChat()`
    // in `setActiveTask` was breaking the chat-nav paths in
    // Sidebar.vue:316-322 and ChatsList.vue:220-232, where
    // `setActiveChat(...)` is called immediately BEFORE
    // `setActiveTask(null)`. The clear undid the just-set chat and
    // left `activeChatId === ''`, so the v-else-if chain at
    // AppLayout.vue:1611 (`activeChatId.startsWith('chat-')`) failed
    // and fell through to <Chats/> (welcome). Now: clearing the
    // task must NOT clear the chat — callers that need both cleared
    // (e.g. handleCloseTaskView in AppLayout.vue:528) explicitly
    // call `navigationStore.clearActiveChat()` themselves.
    const ws = await setupHandlersAndSeed()
    const nav = useNavigationStore()
    ws.setActiveTask('task_1')
    nav.setActiveChat('post_close', 'Some Chat')

    ws.setActiveTask(null)

    expect(nav.activeChatId).toBe('chat-post_close')
    expect(nav.activeChatName).toBe('Some Chat')
    expect(ws.activeTaskId).toBeNull()
  })

  it('setActiveTask(taskId) DOES clear navigationStore.activeChatId', async () => {
    // The opposite-direction invariant: ACTIVATING a task must clear
    // any active chat, otherwise the v-else-if chain at
    // AppLayout.vue:1459 (`currentView === 'task' && activeTask`)
    // and the v-else-if at AppLayout.vue:1611
    // (`activeChatId.startsWith('chat-')`) would BOTH be true,
    // picking whichever renders first (whichever v-else-if chain
    // wins) and leaving the other branch out of sync. The previous
    // unconditional `clearActiveChat()` happened to satisfy this
    // requirement as a side effect of also clearing on null — the
    // new conditional version preserves the "activate a task → no
    // chat left over" contract.
    const ws = await setupHandlersAndSeed()
    const nav = useNavigationStore()
    nav.setActiveChat('pre_task', 'Pre-Task Chat')
    expect(nav.activeChatId).toBe('chat-pre_task')

    ws.setActiveTask('task_1')

    expect(nav.activeChatId).toBe('')
    expect(nav.activeChatName).toBe('')
    expect(ws.activeTaskId).toBe('task_1')
  })

  // ─── onSessionEvent fan-out (ChatsList regression fix) ─────────────────── The internal handler
  // mutates workspace tree state.

  // External components (ChatsList.vue's `navItems` mirror) need to be notified too — they have
  // their own shape (relativeTime, processing flag, etc.) that's not derived from the workspace
  // tree.

  // The fan-out fires after the internal handler so subscribers can safely re-fetch from the API.
  it('fan-outs session.updated events to onSessionEvent subscribers', async () => {
    const ws = await setupHandlersAndSeed()

    const cb = vi.fn()
    const unsub = ws.onSessionEvent(cb)

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New Name',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'updated', id: 'task_1', name: 'New Name' }),
    )

    unsub()
  })

  it('fan-outs session.deleted events to onSessionEvent subscribers', async () => {
    const ws = await setupHandlersAndSeed()

    const cb = vi.fn()
    ws.onSessionEvent(cb)

    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(expect.objectContaining({ action: 'deleted', id: 'task_1' }))
  })

  it('fan-outs session.created events to onSessionEvent subscribers', async () => {
    // The internal handler deliberately ignores 'created' (tasks are created via POST /tasks, not
    // via session.created) — but external subscribers like ChatsList still need to see the event so
    // the new session appears in their list.
    const ws = await setupHandlersAndSeed()

    const cb = vi.fn()
    ws.onSessionEvent(cb)

    dispatch({
      action: 'created',
      id: 'task_new',
      name: 'Brand New Session',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-01T00:00:00Z',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'created', id: 'task_new' }),
    )
  })

  it('onSessionEvent returns an unsubscribe function that detaches the callback', async () => {
    const ws = await setupHandlersAndSeed()

    const cb = vi.fn()
    const unsub = ws.onSessionEvent(cb)
    unsub()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(cb).not.toHaveBeenCalled()
  })

  it('swallows errors thrown by subscribers without breaking the SSE stream', async () => {
    const ws = await setupHandlersAndSeed()

    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const goodCb = vi.fn()
    ws.onSessionEvent(() => {
      throw new Error('subscriber bug')
    })
    ws.onSessionEvent(goodCb)

    // Should NOT throw out of the dispatch path.
    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    // Both subscribers got called (the throwing one threw, was
    // caught + logged, and the next subscriber still ran).
    expect(consoleSpy).toHaveBeenCalled()
    expect(goodCb).toHaveBeenCalledTimes(1)
    consoleSpy.mockRestore()
  })
})