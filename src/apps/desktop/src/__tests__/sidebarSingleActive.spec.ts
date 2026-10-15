/**
 * End-to-end test for the "single active row in the sidebar" contract
 * (plan 2026-08-06-sidebar-single-active-state.md, Task 7).
 *
 * The sidebar derives its `active` styling from the URL (via
 * `useCurrentMainView`), not from store flags. Per the spec, the
 * documented mental model is:
 *
 *   URL ?view=workspace&itemId=X&pageId=Z
 *     → the workspace item + the design page row whose id === Z.
 *       BOTH rows get the active bg + accent bar — this forms a
 *       meaningful hierarchy breadcrumb (the user sees both "I'm in
 *       design" and "I'm on this page"). The expanded workspace
 *       header is NOT active (Task 6 dropped that). Net: 2 active
 *       rows in the sidebar.
 *
 *   URL ?view=chat&session=X
 *     → no workspace item or page is active. The chat row's
 *       highlight lives inside <ChatsList> and isn't a sidebar-row
 *       count in this contract. Net: 0 active rows in the sidebar's
 *       workspace tree.
 *
 *   URL ?view=workspace&itemId=Y (no pageId)
 *     → just the workspace item row (no page active). 1 active row.
 *
 * Pre-fix the sidebar would show 3 active rows simultaneously
 * (expanded workspace + active item + active page) — the user's
 * reported "sidebar active is confusing" symptom.
 *
 * Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 * Plan: docs/superpowers/plans/2026-08-06-sidebar-single-active-state.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// Stub vue-router per the canonical pattern (mirrors sidebarHandleSelectTaskUrl.spec.ts).
// `useRoute` returns a `reactive` shape so the composable's computed re-runs when we mutate the
// query mid-test.
const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

function makeStubClient(): SseClient {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting',
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    state: 'connecting',
    lastError: null,
  } as unknown as SseClient
}

const DESIGN_ITEM_ID = 'item_design'
const PAGE_42_ID = 'page_42'
const PAGE_99_ID = 'page_99'
const WS_ID = 'ws_1'

const baseWorkspace = {
  id: WS_ID,
  name: 'agentic coding',
  icon: 'folder',
  expanded: true,
  items: [
    {
      id: DESIGN_ITEM_ID,
      name: 'design',
      item_type: 'design',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

const baseDesignPages = [
  {
    id: PAGE_42_ID,
    name: 'Task Dialog',
    workspace_item_id: DESIGN_ITEM_ID,
    workspace_item_task_id: 'task_42',
    position: 0,
    created_at: '2026-01-01',
    updated_at: '2026-01-01',
    width: 1440,
    height: 1024,
  },
  {
    id: PAGE_99_ID,
    name: 'Other Page',
    workspace_item_id: DESIGN_ITEM_ID,
    workspace_item_task_id: 'task_99',
    position: 1,
    created_at: '2026-01-01',
    updated_at: '2026-01-01',
    width: 1440,
    height: 1024,
  },
]

function mountSidebar() {
  return mount(Sidebar, {
    global: {
      mocks: { $router: { replace: vi.fn(), push: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

// Count the rendered sidebar's active rows. The "active row" signal is the inline `style` attribute
// containing `--semantic-active-bg` — both the workspace item row and the design page row inject
// that CSS variable into the inline `style` when they are the URL-driven active row.
// Hover styles live in `class="hover:bg-[--semantic-active-bg]"` (Tailwind arbitrary value), NOT in
// the inline style, so we scope the regex to `style="..."` to avoid false positives.
function countActiveRows(html: string): number {
  const matches = html.match(/style="[^"]*--semantic-active-bg[^"]*"/g)
  return matches?.length ?? 0
}

describe('Sidebar — URL-driven single-active contract', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    // ChatsList (a child of Sidebar) calls `loadChats()` in onMounted,
    // which calls `api.getChats`. Stub it so the test doesn't try to
    // hit the network.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  /**    * Helper: pre-populate the workspaces store with the design-workspace fixture (1 design item with
   * 2 design pages). The store's `expandedItemIds` and `designPagesByItemId` caches must be set so
   * the design pages render (otherwise the `<DesignPageRow>` for `page_42` never mounts). */
  function seedWorkspaceFixture() {
    const ws = useWorkspacesStore()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [baseWorkspace as any]
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.designPagesByItemId = { [DESIGN_ITEM_ID]: baseDesignPages as any }
    ws.expandedItemIds = { [DESIGN_ITEM_ID]: true }
  }

  it('design page URL → 2 active rows (item + page), workspace header NOT active', async () => {
    // URL: viewing a design page. Both the item row AND the page row get the active bg + accent bar
    // (per the spec's documented mental model — meaningful hierarchy breadcrumb). The expanded
    // workspace header does NOT get the active bg.
    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ITEM_ID,
        pageId: PAGE_42_ID,
      },
      path: '/app',
      fullPath:
         
        `/app?view=workspace&workspaceId=${WS_ID}` +
        `&itemId=${DESIGN_ITEM_ID}&pageId=${PAGE_42_ID}`,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    seedWorkspaceFixture()

    const wrapper = mountSidebar()
    await nextTick()

    const html = wrapper.html()
    const activeRows = countActiveRows(html)

    // Lock in the documented mental model:
    //   workspace item row + the matching design page row.
    expect(activeRows).toBe(2)

    // Explicit assertion: the workspace header button is NOT active.
    // Without this assertion, a regression could silently bump the
    // header back to an active bg (pre-Task-6 behaviour).
    const buttons = wrapper.findAll('button')
    const wsHeaderButton = buttons.find((b) => b.text().includes('agentic coding'))
    expect(wsHeaderButton).toBeDefined()
    expect(wsHeaderButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    // The matching page row IS active (regression guard for the
    // page-id-driven contract from Task 5).
    const activePage = wrapper.find(`[data-page-id="${PAGE_42_ID}"]`)
    expect(activePage.exists()).toBe(true)
    expect(activePage.attributes('style')).toContain('--semantic-active-bg')
    expect(activePage.attributes('style')).toContain('--color-violet') // accent bar

    // The non-matching page row is NOT active.
    const otherPage = wrapper.find(`[data-page-id="${PAGE_99_ID}"]`)
    expect(otherPage.exists()).toBe(true)
    expect(otherPage.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('chat URL → 0 active rows in the sidebar tree', async () => {
    // URL: viewing a chat. No workspace item or page is the URL-driven active row. The chat row's
    // highlight lives inside <ChatsList> (separate from this count). Pre-fix the expanded workspace
    // header would still be active — this asserts it isn't.
    useRouteMock.mockReturnValue({
       
      query: { view: 'chat', session: 'session_xyz' },
      path: '/app',
      fullPath: '/app?view=chat&session=session_xyz',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    seedWorkspaceFixture()

    const wrapper = mountSidebar()
    await nextTick()

    const html = wrapper.html()
    const activeRows = countActiveRows(html)

    // Zero: nothing in the workspace tree is active when the URL
    // points at a chat. (The chat row's active bg is inside <ChatsList>,
    // which uses a different inline-style string — see below.)
    expect(activeRows).toBe(0)

    // Regression guard: the workspace header still has no active bg
    // even when the URL is chat (Task 6's contract).
    const buttons = wrapper.findAll('button')
    const wsHeaderButton = buttons.find((b) => b.text().includes('agentic coding'))
    expect(wsHeaderButton).toBeDefined()
    expect(wsHeaderButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    // The workspace item row is NOT active.
    const itemButton = buttons.find((b) => b.text().includes('design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    // The design page rows are NOT active.
    const activePage = wrapper.find(`[data-page-id="${PAGE_42_ID}"]`)
    expect(activePage.exists()).toBe(true)
    expect(activePage.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    const otherPage = wrapper.find(`[data-page-id="${PAGE_99_ID}"]`)
    expect(otherPage.exists()).toBe(true)
    expect(otherPage.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })
})