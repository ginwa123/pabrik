import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
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

describe('ChatsList — right-click context menu', () => {
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
        { session_id: 'chat_1', session_name: 'Hello', updated_at: '2026-06-18T10:00:00Z' },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  it('right-click opens the chat action menu, "Open chat in new tab" opens a real browser tab', async () => {
    const openSpy = vi.spyOn(window, 'open').mockReturnValue(null)
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const row = wrapper.findAll('button').find((b) => b.text().includes('Hello'))
    expect(row).toBeTruthy()
    await row!.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const menu = document.body.querySelector('[data-testid="chat-context-menu"]')
    expect(menu).toBeTruthy()
    const item = document.body.querySelector(
      '[data-testid="chat-context-menu-open-tab"]',
    ) as HTMLButtonElement
    expect(item?.textContent).toContain('Open chat in new tab')
    expect(item?.querySelector('span[aria-hidden="true"]')).toBeTruthy()
    item.click()
    await nextTick()
    expect(openSpy).toHaveBeenCalledExactlyOnceWith(
      expect.stringContaining('session=chat_1'),
      '_blank',
      'noopener',
    )
    expect(document.body.querySelector('[data-testid="chat-context-menu"]')).toBeNull()
    wrapper.unmount()
    openSpy.mockRestore()
  })

  it('title bar names the right-clicked row, and Stop agent is hidden while idle', async () => {
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

    expect(
      document.body.querySelector('[data-testid="chat-context-menu-title"]')?.textContent?.trim(),
    ).toBe('Hello')
    // Idle chat → nothing to stop. Asserting the absence matters: the
    // "Stop agent" row firing on an idle chat would POST a stop for a
    // run that never existed.
    expect(document.body.querySelector('[data-testid="chat-context-menu-stop"]')).toBeNull()
    wrapper.unmount()
  })

  it('Stop agent appears only while the row is processing', async () => {
    const processingState = ref<Record<string, boolean>>({ chat_1: true })
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const row = wrapper.findAll('button').find((b) => b.text().includes('Hello'))
    await row!.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()

    const stop = document.body.querySelector('[data-testid="chat-context-menu-stop"]')
    expect(stop?.textContent).toContain('Stop agent')
    wrapper.unmount()
  })

  it('unattended label reflects server truth for the row', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'chat_1',
          session_name: 'Hello',
          updated_at: '2026-06-18T10:00:00Z',
          is_auto_retry_until_stop: '1',
        },
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
    const row = wrapper.findAll('button').find((b) => b.text().includes('Hello'))
    await row!.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()

    // The label states the ACTION, not the state — a static "Unattended
    // mode" row leaves the user guessing whether picking it turns the
    // flag on or off.
    const unattended = document.body.querySelector('[data-testid="chat-context-menu-unattended"]')
    expect(unattended?.textContent).toContain('Turn off unattended mode')
    expect(unattended?.getAttribute('aria-checked')).toBe('true')
    wrapper.unmount()
  })

  it('Rename calls updateTaskSimple — NOT updateSession, which would clear the model profile', async () => {
    const updateTaskSimple = vi.spyOn(api, 'updateTaskSimple').mockResolvedValue({ success: true })
    const updateSession = vi.spyOn(api, 'updateSession').mockResolvedValue({
      id: 'chat_1',
      name: 'Renamed',
      status: 'active',
      selected_profile_model: '',
      is_auto_retry_until_stop: '0',
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

    document.body
      .querySelector<HTMLButtonElement>('[data-testid="chat-context-menu-rename"]')!
      .click()
    await nextTick()
    // RenameTaskModal teleports to <body>, so it is reached through the
    // document rather than the ChatsList wrapper. Drive its input the
    // way a user would rather than reaching past the component boundary.
    const input = document.body.querySelector<HTMLInputElement>(
      '[data-testid="rename-modal-input"]',
    )!
    expect(input).toBeTruthy()
    expect(
      document.body.querySelector('[data-testid="rename-modal-heading"]')?.textContent?.trim(),
    ).toBe('Rename chat')
    input.value = 'Renamed'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    document.body.querySelector<HTMLButtonElement>('[data-testid="rename-modal-save"]')!.click()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()

    // task.id == session_id (Migration 052), so the id-only task PUT is
    // the rename path that cascades to sessions.name WITHOUT also
    // clearing selected_profile_model.
    expect(updateTaskSimple).toHaveBeenCalledWith('chat_1', { name: 'Renamed' })
    expect(updateSession).not.toHaveBeenCalled()
    updateTaskSimple.mockRestore()
    updateSession.mockRestore()
    wrapper.unmount()
  })

  it('unattended toggle passes selectedAgent back so it is not cleared', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'chat_1',
          session_name: 'Hello',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: 'codex-high',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const updateSession = vi.spyOn(api, 'updateSession').mockResolvedValue({
      id: 'chat_1',
      name: 'Hello',
      status: 'active',
      selected_profile_model: 'codex-high',
      is_auto_retry_until_stop: '1',
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

    document.body
      .querySelector<HTMLButtonElement>('[data-testid="chat-context-menu-unattended"]')!
      .click()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()

    // The landmine: api.updateSession always PUTs selected_profile_model,
    // and the server treats '' as CLEAR. Omitting it here would silently
    // reset this chat back to the default profile.
    expect(updateSession).toHaveBeenCalledWith('chat_1', {
      isAutoRetryUntilStop: '1',
      selectedAgent: 'codex-high',
    })
    updateSession.mockRestore()
    wrapper.unmount()
  })
})
