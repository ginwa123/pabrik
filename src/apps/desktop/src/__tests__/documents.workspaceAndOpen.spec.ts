/** Regression specs for the two Documents-feature failures a user reported against Migration 095
 * ("Documents" sidebar section + viewer). BUG 1 — "No workspace selected" with a workspace plainly
 * selected. */

/** `Sidebar.vue` bound `DocumentsList`'s `workspace-id` prop to the RAW
 * `workspacesStore.activeWorkspaceId` ref, and `DocumentsView.vue` read the same ref for its own
 * fetch scope. */

/** That ref is only set by the header dropdown or a `?workspaceId=` URL restore — clicking a
 * project row under PROJECTS sets only `activeWorkspaceItemId`. */

/** Every other consumer in the tree binds `activeWorkspace?.id ?? null`, the computed carrying the
 * documented precedence fallback (explicit → persisted → item-owning workspace → first workspace).
 * Documents was the only section still on the raw ref. */

/** Why the old specs missed it: `DocumentsList.spec.ts` mounts the component with an explicit
 * `workspaceId: 'ws_1'` PROP, so it can only ever test the component, never the binding that feeds
 * it. */

/** Test 1 below therefore mounts the real `Sidebar`, which is the only way to exercise that
 * binding. BUG 2 — clicking a document row did nothing. A two-hop loop in AppLayout, not the
 * one-hop race the store comment describes. */

/** Verified hop by hop: hop 2 — the URL→store watcher watches `[route.path, route.query]`, so a
 * query-only `?doc=` change re-ran the project branch and re-adopted the path's project. */

/** Its `isOverlayView` guard covered gitfile/skill/code-editor but NOT `doc`, even though
 * `currentView` and `useCurrentMainView` both check `doc` FIRST. */

/** This watcher was the one place that didn't. hop 3 — that re-adoption re-fired the store→URL
 * mirror, whose `sub` whitelist was pageId/sorts/detail only, so `router.replace(target)` dropped
 * `doc`. */

/** Note the mirror's local `currentView` is a raw `route.query.view` read that shadows the
 * computed, so on a path-based URL (no `view=` param) its guard passes and hop 3 runs. Net effect:
 * the click's own navigation was undone a microtask later, which is exactly "nothing happens". */

/** Both hops existed only because a document was a `?doc=` OVERLAY. It is now a
 * `/app/{ws}/doc/{id}` page, so the watcher guard and the mirror's `doc` carry are both gone — the
 * class of bug has no mechanism left. */

/** These specs now pin the page contract that replaced it, plus that a stray `?doc=` no longer
 * opens anything. ── Note on how these specs are shaped ── The watcher tests need `useRoute` to
 * hand back a REACTIVE object that the test mutates AFTER mount. */

/** A plain object per test (the shape `sidebarSingleActive.spec.ts` uses, and
 * `AppLayout.chatClickUrlOverwrite` relies on) never re-triggers `[route.path, route.query]`, so
 * the whole hop-2 → hop-3 chain silently does not run and the specs pass against the broken
 * code. */

/** Verified: with a plain route object these two tests are green on pre-fix source. `route` below
 * is `reactive()` and the tests navigate by assigning to it. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, reactive, ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import * as realApi from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useDocumentsStore } from '../stores/documents'
import AppLayout from '../components/AppLayout.vue'
import Sidebar from '../components/shell/Sidebar.vue'
import DocumentsView from '../components/workspace/DocumentsView.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const listDocuments = vi.hoisted(() => vi.fn())
const getDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    getDocument,
    getChats: vi.fn(),
    getWorkspaces: vi.fn(),
    getWorkspacesItems: vi.fn(),
    getTasks: vi.fn(),
    getSystemFolder: vi.fn(),
    getFolderContents: vi.fn(),
    createDocument: vi.fn(),
    updateDocument: vi.fn(),
    deleteDocument: vi.fn(),
  }
})

const { useRouteMock, useRouterMock, replaceMock, pushMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
  replaceMock: vi.fn(),
  pushMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

function makeStubClient(): SseClient {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    isConnected: () => true,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    state: 'open',
    lastError: null,
  } as unknown as SseClient
}

const WS_ID = 'ws_docs'
const ITEM_ID = 'item_kanban'
const DOC_ID = 'doc_1'
const PROJECT_PATH = `/app/${WS_ID}/projects/${ITEM_ID}`

const DOC = {
  id: DOC_ID,
  workspace_id: WS_ID,
  title: 'Release plan',
  content: '# Heading',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
}

/** One workspace owning one project — the shape in the user's screenshot. */
function makeWorkspace() {
  return {
    id: WS_ID,
    name: 'agentic coding',
    icon: '📁',
    expanded: true,
    items: [{ id: ITEM_ID, name: 'AGENTIC_KANBAN', item_type: 'kanban', tasks: [] }],
  }
}

/** The pre-bug state: workspaces loaded, a project selected, but the
 *  explicit workspace ref never set (nobody used the header dropdown). */
function seedProjectClickNavigation() {
  const ws = useWorkspacesStore()
  ws.workspaces = [makeWorkspace()]
  ws.setActiveWorkspaceItem(ITEM_ID)
  // Asserted, not assumed: the whole point is that this stays null while
  // the app still knows a workspace is selected.
  expect(ws.activeWorkspaceId).toBe(null)
  return ws
}

/** REACTIVE route — the test navigates by assigning to it after mount. */
const route = reactive({
  path: '/app',
  query: {} as Record<string, string>,
  fullPath: '/app',
})

function navigate(path: string, query: Record<string, string> = {}) {
  route.path = path
  route.query = { ...query }
  const qs = new URLSearchParams(query).toString()
  route.fullPath = path + (qs ? `?${qs}` : '')
}

/**  * The documents list is cache-first now, and `documentEngineDb` is a module singleton whose
 * IndexedDB fallback is a module-level Map — so rows cached by one test are still primed by the
 * next one. Every test here asserts a COLD start, so each one begins from an empty cache. */
async function clearDocumentsCache(workspaceId: string): Promise<void> {
  const { documentEngineDb } = await import('../sync/DocumentEngineDb')
  const { runSyncVoid } = await import('../sync/runtime')
  await runSyncVoid(documentEngineDb.clear(workspaceId), 'spec.clearDocumentsCache')
}

beforeEach(async () => {
  await clearDocumentsCache(WS_ID)
  setActivePinia(createPinia())
  document.body.innerHTML = ''
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient())

  navigate('/app', {})
  useRouteMock.mockReturnValue(route)
  useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock })
  replaceMock.mockReset()
  replaceMock.mockReturnValue(Promise.resolve())
  pushMock.mockReset()

  listDocuments.mockReset()
  getDocument.mockReset()
  listDocuments.mockResolvedValue({ documents: [DOC], count: 1 })
  getDocument.mockResolvedValue({ document: DOC })
  vi.mocked(realApi.getChats).mockResolvedValue({
    sessions: [],
    has_more: false,
    next_cursor: null,
    total: 0,
  })
  vi.mocked(realApi.getWorkspaces).mockResolvedValue({ workspaces: [] })
  vi.mocked(realApi.getWorkspacesItems).mockResolvedValue({ items: [], count: 0 })
  vi.mocked(realApi.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  vi.mocked(realApi.getSystemFolder).mockResolvedValue({
    path: '/',
    absolute: '/',
    home: '/',
    entries: [],
  } as never)
})

afterEach(() => {
  __resetSseBus()
  vi.clearAllMocks()
})

/**  * The list load is cache-first now (IndexedDB read, then revalidate), so the painted rows land on a
 * promise boundary rather than a microtask. Four `nextTick()`s no longer reach them — this does. */
const flush = async () => {
  await flushPromises()
  for (let i = 0; i < 2; i++) await nextTick()
}

// ─── BUG 1 ────────────────────────────────────────────────────────────────

describe('Documents — a project click still counts as "a workspace is selected"', () => {
  it('the sidebar section lists documents instead of "No workspace selected"', async () => {
    seedProjectClickNavigation()

    const wrapper = mount(Sidebar, {
      global: {
        mocks: { $router: { replace: vi.fn(), push: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
    await flush()

    // The regression: the Documents section said "No workspace selected" while PROJECTS showed a
    // plainly-selected project. Mounting the real Sidebar is the only way to see this — the
    // component-level spec passes a `workspaceId` prop and so never sees the binding.
    expect(wrapper.find('[data-testid="documents-section-body"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-no-workspace"]').exists()).toBe(false)
    // And it actually scoped the fetch to the right workspace.
    expect(listDocuments).toHaveBeenCalledWith(WS_ID)
    expect(wrapper.find(`[data-testid="document-row-${DOC_ID}"]`).exists()).toBe(true)
    wrapper.unmount()
  })

  it('the viewer resolves the workspace and fetches, instead of hanging on "Loading document…"', async () => {
    // DocumentsView receives only `documentId` — it has to learn the
    // workspace from the store itself. Pre-fix its `watch` bailed on a
    // null workspace, so no fetch ever happened.

    // The documents store is deliberately LEFT EMPTY: `loadDocument`
    // short-circuits on a cache hit, so seeding it would make the spec
    // pass on the broken code. The fetch call is the assertion.
    seedProjectClickNavigation()
    const wrapper = mount(DocumentsView, { props: { documentId: DOC_ID } })
    await flush()

    expect(getDocument).toHaveBeenCalledWith(WS_ID, DOC_ID)
    wrapper.unmount()
  })

  it('with the document already listed, the editor and its controls render', async () => {
    // Rendering contract, reached the way a real click reaches it: the
    // sidebar has listed the workspace, so `findById` serves the body.
    seedProjectClickNavigation()
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true
    const wrapper = mount(DocumentsView, { props: { documentId: DOC_ID } })
    await flush()

    expect(wrapper.get('[data-testid="documents-title"]').text()).toBe('Release plan')
    // The control the user was looking for: "the ui to adjust documents".
    expect(wrapper.find('[data-testid="documents-edit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-delete"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

// ─── BUG 2 ────────────────────────────────────────────────────────────────

const STUB_CONFIG = {
  Sidebar: true,
  RightSidebar: true,
  GitFileViewer: true,
  SkillDetail: true,
  Chats: true,
  SettingsView: true,
  ChatView: true,
  CodeEditor: true,
  KanbanView: {
    template: '<div data-kanban-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
  DesignView: {
    template: '<div data-design-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
}

function replacesDroppingDoc() {
  return replaceMock.mock.calls.filter((call) => {
    const q = (call[0] ?? {}).query as Record<string, string> | undefined
    return q && q.doc === undefined
  })
}

const DOC_PATH = `/app/${WS_ID}/doc/${DOC_ID}`

describe('AppLayout — a document is a PAGE, not a ?doc= overlay', () => {
  it('a document click is not undone a microtask later by the store->URL mirror', async () => {
    // The user's exact state: sitting on a PROJECT path, because that is
    // where the Documents section lives. The click navigates to the doc
    // PATH now, so there is no `doc` query for the mirror to strip.
    navigate(PROJECT_PATH)
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    ws.setActiveWorkspaceItem(ITEM_ID)
    await flush()
    replaceMock.mockClear()

    // DocumentsList.selectDocument's exact order: the router.replace is
    // async, so the synchronous store writes below happen FIRST and the
    // navigation lands a microtask later.
    ws.setActiveWorkspaceItem(null)
    ws.setActiveTask(null)
    await flush()
    navigate(DOC_PATH)
    await flush()

    // The regression this file was written for: the mirror re-adopted the project from the path and
    // then router.replace'd a URL that lost the document, so the click appeared to do nothing. With
    // the document on its own path the mirror has no `doc` to drop.
    expect(replacesDroppingDoc()).toHaveLength(0)

    // And the URL->store watcher must not re-adopt the project either: the
    // document is the main content, so re-highlighting the project row
    // behind it is the "two active rows" bug sidebarSingleActive guards.
    expect(ws.activeWorkspaceItemId).toBe(null)
    wrapper.unmount()
  })

  it('a cold boot on a document path keeps the document and drops the project', async () => {
    // The refresh / shared-link case. Before the path shape this was a second, click-free way to
    // lose the open document: the URL restore adopted the item from the path and the mirror fired
    // with no prior state to bail on.
    navigate(DOC_PATH)
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]

    // The document is open, and no `?doc=` was invented on the way in.
    expect(wrapper.find('[data-testid="documents-view"]').exists()).toBe(true)
    expect(replacesDroppingDoc()).toHaveLength(0)
    wrapper.unmount()
  })

  it('the document REPLACES the main view instead of stacking over it', async () => {
    // The heart of the change. As an overlay this rendered alongside the chat/kanban underneath,
    // and the chat's floating chrome out-painted the overlay's z-index (PR #749). A page unmounts
    // what it replaces, so the overlap cannot happen at all.
    navigate(PROJECT_PATH)
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    ws.setActiveWorkspaceItem(ITEM_ID)
    await flush()
    expect(wrapper.find('[data-kanban-view="stub"]').exists()).toBe(true)

    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true
    navigate(DOC_PATH)
    await flush()

    // DocumentsView is deliberately NOT stubbed — the assertion is about
    // which branch of the main-view chain wins.
    expect(wrapper.find('main [data-testid="documents-view"]').exists()).toBe(true)
    // ...and the view it replaced is gone, not merely covered.
    expect(wrapper.find('[data-kanban-view="stub"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('a document path CLEARS the active chat, so no ChatView mounts under it', async () => {
    // The bug this pins is subtle and survived two earlier specs. <main>
    // does NOT have one v-if chain: the standalone `v-if` on
    // <DesignChatDialog> splits it in two, so <DocumentsView> (early, first chain) and the
    // standalone `<ChatView v-else-if="activeChatId…">` (late, second chain) are in DIFFERENT
    // chains.

    // Independent chains are not mutually exclusive, so with `activeChatId` still set the chat
    // rendered UNDERNEATH the document page.

    // It hid from the specs for two reasons: the kanban-path spec above has no active chat (so the
    // ChatView branch is false for an unrelated reason), and a hard page load has no chat state
    // either.

    // It only shows when a CHAT is active and the user clicks a row — which is why the Playwright
    // test drives an actual click.
    const { useNavigationStore } = await import('../stores/navigation')
    navigate(DOC_PATH)
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true

    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const nav = useNavigationStore()
    // Pretend a standalone chat session is open — the state the repro has.
    nav.setActiveChat('sess_live', 'live chat')
    await flush()
    expect(nav.activeChatId).toBe('chat-sess_live')

    // Re-enter the doc path (what a click / Back-Forward does).
    navigate(DOC_PATH)
    await flush()

    // The chat selection must be dropped by the URL->store watcher.
    expect(nav.activeChatId).toBe('')
    // ...and with it gone the second chain cannot mount a ChatView, so the
    // document is the ONLY thing under <main>.
    expect(wrapper.find('main [data-testid="documents-view"]').exists()).toBe(true)
    expect(wrapper.find('main .chat-column').exists()).toBe(false)
    expect(wrapper.find('main .composer-dock').exists()).toBe(false)
    wrapper.unmount()
  })

  it('a stale ?doc= URL is NOT rewritten to the document path', async () => {
    // No fallback by design: Migration 095 shipped the overlay shape and was replaced by the
    // `/doc/` path before it was in wide use, so there are no links in the wild to keep working.

    // Rendering the document here would restore the ambiguous URL that says nothing about which
    // page owns the document.

    // Assert the REPLACE, not the rendered view: `router` is a mock here, so a boot rewrite would
    // not actually move the route and `documents-view` would stay absent either way. Asserting the
    // view would be a green test that passes whether or not the rewrite exists.

    // The absence of a `router.replace` to the doc path is the observable difference.
    navigate(PROJECT_PATH, { doc: DOC_ID })
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const rewroteToDoc = replaceMock.mock.calls.filter((call) => (call[0] ?? {}).path === DOC_PATH)
    expect(rewroteToDoc).toHaveLength(0)
    expect(wrapper.find('[data-testid="documents-view"]').exists()).toBe(false)
    wrapper.unmount()
  })
})
