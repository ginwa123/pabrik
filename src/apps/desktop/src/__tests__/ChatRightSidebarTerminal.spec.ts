import { mount } from '@vue/test-utils'
import { describe, expect, it, beforeEach, vi } from 'vitest'

import ChatRightSidebar from '../components/views/chat_right_sidebar/ChatRightSidebar.vue'
import TerminalTab from '../components/views/chat_right_sidebar/TerminalTab.vue'
import { makeLocalStorageStub } from './helpers'

// ─── xterm fakes (jsdom has no layout/canvas for the real renderer) ─────────
// vi.mock factories hoist above class declarations, so the fakes live
// in vi.hoisted (otherwise "Cannot access before initialization").
const { FakeTerminal, FakeFitAddon, FakeApiError } = vi.hoisted(() => {
  class FakeTerminal {
    static instances: FakeTerminal[] = []
    cols = 80
    rows = 24
    written: string[] = []
    cleared = 0
    disposed = false
    dataHandler: ((data: string) => void) | null = null

    constructor() {
      FakeTerminal.instances.push(this)
    }

    loadAddon() {}
    open() {}
    write(data: string) {
      this.written.push(data)
    }
    clear() {
      this.cleared += 1
      this.written = []
    }
    onData(cb: (data: string) => void) {
      this.dataHandler = cb
    }
    dispose() {
      this.disposed = true
    }
  }

  class FakeFitAddon {
    fitted = 0
    fit() {
      this.fitted += 1
    }
  }

  class FakeApiError extends Error {
    status: number
    constructor(status = 500) {
      super(`HTTP ${status}`)
      this.status = status
    }
  }

  return { FakeTerminal, FakeFitAddon, FakeApiError }
})

vi.mock('@xterm/xterm', () => ({ Terminal: FakeTerminal }))
vi.mock('@xterm/addon-fit', () => ({ FitAddon: FakeFitAddon }))

// ─── WebSocket fake ─────────────────────────────────────────────────────────
const { FakeWebSocket } = vi.hoisted(() => {
  type Handler = ((event: never) => void) | null
  class FakeWebSocket {
    static instances: FakeWebSocket[] = []
    static CONNECTING = 0
    static OPEN = 1
    static CLOSING = 2
    static CLOSED = 3

    url: string
    readyState = 0
    binaryType = ''
    sent: string[] = []
    closed = false
    onopen: Handler = null
    onmessage: Handler = null
    onerror: Handler = null
    onclose: Handler = null

    constructor(url: string) {
      this.url = url
      FakeWebSocket.instances.push(this)
    }

    send(data: string) {
      this.sent.push(data)
    }
    close() {
      this.closed = true
      this.readyState = FakeWebSocket.CLOSED
    }
    serverOpen() {
      this.readyState = FakeWebSocket.OPEN
      this.onopen?.(undefined as never)
    }
    serverMessage(data: unknown) {
      this.onmessage?.({ data } as never)
    }
    serverError() {
      this.onerror?.(undefined as never)
    }
    serverClose() {
      this.readyState = FakeWebSocket.CLOSED
      this.onclose?.(undefined as never)
    }
  }

  return { FakeWebSocket }
})

vi.stubGlobal('WebSocket', FakeWebSocket)

// ─── API fakes (incrementing session ids for multi-session tests) ──────────
const apiState = {
  nextId: 0,
  output404For: null as string | null,
  outputs: [] as Array<{ data: string; cursor: number; exited: boolean; exit_code: number | null }>,
}

vi.mock('../api', () => ({
  ApiError: FakeApiError,
  createTerminalSession: vi.fn(async (cwd: string) => {
    apiState.nextId += 1
    return { id: `term-${apiState.nextId}`, pid: 100 + apiState.nextId, cwd }
  }),
  sendTerminalInput: vi.fn(async () => ({ ok: true, bytes: 3 })),
  getTerminalOutput: vi.fn(async (id: string) => {
    if (apiState.output404For === id) throw new FakeApiError(404)
    return apiState.outputs.shift() ?? { data: '', cursor: 0, exited: false, exit_code: null }
  }),
  resizeTerminal: vi.fn(async (_id: string, cols: number, rows: number) => ({
    ok: true,
    cols,
    rows,
  })),
  deleteTerminalSession: vi.fn(async () => ({ ok: true })),
}))

import {
  createTerminalSession,
  sendTerminalInput,
  getTerminalOutput,
  deleteTerminalSession,
} from '../api'

const flush = async (rounds = 5) => {
  for (let i = 0; i < rounds; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

// Condition-based waits. Session creation needs ~350ms of real time
// (300ms cwd-stability window); fixed sleeps assert unreliably under
// load, so wait for the condition instead.
const waitFor = async (cond: () => boolean, timeoutMs = 8000) => {
  const start = Date.now()
  while (!cond()) {
    if (Date.now() - start > timeoutMs) break
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  await flush()
}

const waitForCreates = async (n: number) => {
  await waitFor(() => apiState.nextId >= n)
}

const mountSidebar = () =>
  mount(ChatRightSidebar, {
    props: { cwd: '/tmp/toolbox', open: true, width: 280 },
  })

const firstTerm = () => {
  const term = FakeTerminal.instances[0]!
  expect(term).toBeDefined()
  return term
}

const socketFor = (id: string) => {
  const matches = FakeWebSocket.instances.filter((s) => s.url.includes(`id=${id}`))
  expect(matches.length).toBeGreaterThan(0)
  return matches[matches.length - 1]!
}

const chips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="terminal-session-chip"]')

const encode = (text: string) => new TextEncoder().encode(text)

describe('ChatRightSidebar terminal tab (Phase 4: multi-session)', () => {
  beforeEach(() => {
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    FakeTerminal.instances = []
    FakeWebSocket.instances = []
    apiState.nextId = 0
    apiState.output404For = null
    apiState.outputs = []
    vi.clearAllMocks()
  })

  it('keeps both panels mounted and persists the active tab', async () => {
    const wrapper = mountSidebar()
    await flush()
    expect(wrapper.find('[data-testid="terminal-tab"]').exists()).toBe(true)
    await wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').trigger('click')
    expect(localStorage.getItem('pabrik-right-sidebar-panel')).toBe('terminal')
    wrapper.unmount()
  })

  it('stays empty on mount and creates only on explicit action', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    // Mounting (ChatRightSidebar keeps the tab mounted via v-show) must not spawn.
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('No terminal')
    await wrapper.find('[data-testid="terminal-empty-new"]').trigger('click')
    await waitForCreates(1)
    expect(createTerminalSession).toHaveBeenCalledWith('/tmp/toolbox', {
      cols: 80,
      rows: 24,
    })
    expect(chips(wrapper)).toHaveLength(1)
    const socket = socketFor('term-1')
    socket.serverOpen()
    socket.serverMessage(encode('hello'))
    await flush()
    expect(firstTerm().written.join('')).toContain('hello')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('connected')
    expect(getTerminalOutput).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('opens a second session with an isolated socket', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(2)
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
    expect(chips(wrapper)).toHaveLength(2)
    const socket2 = socketFor('term-2')
    socket2.serverOpen()

    // Input goes to the active (second) socket only.
    firstTerm().dataHandler?.('ls\n')
    await flush()
    expect(socket2.sent).toContain(JSON.stringify({ type: 'input', data: 'ls\n' }))
    expect(socketFor('term-1').sent).toEqual([])
    expect(sendTerminalInput).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('switching sessions clears the view and attaches to that session', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()
    socketFor('term-1').serverMessage(encode('first'))
    await flush()
    expect(firstTerm().written.join('')).toContain('first')

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(2)
    socketFor('term-2').serverOpen()

    // Switch back: view cleared, fresh socket for term-1.
    const clearedBefore = firstTerm().cleared
    await chips(wrapper)[0]!.trigger('click')
    await flush()
    expect(firstTerm().cleared).toBeGreaterThan(clearedBefore)
    const socketsForOne = FakeWebSocket.instances.filter((s) => s.url.includes('id=term-1'))
    expect(socketsForOne.length).toBe(2)

    // Input now routes to term-1 again.
    socketsForOne[1]!.serverOpen()
    firstTerm().dataHandler?.('pwd\n')
    await flush()
    expect(socketsForOne[1]!.sent).toContain(JSON.stringify({ type: 'input', data: 'pwd\n' }))
    wrapper.unmount()
  })

  it('closing a background session deletes it and keeps the active one', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(2)
    expect(chips(wrapper)).toHaveLength(2)

    // Close term-1 (background): active term-2 untouched.
    const closers = wrapper.findAll('[data-testid="terminal-session-close"]')
    await closers[0]!.trigger('click')
    await flush()
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    expect(chips(wrapper)).toHaveLength(1)
    expect(createTerminalSession).toHaveBeenCalledTimes(2) // no replacement needed
    wrapper.unmount()
  })

  it('killing the last session leaves an empty state (no auto-spawn)', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()

    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    // No auto-spawn: empty state until explicit action.
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    expect(chips(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('No terminal')
    wrapper.unmount()
  })

  it('reconnects WS after a pre-open failure (no polling loop)', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    const before = FakeWebSocket.instances.length
    firstSocket().serverError()
    await flush(10)
    // One-shot validation, then backoff reconnect — never a poll interval.
    expect(getTerminalOutput).toHaveBeenCalledWith('term-1', 0)
    expect(firstTerm().written.join('')).not.toContain('fb')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('reconnecting')
    // Backoff fires (0.5-1s for attempt 1): a fresh socket re-attaches same id.
    await waitFor(() => FakeWebSocket.instances.length > before, 5000)
    const retry = FakeWebSocket.instances[FakeWebSocket.instances.length - 1]!
    expect(retry.url).toContain('id=term-1')
    retry.serverOpen()
    await flush()
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('connected')
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    wrapper.unmount()
  })

  it('sends input via REST while reconnecting without polling output', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    // Force the REST input path: open then drop so wsOpened=false.
    firstSocket().serverOpen()
    firstSocket().serverClose()
    await flush(10)
    vi.clearAllMocks()
    firstTerm().dataHandler?.('y')
    await flush()
    expect(sendTerminalInput).toHaveBeenCalledWith('term-1', 'y')
    expect(getTerminalOutput).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('shows the exited state on the socket exit event', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    const socket = firstSocket()
    socket.serverOpen()
    socket.serverMessage(JSON.stringify({ type: 'exit', exit_code: 0 }))
    await flush(10)
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('code 0')
    wrapper.unmount()
  })

  it('persists sessions per chat key and re-attaches on remount', async () => {
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-abc' },
    })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()
    expect(localStorage.getItem('pabrik-terminal-sessions:chat-abc')).toContain('term-1')

    // Unmount (chat switch): keyed sessions are NOT deleted server-side.
    wrapper.unmount()
    await flush()
    expect(deleteTerminalSession).not.toHaveBeenCalled()

    // Remount: stored id validates via output poll, no new session, WS re-attaches.
    const wrapper2 = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-abc' },
    })
    await flush()
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    expect(getTerminalOutput).toHaveBeenCalledWith('term-1', 0)
    const reattached = socketFor('term-1')
    reattached.serverOpen()
    reattached.serverMessage(encode('back-again'))
    await flush()
    expect(FakeTerminal.instances[1]!.written.join('')).toContain('back-again')
    wrapper2.unmount()
  })

  it('drops 404 sessions on restore and stays empty', async () => {
    localStorage.setItem(
      'pabrik-terminal-sessions:chat-gone',
      JSON.stringify([{ id: 'old-9', label: 'term 1' }]),
    )
    apiState.output404For = 'old-9'
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-gone' },
    })
    await flush()
    // Gone id dropped (no delete call — already gone server-side)…
    expect(deleteTerminalSession).not.toHaveBeenCalledWith('old-9')
    // …and no replacement is auto-created — user starts explicitly.
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(chips(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(true)
    expect(localStorage.getItem('pabrik-terminal-sessions:chat-gone')).not.toContain('old-9')
    wrapper.unmount()
  })

  it('reclaims a 404 session on attach failure and goes empty', async () => {
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-evict' },
    })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    // Server loses the session (restart / LRU): attach fails fast.
    apiState.output404For = 'term-1'
    firstSocket().serverError()
    await flush(10)
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    expect(chips(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('numbers new sessions past restored labels (no duplicate chips)', async () => {
    localStorage.setItem(
      'pabrik-terminal-sessions:chat-nums',
      JSON.stringify([
        { id: 'a', label: 'term 2' },
        { id: 'b', label: 'term 5' },
      ]),
    )
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-nums' },
    })
    await flush()
    expect(chips(wrapper)).toHaveLength(2)

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    const labels = chips(wrapper).map((c) => c.text())
    expect(labels).toHaveLength(3)
    expect(labels.join(' ')).toContain('term 6')
    expect(new Set(labels).size).toBe(labels.length)
    wrapper.unmount()
  })

  it('switching back to an exited session re-attaches for history', async () => {
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-exit-hist' },
    })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    socketFor('term-1').serverOpen()
    socketFor('term-1').serverMessage(JSON.stringify({ type: 'exit', exit_code: 0 }))
    await flush(10)

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(2)
    socketFor('term-2').serverOpen()

    // Switch back: a FRESH socket attaches (server flushes the dead
    // shell's buffer first), no session is recreated.
    await chips(wrapper)[0]!.trigger('click')
    await flush()
    const socketsForOne = FakeWebSocket.instances.filter((s) => s.url.includes('id=term-1'))
    expect(socketsForOne.length).toBe(2)
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
    wrapper.unmount()
  })

  it('waits for late cwd instead of spawning twice', async () => {
    // Mount before effectiveCwd resolves (the chat-return race): one
    // session, created with the resolved dir — not fallback + recreate.
    const wrapper = mount(TerminalTab, {
      props: { cwd: '', sessionKey: 'chat-late-cwd' },
    })
    await new Promise((resolve) => setTimeout(resolve, 120))
    await wrapper.setProps({ cwd: '/real/dir' })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    expect(createTerminalSession).toHaveBeenCalledWith('/real/dir', {
      cols: 80,
      rows: 24,
    })
    wrapper.unmount()
  })

  it('late cwd resolution does not drop restored sessions', async () => {
    localStorage.setItem(
      'pabrik-terminal-sessions:chat-restore-cwd',
      JSON.stringify([{ id: 'term-9', label: 'term 9' }]),
    )
    const wrapper = mount(TerminalTab, {
      props: { cwd: '', sessionKey: 'chat-restore-cwd' },
    })
    await flush()
    // Restored by id without waiting for cwd, no fresh session.
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(chips(wrapper)).toHaveLength(1)

    // Cwd arriving late must not wipe the restored session.
    await wrapper.setProps({ cwd: '/real/dir' })
    await flush(10)
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(chips(wrapper)).toHaveLength(1)
    expect(deleteTerminalSession).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('ignores mount-time worktree cwd flips, recreates on real change', async () => {
    // Git worktree binding resolves as session dir -> worktree dir on
    // every mount. Those mount-time flips must not wipe the restored
    // session ("always a new term" with worktrees).
    localStorage.setItem(
      'pabrik-terminal-sessions:chat-worktree',
      JSON.stringify([{ id: 'wt-1', label: 'term 1' }]),
    )
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/session/dir', sessionKey: 'chat-worktree' },
    })
    await flush()
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(chips(wrapper)).toHaveLength(1)

    await wrapper.setProps({ cwd: '/worktrees/chat-1' })
    await flush(10)
    await wrapper.setProps({ cwd: '/worktrees/chat-1-final' })
    await flush(10)
    expect(createTerminalSession).not.toHaveBeenCalled()
    expect(deleteTerminalSession).not.toHaveBeenCalled()
    expect(chips(wrapper)).toHaveLength(1)

    // A genuine scope change after the grace window restarts shells.
    await new Promise((resolve) => setTimeout(resolve, 3100))
    await wrapper.setProps({ cwd: '/other/project' })
    await waitForCreates(1)
    expect(deleteTerminalSession).toHaveBeenCalledWith('wt-1')
    expect(createTerminalSession).toHaveBeenCalledTimes(1)
    wrapper.unmount()
  })

  it('shows a session counter', async () => {
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-counter' },
    })
    await flush()
    expect(wrapper.find('[data-testid="terminal-count"]').text()).toContain('0/20')
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitForCreates(1)
    const count = wrapper.find('[data-testid="terminal-count"]')
    expect(count.exists()).toBe(true)
    expect(count.text()).toContain('1/20')
    wrapper.unmount()
  })

  it('surfaces the 429 cap message when the server is full', async () => {
    vi.mocked(createTerminalSession).mockRejectedValueOnce(new FakeApiError(429))
    const wrapper = mount(TerminalTab, {
      props: { cwd: '/tmp/toolbox', sessionKey: 'chat-cap-429' },
    })
    await flush()
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('No terminal')
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await waitFor(() => wrapper.find('[data-testid="terminal-status"]').text().includes('Max 20'))
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('Max 20')
    wrapper.unmount()
  })
})

const firstSocket = () => {
  const socket = FakeWebSocket.instances[0]!
  expect(socket).toBeDefined()
  return socket
}
