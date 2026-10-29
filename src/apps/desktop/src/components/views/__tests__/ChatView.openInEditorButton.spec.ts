/** The center-diff ⤴ "Open file in code browser" button — BEHAVIOURAL. THE BUG (user report:
 * "button open code editor not work"). Clicking the ⤴ button in a stacked center-diff file header
 * did nothing. ROOT CAUSE. */
import { afterEach, beforeEach, describe, expect, it, vi, type Mock } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createApp, defineComponent, h, nextTick, provide, type App as VueApp } from 'vue'

import * as api from '@/api'
import ChatView from '../ChatView.vue'
import ChatRightSidebar from '../chat_right_sidebar/ChatRightSidebar.vue'
import CenterDiffSection from '../chat_right_sidebar/CenterDiffSection.vue'
import { OPEN_IN_CODE_EDITOR_KEY, type OpenInCodeEditorFn } from '@/composables/useCodeEditor'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '@/helpers/sseBus'
import type { SseClient, SseState } from '@/helpers/sseClient'
import { makeLocalStorageStub } from '@/__tests__/helpers'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const __dir = dirname(fileURLToPath(import.meta.url))
const chatViewSrc = readChatViewBundle()

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  // ChatView's URL sync does `router.replace(...).catch(...)`, so the
  // mock must return a thenable like the real router does.
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(() => Promise.resolve()),
    push: vi.fn(() => Promise.resolve()),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBaseMocks() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's_open',
    session_name: '',
    selectedAgent: null,
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

/** A changed file, in the shape `SidebarDiffPanel` emits as `show-diff`. */
const DIFF_SELECTION = {
  path: 'docs/task3.md',
  lines: [{ type: 'add' as const, content: 'hello', newLineNum: 7, lineIndex: 0 }],
  added: 1,
  removed: 0,
  staged: false,
  error: null,
}

describe('ChatView center-diff ⤴ opens the file in the code viewer', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null
  let openInEditor: Mock<OpenInCodeEditorFn>

  /**    * Mount ChatView under a real `OPEN_IN_CODE_EDITOR_KEY` provider — the same provide AppLayout
   * does — then open a center diff so the stacked sections (and their ⤴ buttons) actually render. */
  async function mountChatWithDiff() {
    openInEditor = vi.fn<OpenInCodeEditorFn>()
    const Host = defineComponent({
      setup() {
        provide(OPEN_IN_CODE_EDITOR_KEY, openInEditor)
        return () => h(ChatView, { chatId: 's_open', chatName: 'Open Chat', cwd: '/tmp/repo' })
      },
    })

    wrapper = mount(Host, { attachTo: document.body })
    await flushPromises()
    for (let i = 0; i < 30; i++) await nextTick()

    // Drive the REAL user path: the chat-owned right sidebar emits `show-diff`, ChatView stores it,
    // and the stacked center sections (which host the ⤴ button) render. Nothing reaches into the
    // component's internals — this is the same chain a click takes.
    const sidebar = wrapper.findComponent(ChatRightSidebar)
    expect(sidebar.exists()).toBe(true)
    sidebar.vm.$emit('show-diff', DIFF_SELECTION)
    for (let i = 0; i < 30; i++) await nextTick()
    await flushPromises()
    return wrapper
  }

  beforeEach(() => {
    // CenterDiffSection lazily mounts its SidebarDiffView behind an
    // IntersectionObserver; jsdom has none, so the section falls back to
    // mounting immediately and the ⤴ button exists for us to click.
    vi.stubGlobal('IntersectionObserver', undefined)
    // show-diff scrolls the section into view. jsdom implements neither
    // `scrollIntoView` nor `scrollTo`, on the prototype (the call is
    // `el.scrollIntoView(...)`, not a global).
    Element.prototype.scrollIntoView = vi.fn()
    Element.prototype.scrollTo = vi.fn()
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    installBaseMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('calls the injected opener with the file path, cwd and first added line', async () => {
    await mountChatWithDiff()

    const section = wrapper!.findComponent(CenterDiffSection)
    expect(section.exists()).toBe(true)

    const button = section.get('[data-testid="sidebar-diff-open-file"]')
    await button.trigger('click')

    // THE ASSERTION THAT WAS IMPOSSIBLE WITH A SOURCE GREP. On the
    // pre-fix source this is 0 calls: `inject()` inside the handler
    // returned undefined and the guard returned silently.
    expect(openInEditor).toHaveBeenCalledTimes(1)
    expect(openInEditor).toHaveBeenCalledWith({
      filePath: 'docs/task3.md',
      cwd: '/tmp/repo',
      line: 7,
    })
  })

  it('keeps the injection at setup scope (the grep that would have caught it)', () => {
    // Assert the SCOPE, not just the string. `inject()` must be called in the setup body — i.e. the
    // `const` starts at column 0, never indented inside a function. On the pre-fix source this line
    // is indented two spaces (nested in onChatSidebarOpenFile) and fails.
    expect(chatViewSrc).toMatch(/^const openInEditor = useInjectOpenInCodeEditor\(\)$/m)
    // …and the handler itself must NOT call the injector.
    const handler = chatViewSrc.slice(
      chatViewSrc.indexOf('function onChatSidebarOpenFile'),
      chatViewSrc.indexOf('\n}', chatViewSrc.indexOf('function onChatSidebarOpenFile')),
    )
    expect(handler).not.toMatch(/useInjectOpenInCodeEditor\(\)/)
  })
})
