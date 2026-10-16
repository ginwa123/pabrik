/** Chat surface stacking containment — structural contract. The document viewer is now its own PAGE
 * (`/app/<ws>/doc/<id>`) and REPLACES the chat, so it no longer needs this containment — that was
 * the follow-up fix. */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const __dir = dirname(fileURLToPath(import.meta.url))
const chatViewSrc = readFileSync(resolve(__dir, '../components/views/ChatView.vue'), 'utf8')
const appLayoutSrc = readFileSync(resolve(__dir, '../components/AppLayout.vue'), 'utf8')

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

/** The chat chrome tiers that must never out-paint an app-level overlay. */
const CHROME_Z_TIERS = [
  { name: 'chat scroll slider', source: 'components/chat/ChatScrollSlider.vue', z: 20 },
  { name: 'user pill rail', source: 'components/chat/UserPillRail.vue', z: 20 },
  { name: 'composer dock', source: 'ChatView.vue', z: 30 },
  { name: 'scroll-to-bottom arrow', source: 'ChatView.vue', z: 31 },
]

function readSource(rel: string): string {
  return readFileSync(resolve(__dir, '../', rel), 'utf8')
}

/** `isolation: isolate` for `.chat-column`, wherever the fix was applied. */
function chatColumnIsolation(): string | null {
  const rule = chatViewSrc.match(/\.chat-column\s*\{[^}]*\}/)
  if (!rule) return null
  const m = rule[0].match(/isolation:\s*([a-z-]+)\s*;/)
  return m ? m[1]! : null
}

let wrapper: VueWrapper | null = null

async function mountChat() {
  wrapper = mount(ChatView, {
    props: { chatId: 'chat-1', chatName: 'session', cwd: '/tmp' },
    global: { stubs: { Teleport: true } },
  })
  await flushPromises()
}

describe('ChatView stacking containment — document overlay must cover the chat', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    const storage = makeLocalStorageStub()
    vi.stubGlobal('localStorage', storage)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({}) }))

    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [
        { role: 'user', content: 'first question' },
        { role: 'assistant', content: 'first answer' },
        { role: 'user', content: 'second question' },
        { role: 'assistant', content: 'second answer' },
      ].map((m, i) => ({
        id: `m${i}`,
        session_id: 's_stack',
        content: m.content,
        role: m.role,
        created_at: 1_700_000_000 + i,
      })),
      has_more: false,
      next_cursor: null,
      cwd: '/tmp',
      git_worktree_cwd: '',
      max_total_tokens: 0,
      max_capacity_total_tokens: 0,
    } as never)
    vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
    vi.spyOn(api, 'getSession').mockResolvedValue({
      session_id: 's_stack',
      session_name: '',
      selectedProfile: null,
      cwd: '/tmp',
      git_worktree_cwd: '',
    } as never)
    vi.spyOn(api, 'getGitStatus').mockResolvedValue({ is_git_repo: false } as never)
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as never)

    const sse = {
      close: vi.fn(),
      reconnect: vi.fn(),
      getState: (): SseState => 'connecting',
      onStateChange: () => () => {},
    } as unknown as SseClient
    // `installSseBus` takes an optional Vue app; the client is installed
    // separately via `__setSseBusGlobalClient`.
    installSseBus()
    __setSseBusGlobalClient(sse)
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('the chat column carries the class the isolation rule targets', async () => {
    await mountChat()

    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    expect(column).toBeTruthy()

    // `position: relative` alone is NOT enough — with z-index auto it does not create a stacking
    // context, which is precisely why the chat chrome used to paint over the document overlay. The
    // `relative` class is here because the composer dock anchors to this column.
    expect(column.classList.contains('relative')).toBe(true)

    // The scoped rule in the SFC is what actually opens the stacking
    // context. jsdom does NOT apply SFC <style> blocks to the mounted
    // tree, so `getComputedStyle` here would read the empty default
    // (`isolation: ''`) on the buggy source AND on the fixed one — a
    // green test that proves nothing. The declaration is therefore
    // pinned against the source in the next test, and the resulting
    // paint order is asserted in a real browser (see the header note).
  })

  it('the isolation is declared in the stylesheet, not only in a test-visible class', () => {
    // Guards against the class being dropped from the class attribute while the declaration is what
    // actually does the work, and vice versa: the runtime check above needs the rule to EXIST, and
    // the rule needs the element to CARRY it. Pin both ends.
    expect(chatColumnIsolation()).toBe('isolate')
  })

  it('every chat chrome tier outranks the remaining app overlays without the containment', () => {
    // The isolation above is what makes this ordering irrelevant to the result — but these ARE the
    // numbers that regressed the bug, so keep them visible. If someone drops `isolation`, this is
    // exactly the comparison that lets the chat win.
    const overlayZ = Number(appLayoutSrc.match(/z-index:\s*(\d+)/)?.[1])
    const tierZ = CHROME_Z_TIERS.map((t) => t.z)
    expect({ overlayZ, tierZ, allChatTiersWin: tierZ.every((z) => z > overlayZ) }).toEqual({
      overlayZ: 10,
      tierZ: [20, 20, 30, 31],
      allChatTiersWin: true,
    })
  })

  it('the chrome element named in the bug report is inside the chat column', async () => {
    // Locks the blast radius to the composer dock — the element the screenshot showed sitting on
    // top of the document. If a future refactor moves it OUT of the column it stops being
    // contained, and the isolation stops covering it, so this must stay true for the fix to hold.
    await mountChat()

    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    const dock = column.querySelector('.composer-dock')
    expect(dock).not.toBeNull()
    expect(column.contains(dock)).toBe(true)
  })
})

describe('ChatView stacking containment — source contract', () => {
  it('ChatScrollSlider and UserPillRail keep their z-index at 20', () => {
    const slider = readSource('components/chat/ChatScrollSlider.vue')
    const rail = readSource('components/chat/UserPillRail.vue')
    expect([slider.match(/z-index:\s*(\d+)/)?.[1], rail.match(/z-index:\s*(\d+)/)?.[1]]).toEqual([
      '20',
      '20',
    ])
  })

  it('the composer dock and scroll-to-bottom arrow keep their z-index ladder', () => {
    const dock = chatViewSrc.match(/\.composer-dock\s*\{[^}]*\}/)?.[0]
    expect(dock).toBeTruthy()
    expect(dock).toMatch(/z-index:\s*30;/)

    const arrow = chatViewSrc.match(/\.chat-scroll-to-bottom\s*\{[^}]*\}/)?.[0]
    expect(arrow).toBeTruthy()
    expect(arrow).toMatch(/z-index:\s*31;/)
  })
})
