/** The centre-diff TOOLBAR, asserted through a real ChatView mount: the two global controls that
 * the whole feature hangs off. - `Unified | Split` — the LAYOUT axis, every section at once -
 * `Expand all / Collapse all` — one state-aware button. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import ChatRightSidebar from '../components/views/chat_right_sidebar/ChatRightSidebar.vue'
import CenterDiffSection from '../components/views/chat_right_sidebar/CenterDiffSection.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import type { DiffSelection } from '../components/views/chat_right_sidebar/parseUnifiedDiff'
import { makeLocalStorageStub } from './helpers'

const proto = (
  globalThis as unknown as { HTMLElement: { prototype: Record<string, unknown> } }
).HTMLElement.prototype
if (typeof proto.scrollTo === 'undefined') {
  // jsdom 29 has no Element.scrollTo (see chatViewWorktree.spec.ts)…
  proto.scrollTo = function () {
    // no-op
  }
}
if (typeof proto.scrollIntoView === 'undefined') {
  // …and no scrollIntoView either, which `scrollToSectionElement` calls on
  // every sidebar-row click (the expand-before-scroll path).
  proto.scrollIntoView = function () {
    // no-op
  }
}

function makeStubClient(initial: SseState): SseClient {
  const stub = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => initial,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  return stub as unknown as SseClient
}

function installMocks() {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
    } as never)
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's1',
    session_name: '',
    cwd: '',
  } as never)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({ is_git_repo: false } as never)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as never)
}

const FILES: DiffSelection[] = [
  {
    path: 'a.go',
    staged: false,
    lines: [{ type: 'add', content: 'x', newLineNum: 1, lineIndex: 0 }],
    added: 1,
    removed: 0,
  },
  {
    path: 'b.go',
    staged: false,
    lines: [{ type: 'remove', content: 'y', oldLineNum: 1, lineIndex: 0 }],
    added: 0,
    removed: 1,
  },
]

let wrapper: VueWrapper | null = null
let app: VueApp | null = null

/** Mount, then open the diff stage the way the sidebar does: `show-diff`. */
async function mountWithDiffOpen(files: DiffSelection[] = FILES) {
  wrapper = mount(ChatView, {
    props: { chatId: 'session_toolbar', chatName: 'Toolbar Chat' },
    attachTo: document.body,
    global: { stubs: { ChatRightSidebar: true } },
  })
  await flushPromises()
  await nextTick()
  const sidebar = wrapper.findComponent(ChatRightSidebar)
  expect(sidebar.exists()).toBe(true)
  sidebar.vm.$emit('show-diff', files[0])
  sidebar.vm.$emit('show-diff-list', files)
  await nextTick()
  await nextTick()
  return wrapper
}

beforeEach(() => {
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
  __setSseBusGlobalClient(makeStubClient('connecting'))
  installMocks()
})

afterEach(() => {
  wrapper?.unmount()
  wrapper = null
  __resetSseBus()
  app = null
  vi.restoreAllMocks()
})

describe('ChatView centre-diff toolbar', () => {
  it('renders the layout + bulk controls only once the diff stage is open, and counts the files', async () => {
    const w = await mountWithDiffOpen()
    expect(w.find('[data-testid="chat-center-diff-mode"]').exists()).toBe(true)
    expect(w.find('[data-testid="chat-center-diff-mode-unified"]').exists()).toBe(true)
    expect(w.get('[data-testid="chat-center-diff-toggle-all"]').text()).toContain('Collapse all')
    expect(w.get('[data-testid="chat-center-diff-count"]').text().replace(/\s+/g, ' ')).toBe(
      '2 files',
    )
  })

  it('a single section toggle collapses exactly that file and states it in the count', async () => {
    const w = await mountWithDiffOpen()
    const second = w.findAllComponents(CenterDiffSection)[1]!
    second.vm.$emit('toggle-collapse')
    await nextTick()
    expect(w.findAllComponents(CenterDiffSection)[0]!.props('collapsed')).toBe(false)
    expect(w.findAllComponents(CenterDiffSection)[1]!.props('collapsed')).toBe(true)
    expect(w.get('[data-testid="chat-center-diff-count"]').text()).toContain('1 collapsed')
    expect(w.get('[data-testid="chat-center-diff-toggle-all"]').text()).toContain('Expand all')
  })

  it('Expand all collapses everything, and the button flips back to Collapse all', async () => {
    const w = await mountWithDiffOpen()
    await w.get('[data-testid="chat-center-diff-toggle-all"]').trigger('click')
    await nextTick()
    expect(w.findAllComponents(CenterDiffSection).every((s) => s.props('collapsed') === true)).toBe(
      true,
    )
    expect(w.get('[data-testid="chat-center-diff-count"]').text()).toContain('2 collapsed')
    const btn = w.get('[data-testid="chat-center-diff-toggle-all"]')
    expect(btn.text()).toContain('Expand all')

    await btn.trigger('click')
    await nextTick()
    expect(
      w.findAllComponents(CenterDiffSection).every((s) => s.props('collapsed') === false),
    ).toBe(true)
    expect(w.get('[data-testid="chat-center-diff-count"]').text()).not.toContain('collapsed')
  })

  it('the layout toggle reaches EVERY section (one axis, not per file)', async () => {
    const w = await mountWithDiffOpen()
    await w.get('[data-testid="chat-center-diff-mode-split"]').trigger('click')
    await nextTick()
    expect(w.findAllComponents(CenterDiffSection).map((s) => s.props('mode'))).toEqual([
      'split',
      'split',
    ])

    await w.get('[data-testid="chat-center-diff-mode-unified"]').trigger('click')
    await nextTick()
    expect(w.findAllComponents(CenterDiffSection).map((s) => s.props('mode'))).toEqual([
      'unified',
      'unified',
    ])
  })

  it('Whole file is per section: toggling one does not follow the others', async () => {
    const w = await mountWithDiffOpen()
    w.findAllComponents(CenterDiffSection)[0]!.vm.$emit('toggle-whole-file')
    await nextTick()
    expect(w.findAllComponents(CenterDiffSection).map((s) => s.props('wholeFile'))).toEqual([
      true,
      false,
    ])
  })

  it('an untracked file is whole by definition — scope on, and no request implied', async () => {
    const untracked: DiffSelection = { ...FILES[0]!, path: 'new.txt', untracked: true }
    const w = await mountWithDiffOpen([untracked])
    const section = w.findAllComponents(CenterDiffSection)[0]!
    expect(section.props('untracked')).toBe(true)
    expect(section.props('wholeFile')).toBe(true)
  })
})
