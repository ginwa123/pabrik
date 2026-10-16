// src/apps/desktop/src/composables/useCurrentMainView.spec.ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { reactive, nextTick } from 'vue'
import { useCurrentMainView } from './useCurrentMainView'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function mockRoute(
  query: Record<string, string>,
  path = '/app',
  params: Record<string, string> = {},
) {
  // `reactive` so post-mount mutations trigger the computed.
  const fullPath =
    path + (Object.keys(query).length ? '?' + new URLSearchParams(query).toString() : '')
  const obj = reactive({ query, path, params, fullPath })

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouteMock.mockReturnValue(obj as any)
  return obj
}

describe('useCurrentMainView', () => {
  beforeEach(() => {
    useRouteMock.mockReset()
  })

  it('returns chat view when URL is ?view=chat&session=X', () => {
    mockRoute({ view: 'chat', session: 'session_abc' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_abc' })
  })

  it('returns workspace view with chatTaskId when URL is ?view=workspace&itemId=Y/chat/task_Z', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban/chat/task_xyz',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
      pageId: undefined,
      chatTaskId: 'task_xyz',
    })
  })

  it('returns workspace view without chatTaskId when itemId is bare', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
      pageId: undefined,
      chatTaskId: undefined,
    })
  })

  it('returns workspace view with pageId when URL has pageId', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
      chatTaskId: undefined,
    })
  })

  it('returns workspace view (no itemId) for standalone ?view=workspace&workspaceId=X', () => {
    // Header-dropdown workspace switch with no item open — the
    // selection-only URL shape (revamp plan 2026-09-22). itemId is
    // absent so no sidebar row is active.
    mockRoute({ view: 'workspace', workspaceId: 'ws_7' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'workspace', workspaceId: 'ws_7' })
  })

  it('returns none for a legacy bare ?view=workspace (no workspaceId, no itemId)', () => {
    mockRoute({ view: 'workspace' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('returns none when URL is empty', () => {
    mockRoute({})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('returns none when URL is a non-content view (settings)', () => {
    mockRoute({ view: 'settings' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('reacts to URL changes (computed re-runs when route.query mutates)', async () => {
    const route = mockRoute({})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
    route.query = { view: 'chat', session: 'session_now' }
    await nextTick()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_now' })
  })

  it('does NOT have a kind=task variant (legacy view=task URLs are auto-rewritten on mount)', () => {
    // Sanity: the legacy shape ?view=task&task=X is not handled by this composable —
    // AppLayout.onMounted silently rewrites those URLs to the new shape before the composable is
    // consulted. This test pins the contract.
    mockRoute({ view: 'task', task: 'task_old' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value.kind).toBe('none')
  })

  // ──────────────────────────────────────────────────────────────────
  // kanban-settings variant (plan: 2026-09-02-kanban-settings-as-page)
  // Path-based vue-router route /app/kanban/:itemId/settings.
  // itemId comes from route.params; workspaceId is optional and
  // comes from ?workspaceId=X query (used by the back navigation).
  // ──────────────────────────────────────────────────────────────────
  it('returns kanban-settings view when URL is /app/kanban/:itemId/settings', () => {
    mockRoute({}, '/app/kanban/item_kanban/settings', { itemId: 'item_kanban' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: 'item_kanban',
    })
  })

  it('returns kanban-settings view with workspaceId when ?workspaceId=X is on the path', () => {
    mockRoute({ workspaceId: 'ws_1' }, '/app/kanban/item_kanban/settings', {
      itemId: 'item_kanban',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
    })
  })

  it('returns kanban-settings view with empty itemId when the path lacks :itemId (defensive)', () => {
    // Path is /app/kanban//settings (double slash) — Vue Router would
    // normally reject this, but we want the composable to degrade
    // gracefully so the sidebar can still react.
    mockRoute({}, '/app/kanban//settings', { itemId: '' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value.kind).toBe('kanban-settings')
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: '',
    })
  })

  it('reacts to URL changes for kanban-settings (computed re-runs when route.path mutates)', async () => {
    const route = mockRoute({}, '/app', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
    // Simulate vue-router's navigation — both path and params update.
    route.path = '/app/kanban/item_now/settings'
    route.params = { itemId: 'item_now' }
    await nextTick()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: 'item_now',
    })
  })

  it('does NOT match kanban-settings for unrelated paths like /app/settings', () => {
    mockRoute({}, '/app/settings', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    // /app/settings is its own view — the composable's chat/workspace
    // branches don't match it either, so it falls through to 'none'.
    expect(v.value).toEqual({ kind: 'none' })
  })

  // Path-based contract (2026-09-22 revamp). A project is a workspace
  // item, so path projects map onto the `workspace` kind.
  it('returns none for the /app landing', () => {
    mockRoute({}, '/app', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('returns workspace for /app/{ws}', () => {
    mockRoute({}, '/app/ws_1', { workspaceId: 'ws_1' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
  })

  it('returns chat with workspaceId for /app/{ws}/chat/{sid}', () => {
    mockRoute({}, '/app/ws_1/chat/sess_9', { workspaceId: 'ws_1', sessionId: 'sess_9' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'sess_9', workspaceId: 'ws_1' })
  })

  it('returns workspace with itemId for /app/{ws}/projects/{pid}', () => {
    mockRoute({ pageId: 'page_1' }, '/app/ws_1/projects/item_7', {
      workspaceId: 'ws_1',
      projectId: 'item_7',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_7',
      pageId: 'page_1',
      chatTaskId: undefined,
    })
  })

  it('returns workspace with chatTaskId for /app/{ws}/projects/{pid}/chat/{tid}', () => {
    mockRoute({}, '/app/ws_1/projects/item_7/chat/task_3', {
      workspaceId: 'ws_1',
      projectId: 'item_7',
      taskId: 'task_3',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_7',
      pageId: undefined,
      chatTaskId: 'task_3',
    })
  })

  it('legacy ?view=chat on /app still parses (boot rewrite converts it)', () => {
    mockRoute({ view: 'chat', session: 'session_abc' }, '/app', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_abc' })
  })

  // ── Document page (Migration 095) ─────────────────────────────────── `/app/{ws}/doc/{id}` is a
  // PATH shape: the document REPLACES the main view instead of layering `?doc=` over whatever was
  // open.
  it('returns the document view for a /doc/ path', () => {
    mockRoute({}, '/app/ws_1/doc/doc_1')
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'document', documentId: 'doc_1', workspaceId: 'ws_1' })
  })

  it('a /doc/ path tolerates a trailing slash', () => {
    mockRoute({}, '/app/ws_1/doc/doc_1/')
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'document', documentId: 'doc_1', workspaceId: 'ws_1' })
  })

  it('the doc path wins over a chat/project path', () => {
    // A leftover query from the old overlay must not out-rank the path,
    // and a doc path must not be mistaken for a workspace called "doc".
    mockRoute({ doc: 'doc_stale' }, '/app/ws_1/doc/doc_1')
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'document', documentId: 'doc_1', workspaceId: 'ws_1' })
  })

  it('reacts to path navigation between two documents (Back/Forward)', async () => {
    const route = mockRoute({}, '/app/ws_1', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })

    route.path = '/app/ws_1/doc/doc_1'
    await nextTick()
    expect(v.value).toEqual({ kind: 'document', documentId: 'doc_1', workspaceId: 'ws_1' })

    route.path = '/app/ws_1/doc/doc_2'
    await nextTick()
    expect(v.value).toEqual({ kind: 'document', documentId: 'doc_2', workspaceId: 'ws_1' })
  })

  it('a stale ?doc= query no longer names a document', () => {
    // Migration 095 shipped documents as a `?doc=` overlay and was replaced by the `/doc/` path
    // before that shape was in wide use, so there is no fallback.
    mockRoute({ doc: 'doc_1' }, '/app/ws_1')
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
  })

  it('reacts to path navigation (computed re-runs when route.path mutates)', async () => {
    const route = mockRoute({}, '/app', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() {
      v = useCurrentMainView()
    }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
    route.path = '/app/ws_1/chat/sess_9'
    await nextTick()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'sess_9', workspaceId: 'ws_1' })
  })
})
