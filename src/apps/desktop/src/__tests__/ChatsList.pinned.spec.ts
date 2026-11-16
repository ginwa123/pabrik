import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { useSidebarStore } from '../stores/sidebar'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const { useRouterMock } = vi.hoisted(() => ({
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolve: (target: any) => ({
      href: `/app?view=${target.query.view}&session=${target.query.session}`,
    }),
  })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting',
    onStateChange: () => () => {},
  }
}

describe('ChatsList — PINNED section (Migration 104)', () => {
  let app: VueApp
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'pinned_1',
          session_name: 'Pinned one',
          updated_at: '2026-06-18T10:00:00Z',
          is_pinned: true,
          pinned_position: 1,
        },
        {
          session_id: 'pinned_2',
          session_name: 'Pinned two',
          updated_at: '2026-06-18T09:00:00Z',
          is_pinned: true,
          pinned_position: 0,
        },
        {
          session_id: 'chat_1',
          session_name: 'Hello',
          updated_at: '2026-06-18T10:00:00Z',
          is_pinned: false,
          pinned_position: 0,
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 3,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  it('renders PINNED above RECENT with pinned rows sorted by position DESC', async () => {
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    const pinned = document.body.querySelector('[data-testid="pinned-section"]')
    expect(pinned).toBeTruthy()
    // Layout contract: Pinned, Recent, Projects — the PINNED section must precede the RECENT header in DOM order.
    const recentTitle = document.body.querySelector('[data-testid="recent-section-title"]')
    expect(recentTitle).toBeTruthy()
    expect(
      pinned!.compareDocumentPosition(recentTitle!) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
    expect(
      document.body.querySelector('[data-testid="pinned-section-title"]')?.textContent,
    ).toContain('Pinned')
    const rows = Array.from(pinned!.querySelectorAll('[data-testid^="chat-row-"]')).map((el) =>
      el.getAttribute('data-testid'),
    )
    expect(rows).toEqual(['chat-row-pinned_1', 'chat-row-pinned_2'])
    const recentRows = wrapper.findAll('[data-testid^="chat-row-"]')
    const ids = recentRows.map((b) => b.attributes('data-testid'))
    expect(ids.filter((id) => id === 'chat-row-pinned_1').length).toBe(1)
    expect(ids.filter((id) => id === 'chat-row-pinned_2').length).toBe(1)
    wrapper.unmount()
  })

  it('hides the PINNED section when nothing is pinned', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        { session_id: 'chat_1', session_name: 'Hello', updated_at: '2026-06-18T10:00:00Z' },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    expect(document.body.querySelector('[data-testid="pinned-section"]')).toBeNull()
    wrapper.unmount()
  })

  it('right-click menu offers Pin and calls api.pinSession', async () => {
    const pinSession = vi.spyOn(api, 'pinSession').mockResolvedValue({
      success: true,
      id: 'chat_1',
      is_pinned: true,
      pinned_position: 5,
    })
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const row = wrapper.findAll('button').find((b) => b.text().includes('Hello'))
    await row!.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const pinItem = document.body.querySelector(
      '[data-testid="chat-context-menu-pin"]',
    ) as HTMLButtonElement
    expect(pinItem?.textContent).toContain('Pin to top')
    pinItem.click()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    expect(pinSession).toHaveBeenCalledWith('chat_1', true)
    expect(document.body.querySelector('[data-testid="pinned-section"]')).toBeTruthy()
    pinSession.mockRestore()
    wrapper.unmount()
  })

  it('unpin label reflects server truth for a pinned row', async () => {
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const pinned = document.body.querySelector('[data-testid="pinned-section"]')!
    const row = Array.from(pinned.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Pinned one'),
    ) as HTMLButtonElement
    const ev = new MouseEvent('contextmenu', { bubbles: true, clientX: 100, clientY: 200 })
    row.dispatchEvent(ev)
    await nextTick()
    const pinItem = document.body.querySelector('[data-testid="chat-context-menu-pin"]')
    expect(pinItem?.textContent).toContain('Unpin from top')
    expect(pinItem?.getAttribute('aria-checked')).toBe('true')
    wrapper.unmount()
  })

  it('collapsing RECENT keeps PINNED visible (independent flags)', async () => {
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const sidebarStore = useSidebarStore()
    expect(sidebarStore.navExpanded).toBe(true)
    expect(sidebarStore.pinnedExpanded).toBe(true)
    // Collapse RECENT — the reported bug hid PINNED here.
    sidebarStore.toggleNavExpanded()
    await nextTick()
    expect(sidebarStore.navExpanded).toBe(false)
    const pinned = document.body.querySelector('[data-testid="pinned-section"]')
    expect(pinned).toBeTruthy()
    expect(pinned!.querySelector('[data-testid="chat-row-pinned_1"]')).toBeTruthy()
    wrapper.unmount()
  })

  it('collapsing PINNED hides only pinned rows, RECENT stays', async () => {
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const sidebarStore = useSidebarStore()
    sidebarStore.togglePinnedExpanded()
    await nextTick()
    expect(sidebarStore.pinnedExpanded).toBe(false)
    // Section shell stays (header + count) so the user can re-expand, but the pinned rows unmount.
    expect(document.body.querySelector('[data-testid="pinned-section"]')).toBeTruthy()
    expect(document.body.querySelector('[data-testid="chat-row-pinned_1"]')).toBeNull()
    // RECENT is untouched.
    expect(document.body.querySelector('[data-testid="recent-section-title"]')).toBeTruthy()
    expect(localStorage.getItem('pabrik-sidebar-pinned-expanded')).toBe('false')
    wrapper.unmount()
  })
})
