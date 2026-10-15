/**
 * Behavioural tests for DesignPageRow.vue.
 *
 * Plan: docs/superpowers/plans/2026-08-06-design-pages-in-workspace-tree.md
 *
 * 6 tests covering the row's behavioral contract:
 *  1. Renders the page name.
 *  2. Click emits `selectPage` with the page object.
 *  3. × button emits `deletePage` with the page object.
 *  4. × button click does NOT also emit `selectPage` (stopPropagation).
 *  5. Active page gets the violet active style; inactive doesn't.
 *  6. data-testid `design-page-row-${pageId}` is present.
 *
 * Active styling is driven by URL (?view=workspace&pageId=X) via the
 * `useCurrentMainView` composable (see sidebar-single-active-state plan).
 * Tests stub vue-router so the URL is controllable per test.
 */
import { describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import DesignPageRow from '../components/workspace/DesignPageRow.vue'
import type { DesignPage } from '../api'

// Stub vue-router — DesignPageRow reads useRoute() via useCurrentMainView() to drive its active
// state. Mirrors the pattern at sidebarHandleSelectTaskUrl.spec.ts:57-77. Default = empty route (no
// active state); tests that need the active styling override per-test.
const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function makePage(overrides: Partial<DesignPage> = {}): DesignPage {
  return {
    id: 'page_1',
    workspace_item_id: 'item_1',
    name: 'AI Chat View',
    workspace_item_task_id: 'task_1',
    width: 1440,
    height: 1024,
    position: 0,
    created_at: '2026-08-06 00:00:00',
    updated_at: '2026-08-06 00:00:00',
    ...overrides,
  }
}

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function mountRow(props: {
  page: DesignPage
  isActivePage: boolean
}) {
  return mount(DesignPageRow, {
    props: {
      page: props.page,
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      isActivePage: props.isActivePage,
    },
  })
}

describe('DesignPageRow.vue', () => {
  it('renders the page name', () => {
    const wrapper = mountRow({
      page: makePage({ name: 'AI Chat View' }),
      isActivePage: false,
    })
    expect(wrapper.text()).toContain('AI Chat View')
  })

  it('click on the row emits selectPage with the page object', async () => {
    const page = makePage({ id: 'page_abc', name: 'Kanban Mode' })
    const wrapper = mountRow({ page, isActivePage: false })
    await wrapper.find(`[data-testid="design-page-row-page_abc"]`).trigger('click')
    expect(wrapper.emitted('selectPage')).toBeTruthy()
    expect(wrapper.emitted('selectPage')![0]).toEqual([page])
  })

  it('click on the × button emits deletePage with the page object', async () => {
    const page = makePage({ id: 'page_xyz', name: 'Workspaces Sidebar' })
    const wrapper = mountRow({ page, isActivePage: false })
    await wrapper.find(`[data-testid="design-page-delete-page_xyz"]`).trigger('click')
    expect(wrapper.emitted('deletePage')).toBeTruthy()
    expect(wrapper.emitted('deletePage')![0]).toEqual([page])
  })

  it('click on × does NOT also emit selectPage (stopPropagation)', async () => {
    // Regression: the row's button would bubble the click up to the
    // outer <button>, firing selectPage right before deletePage —
    // bad UX (the user sees the page flash before the empty state).
    const wrapper = mountRow({
      page: makePage({ id: 'page_a' }),
      isActivePage: false,
    })
    await wrapper.find('[data-testid="design-page-delete-page_a"]').trigger('click')
    expect(wrapper.emitted('selectPage')).toBeFalsy()
    expect(wrapper.emitted('deletePage')).toBeTruthy()
  })

  it('active page gets the violet active style; inactive does not', () => {
    // Active state is now URL-driven (sidebar-single-active-state plan,
    // 2026-08-06). The `isActivePage` prop is kept for backwards compat
    // but the visual now sources from the URL.
    const page = makePage({ id: 'page_active' })
    // Mock URL with the matching pageId — page_1 is item_1's page in
    // the base fixture. The first mockReturnValueOnce is consumed by
    // the active mount, the second by the inactive mount (no match).
    useRouteMock
      .mockReturnValueOnce({
        query: { view: 'workspace', itemId: 'item_1', pageId: 'page_active' },
        path: '/app',
        fullPath: '/app?view=workspace&itemId=item_1&pageId=page_active',
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
      .mockReturnValueOnce({
        query: { view: 'workspace', itemId: 'item_1', pageId: 'page_other' },
        path: '/app',
         
        fullPath: '/app?view=workspace&itemId=item_1&pageId=page_other',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
    const active = mountRow({ page, isActivePage: true })
    const inactive = mountRow({ page, isActivePage: false })
    expect(active.find('[data-testid="design-page-row-page_active"]').attributes('style') ?? '')
      .toContain('var(--color-aqua)')
    expect(inactive.find('[data-testid="design-page-row-page_active"]').attributes('style') ?? '')
      .not.toContain('var(--color-aqua)')
    // The inactive row should expose a data-active-page attribute that
    // is undefined (Vue's `data-` binding with `undefined` value drops
    // the attribute entirely).
    expect(inactive.find('[data-testid="design-page-row-page_active"]').attributes('data-active-page'))
      .toBeUndefined()
  })

  it('exposes the data-testid design-page-row-${pageId} selector', () => {
    const wrapper = mountRow({
      page: makePage({ id: 'page_xxx' }),
      isActivePage: false,
    })
    expect(wrapper.find('[data-testid="design-page-row-page_xxx"]').exists()).toBe(true)
  })

  // ─── ⋮ menu (rename-design-pages, 2026-08-06) ────────────────────────── Verifies the three-dot
  // menu mounted alongside the existing × delete button. The menu is the canonical surface for
  // page-level actions (Rename + Delete); future actions (duplicate, lock, etc.) slot in here.
  it('renders a ⋮ menu trigger button on the row', () => {
    const wrapper = mountRow({
      page: makePage({ id: 'page_menu' }),
      isActivePage: false,
    })
    expect(wrapper.find('[data-testid="design-page-menu-page_menu"]').exists()).toBe(true)
  })

  it('does NOT render the menu dropdown by default (closed)', () => {
    const wrapper = mountRow({
      page: makePage({ id: 'page_closed' }),
      isActivePage: false,
    })
    expect(wrapper.find('[data-testid="design-page-menu-list-page_closed"]').exists()).toBe(false)
  })

  it('clicking the ⋮ trigger opens the menu dropdown', async () => {
    const wrapper = mountRow({
      page: makePage({ id: 'page_open' }),
      isActivePage: false,
    })
    await wrapper.find('[data-testid="design-page-menu-page_open"]').trigger('click')
    expect(wrapper.find('[data-testid="design-page-menu-list-page_open"]').exists()).toBe(true)
    // The dropdown items should be present.
    expect(wrapper.find('[data-testid="design-page-menu-rename-page_open"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="design-page-menu-delete-page_open"]').exists()).toBe(true)
  })

  it('clicking the ⋮ trigger does NOT emit selectPage (stopPropagation)', async () => {
    // Regression: without @click.stop on the menu trigger, the outer row's click handler would also
    // fire when the menu is opened, causing the user to navigate to the page right before the menu
    // appears.
    const wrapper = mountRow({
      page: makePage({ id: 'page_noop' }),
      isActivePage: false,
    })
    await wrapper.find('[data-testid="design-page-menu-page_noop"]').trigger('click')
    expect(wrapper.emitted('selectPage')).toBeFalsy()
  })

  it('clicking "Rename" in the menu emits renamePage with the page object', async () => {
    const page = makePage({ id: 'page_ren', name: 'AI Chat View' })
    const wrapper = mountRow({ page, isActivePage: false })
    await wrapper.find('[data-testid="design-page-menu-page_ren"]').trigger('click')
    await wrapper.find('[data-testid="design-page-menu-rename-page_ren"]').trigger('click')
    expect(wrapper.emitted('renamePage')).toBeTruthy()
    expect(wrapper.emitted('renamePage')![0]).toEqual([page])
  })

  it('clicking "Delete" in the menu emits deletePage with the page object', async () => {
    const page = makePage({ id: 'page_menudel', name: 'Workspaces Sidebar' })
    const wrapper = mountRow({ page, isActivePage: false })
    await wrapper.find('[data-testid="design-page-menu-page_menudel"]').trigger('click')
    await wrapper.find('[data-testid="design-page-menu-delete-page_menudel"]').trigger('click')
    expect(wrapper.emitted('deletePage')).toBeTruthy()
    expect(wrapper.emitted('deletePage')![0]).toEqual([page])
  })

  it('clicking the ⋮ trigger does NOT emit renamePage or deletePage (menu opens, item click emits)', async () => {
    // The menu trigger ITSELF should not fire any row actions — only
    // the menu items do.
    const wrapper = mountRow({
      page: makePage({ id: 'page_only_menu' }),
      isActivePage: false,
    })
    await wrapper.find('[data-testid="design-page-menu-page_only_menu"]').trigger('click')
    expect(wrapper.emitted('renamePage')).toBeFalsy()
    expect(wrapper.emitted('deletePage')).toBeFalsy()
  })
})
