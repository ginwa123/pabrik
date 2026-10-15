/** Tests for KanbanSettingsView — the dedicated full-page route for per-board kanban settings.
 * Replaces KanbanSettingsDialog (the centered modal that used to pop up when the user clicked ⚙ on
 * a kanban board header). URL: /app/kanban/:itemId/settings (path-based vue-router route). */

/** The page reads itemId from route.params and derives workspaceId from the store by walking
 * workspaces. Mount pattern: same as KanbanSettingsDialog.spec.ts. */

/** The KanbanColumnEditor child uses <Teleport to="body">, so the rendered DOM lives outside
 * wrapper.element when the rename/delete editor is open. */

/** We use `attachTo: document.body` and query the teleported content via `document.querySelector` /
 * `document.querySelectorAll` (NOT `wrapper.find`). `wrapper.emitted` still works because it tracks
 * the vm, not the DOM tree. */

/** Plan: docs/superpowers/plans/2026-09-02-kanban-settings-as-page.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { reactive } from 'vue'

import KanbanSettingsView from '@/components/views/KanbanSettingsView.vue'
import { useWorkspacesStore, type WorkspaceItem } from '@/stores/workspaces'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: useRouteMock,
    useRouter: useRouterMock,
  }
})

const baseItem: WorkspaceItem = {
  id: 'wi_test',
  name: 'Sprint 12',
  item_type: 'kanban',
  path: null,
  kanban_columns: [
    {
      id: 'col_a',
      workspace_item_id: 'wi_test',
      name: 'todo',
      description: 'Not started',
      position: 0,
      created_at: '2026-06-26T10:00:00Z',
    },
    {
      id: 'col_b',
      workspace_item_id: 'wi_test',
      name: 'done',
      description: '',
      position: 1,
      created_at: '2026-06-26T10:00:00Z',
    },
  ],
}

function setupRoute(
  query: Record<string, string>,
  path = '/app/kanban/wi_test/settings',
  params: Record<string, string> = { itemId: 'wi_test' },
) {
  const obj = reactive({ query, path, params, fullPath: path })
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouteMock.mockReturnValue(obj as any)
  // Mocked router methods apply their `query` argument to the reactive
  // route object (mirrors what a real router does) so URL-backed
  // computed refs in the page re-evaluate after `router.replace`.
  const apply = (target: { query?: Record<string, string> }) => {
    if (target.query) {
      // Reactive replacement — triggers computed re-eval.
      Object.keys(obj.query).forEach((k) => delete obj.query[k])
      Object.assign(obj.query, target.query)
    }
  }
  const push = vi.fn((target: { query?: Record<string, string> }) => apply(target))
  const replace = vi.fn((target: { query?: Record<string, string> }) => apply(target))
  const back = vi.fn()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouterMock.mockReturnValue({ push, replace, back, currentRoute: obj } as any)
  return { route: obj, router: { push, replace, back } }
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function setInputValue(selector: string, value: string) {
  const el = findInDom<HTMLInputElement | HTMLTextAreaElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

/** Seed the workspacesStore with a workspace that contains the given
 * kanban item. Returns the store so tests can inspect/assert. */
function seedWorkspaces(item: WorkspaceItem | null = baseItem) {
  const store = useWorkspacesStore()
  // Force-create the workspace + items arrays; we don't need the full
  // initializeFromSystemFolder fetch since the page only reads
  // workspaces[].items[].
  store.workspaces = [
    {
      id: 'ws_1',
      name: 'Test Workspace',
      icon: '📁',
      items: item ? [item] : [],
      expanded: true,
    },
  ]
  // activeWorkspaceItemId is set via setActiveWorkspaceItem so the
  // computed works as expected.
  if (item) {
    store.setActiveWorkspaceItem(item.id)
  }
  return store
}

describe('KanbanSettingsView', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    setupRoute({})
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  function mountView() {
    document.body.innerHTML = ''
    wrapper = mount(KanbanSettingsView, {
      attachTo: document.body,
      global: {
        stubs: {
          // Stub the memories view — it's heavy (renders a full
          // memories panel) and we only test its presence/absence.
          WorkspaceItemMemoriesView: { template: '<div data-testid="stub-memories"></div>' },
          // Stub AgentView — it renders the full Knowledge + Tools + System Prompt
          // UI (reused from `item_type='agent'`). We only assert its
          // presence/absence here; AgentView's own spec covers behaviour.
          AgentView: {
            template:
              '<div data-testid="kanban-settings-page-agent-panel-stub"><slot name="right-extra" /></div>',
            props: ['item', 'workspaceId', 'itemId', 'knowledge', 'tools', 'systemPrompts'],
          },
          // Stub KanbanColumnEditor to avoid the Teleport + nested dialog complexity in the
          // rename/delete tests.

          // Mirrors the real editor's `kanban-column-editor-<mode>-submit` data-testid so the
          // 2-step delete test can confirm via the submit button (same shape as the original
          // KanbanSettingsDialog test at line 180).
          KanbanColumnEditor: {
            template:
              '<div v-if="show" :data-testid="`kanban-column-editor-${mode}`">' +
              '<button v-if="mode===\'delete\'" :data-testid="`kanban-column-editor-${mode}-submit`" @click="$emit(\'delete\')">Delete</button>' +
              '</div>',
            props: ['show', 'mode', 'initialName', 'initialDescription'],
          },
        },
      },
    })
    return wrapper
  }

  it('renders the kanban name in the header', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const page = findInDom<HTMLElement>('[data-testid="kanban-settings-page"]')
    expect(page).not.toBeNull()
    expect(page?.textContent).toContain('Sprint 12')
  })

  it('renders one row per column sorted by position', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const rows = findAllInDom<HTMLElement>('[data-testid^="kanban-settings-page-column-row-"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]!.getAttribute('data-testid')).toBe('kanban-settings-page-column-row-col_a')
    expect(rows[1]!.getAttribute('data-testid')).toBe('kanban-settings-page-column-row-col_b')
  })

  it('adds a column via the inline form', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    setInputValue('[data-testid="kanban-settings-page-add-name"]', 'Review')
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-add-submit"]')
    expect(wrapper!.emitted('addColumn')).toEqual([['Review', '']])
  })

  it('deletes a column via the per-row Delete button (opens editor, then confirms)', async () => {
    // The per-row Delete button opens the editor in delete mode (mirrors KanbanSettingsDialog's
    // 2-step flow). The editor's Delete submit is what fires `deleteColumn`. Mirrors the original
    // KanbanSettingsDialog test at line 166.
    seedWorkspaces()
    mountView()
    await flushPromises()
    // 1. Click the per-row Delete button on col_a.
    clickInDom('[data-testid="kanban-settings-page-delete-col_a"]')
    await flushPromises()
    // 2. Click the editor's Delete submit to confirm.
    clickInDom('[data-testid="kanban-column-editor-delete-submit"]')
    expect(wrapper!.emitted('deleteColumn')).toEqual([['col_a']])
  })

  it('renames the kanban via the inline pencil', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const renameDisplay = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-rename-display"]',
    )
    expect(renameDisplay).not.toBeNull()
    renameDisplay!.click()
    await flushPromises()
    setInputValue('[data-testid="kanban-settings-page-rename-input"]', 'Sprint 13')
    clickInDom('[data-testid="kanban-settings-page-rename-save"]')
    expect(wrapper!.emitted('renameItem')).toEqual([['Sprint 13']])
  })

  it('copies spec via the footer button', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-copy-spec"]')
    expect(wrapper!.emitted('copySpec')).toBeDefined()
  })

  it('navigates back to the kanban board on the Back button (workspaceId derived from store)', async () => {
    seedWorkspaces()
    const { router } = setupRoute({})
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-back"]')
    // Canonical path shape (not the legacy `/app?view=workspace` one) so the
    // board's sub-state survives the boot rewrite.
    expect(router.replace).toHaveBeenCalledWith({
      path: '/app/ws_1/projects/wi_test',
      query: {},
    })
  })

  it('Back preserves the board sub-state (?sorts=, ?layout=) instead of resetting it', async () => {
    seedWorkspaces()
    const { router } = setupRoute({ sorts: 'col_1:name:asc', layout: 'rows' })
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-back"]')
    expect(router.replace).toHaveBeenCalledWith({
      path: '/app/ws_1/projects/wi_test',
      query: { sorts: 'col_1:name:asc', layout: 'rows' },
    })
  })

  it('Back does not leak the settings page own params onto the board', async () => {
    seedWorkspaces()
    const { router } = setupRoute({ tab: 'tools', section: 'agent', layout: 'rows' })
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-back"]')
    expect(router.replace).toHaveBeenCalledWith({
      path: '/app/ws_1/projects/wi_test',
      query: { layout: 'rows' },
    })
  })

  it('does NOT render a standalone Local Memories tab (now inside Agent tab)', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    mountView()
    await flushPromises()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-memories"]')).toBeNull()
  })

  it('does NOT render a standalone Local Memories tab even when kanban has no path', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    mountView()
    await flushPromises()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-memories"]')).toBeNull()
  })

  it('only renders two tabs: Columns and Agent', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    mountView()
    await flushPromises()
    const tabs = findAllInDom<HTMLElement>('[data-testid^="kanban-settings-page-tab-"]')
    const tabIds = tabs.map((t) => t.getAttribute('data-testid')).sort()
    expect(tabIds).toEqual(['kanban-settings-page-tab-agent', 'kanban-settings-page-tab-columns'])
  })

  it('shows a "no kanban selected" hint when the URL itemId is empty', async () => {
    setupRoute({}, '/app/kanban//settings', { itemId: '' })
    seedWorkspaces()
    mountView()
    await flushPromises()
    const hint = findInDom<HTMLElement>('[data-testid="kanban-settings-page-no-item"]')
    expect(hint).not.toBeNull()
  })

  it('falls back to a "not found" hint if itemId is missing from the store', async () => {
    setupRoute({}, '/app/kanban/wi_missing/settings', { itemId: 'wi_missing' })
    seedWorkspaces() // store has wi_test, NOT wi_missing
    mountView()
    await flushPromises()
    const hint = findInDom<HTMLElement>('[data-testid="kanban-settings-page-not-found"]')
    expect(hint).not.toBeNull()
  })

  // ─── Agent tab (reuses AgentView — unified Knowledge + Tools + System Prompt) ───

  it('renders the Agent tab button (visible regardless of item.path)', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    mountView()
    await flushPromises()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-agent"]')).not.toBeNull()
  })

  it('does NOT render separate Tools / Knowledge tabs (regression — unified into Agent)', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-tools"]')).toBeNull()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-knowledge"]')).toBeNull()
  })

  it('mounts AgentView as the active body when ?section=agent is in the URL', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ section: 'agent' })
    mountView()
    await flushPromises()
    const tab = findInDom<HTMLElement>('[data-testid="kanban-settings-page-tab-agent"]')
    expect(tab).not.toBeNull()
    const panel = findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')
    expect(panel).not.toBeNull()
    // Columns body should NOT be rendered.
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-column-list"]')).toBeNull()
  })

  it('mounts AgentView for legacy ?tab=agent (backward compat, pre tab-mode)', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ tab: 'agent' })
    mountView()
    await flushPromises()
    const panel = findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')
    expect(panel).not.toBeNull()
    // Columns body should NOT be rendered.
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-column-list"]')).toBeNull()
  })

  it('also mounts AgentView for legacy ?tab=tools (backward compat)', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ tab: 'tools' })
    mountView()
    await flushPromises()
    const panel = findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')
    expect(panel).not.toBeNull()
  })

  it('also mounts AgentView for legacy ?tab=knowledge (backward compat)', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ tab: 'knowledge' })
    mountView()
    await flushPromises()
    const panel = findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')
    expect(panel).not.toBeNull()
  })

  it('also mounts AgentView for legacy ?tab=memories (backward compat — now inside Agent)', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    setupRoute({ tab: 'memories' })
    mountView()
    await flushPromises()
    const panel = findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')
    expect(panel).not.toBeNull()
    // Columns body should NOT be rendered.
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-column-list"]')).toBeNull()
  })

  it('calls router.replace with {query:{section:"agent"}} when the Agent tab is clicked', async () => {
    seedWorkspaces()
    const { router } = setupRoute({})
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-tab-agent"]')
    expect(router.replace).toHaveBeenCalledWith(
      expect.objectContaining({ query: expect.objectContaining({ section: 'agent' }) }),
    )
  })

  it('preserves the browser tab ID (?tab=tab_xxx) when the Agent tab is clicked', async () => {
    // Regression: browser-style tab mode owns `?tab=<tabId>`. Clicking
    // Agent must write `?section=agent` alongside it, never clobber it.
    seedWorkspaces()
    const { router } = setupRoute({ tab: 'tab_mu0lle6j940yz' })
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-tab-agent"]')
    expect(router.replace).toHaveBeenCalledWith(
      expect.objectContaining({
        query: expect.objectContaining({ section: 'agent', tab: 'tab_mu0lle6j940yz' }),
      }),
    )
  })

  it('stays on columns when ?tab= holds a browser tab ID (tab-mode coexistence)', async () => {
    // The exact URL from the bug report: /app/kanban/<id>/settings?tab=tab_mu0lle6j940yz — the
    // settings getter must ignore the browser ID (fall back to columns) rather than crash or
    // misroute.
    seedWorkspaces()
    setupRoute({ tab: 'tab_mu0lle6j940yz' })
    mountView()
    await flushPromises()
    const columnsList = findInDom<HTMLElement>('[data-testid="kanban-settings-page-column-list"]')
    expect(columnsList).not.toBeNull()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]')).toBeNull()
  })

  it('prefers ?section= over legacy ?tab= when both are present', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ section: 'agent', tab: 'tab_mu0lle6j940yz' })
    mountView()
    await flushPromises()
    expect(
      findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-panel"]'),
    ).not.toBeNull()
  })

  it('falls back to columns when ?tab= has an unknown value', async () => {
    seedWorkspaces()
    setupRoute({ tab: 'totally-bogus' })
    mountView()
    await flushPromises()
    const columnsList = findInDom<HTMLElement>('[data-testid="kanban-settings-page-column-list"]')
    expect(columnsList).not.toBeNull()
  })

  // ─── Agent tab — embedded Local Memories section ───

  it('renders Local Memories inside Agent tab when kanban has a path', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    setupRoute({ section: 'agent' })
    mountView()
    await flushPromises()
    const memoriesSection = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-agent-memories"]',
    )
    expect(memoriesSection).not.toBeNull()
    const stubMemories = findInDom<HTMLElement>('[data-testid="stub-memories"]')
    expect(stubMemories).not.toBeNull()
  })

  it('shows no-path hint inside Agent tab when kanban has no path', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    setupRoute({ section: 'agent' })
    mountView()
    await flushPromises()
    const noPath = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-agent-memories-no-path"]',
    )
    expect(noPath).not.toBeNull()
    expect(noPath?.textContent).toContain('No directory is set')
    // Memories view should NOT be rendered.
    expect(findInDom<HTMLElement>('[data-testid="stub-memories"]')).toBeNull()
  })

  it('does NOT render Local Memories section when Agent tab is not active', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    setupRoute({}) // default = columns
    mountView()
    await flushPromises()
    expect(findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-memories"]')).toBeNull()
    expect(
      findInDom<HTMLElement>('[data-testid="kanban-settings-page-agent-memories-no-path"]'),
    ).toBeNull()
    expect(findInDom<HTMLElement>('[data-testid="stub-memories"]')).toBeNull()
  })

  it('renders the memories section wrapper inside Agent panel', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    setupRoute({ section: 'agent' })
    mountView()
    await flushPromises()
    const section = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-agent-memories-section"]',
    )
    expect(section).not.toBeNull()
  })
})
