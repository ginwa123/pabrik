/** Behaviour tests for the window-level terminal footer: the strip opens the
 * dialog, the dialog lists the live shells grouped per workspace, and picking
 * one turns the dialog into that terminal. */
import { mount } from '@vue/test-utils'
import { describe, expect, it, beforeEach, vi } from 'vitest'

// ─── xterm fakes (jsdom has no layout/canvas for the real renderer) ─────────
const { FakeTerminal, FakeFitAddon } = vi.hoisted(() => {
  class FakeTerminal {
    static instances: FakeTerminal[] = []
    cols = 80
    rows = 24
    written: string[] = []
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
    fit() {}
  }

  return { FakeTerminal, FakeFitAddon }
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
  }

  return { FakeWebSocket }
})

vi.stubGlobal('WebSocket', FakeWebSocket)

// ─── API fake ───────────────────────────────────────────────────────────────
const apiState = {
  sessions: [] as Array<{
    id: string
    workspace_id: string
    cwd: string
    cols: number
    rows: number
    exited: boolean
    backend: string
  }>,
  nextId: 0,
}

vi.mock('../api', () => ({
  createTerminalSession: vi.fn(async (workspaceId: string, cwd: string) => {
    apiState.nextId += 1
    const id = `term-new-${apiState.nextId}`
    apiState.sessions = [
      ...apiState.sessions,
      {
        id,
        workspace_id: workspaceId,
        cwd,
        cols: 80,
        rows: 24,
        exited: false,
        backend: 'posix-pty',
      },
    ]
    return { id, pid: 900 + apiState.nextId }
  }),
  listTerminalSessions: vi.fn(async () => apiState.sessions),
  sendTerminalInput: vi.fn(async () => ({ ok: true, bytes: 3 })),
  resizeTerminal: vi.fn(async () => ({ ok: true, cols: 80, rows: 24 })),
}))

import TerminalFooter from '../components/shell/TerminalFooter.vue'
import { createTerminalSession } from '../api'

const flush = async (rounds = 5) => {
  for (let i = 0; i < rounds; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const WORKSPACES = [
  { id: 'ws_1', name: 'Pabrik SaaS' },
  { id: 'ws_2', name: 'Kabelweb' },
]

const mountFooter = () =>
  mount(TerminalFooter, {
    props: {
      workspaces: WORKSPACES,
      activeWorkspaceId: 'ws_1',
      cwd: '/home/ginwa/pabrik',
    },
  })

const q = (selector: string) => document.body.querySelector(selector)
const qAll = (selector: string) => Array.from(document.body.querySelectorAll(selector))

describe('the terminal footer', () => {
  beforeEach(() => {
    FakeTerminal.instances = []
    FakeWebSocket.instances = []
    apiState.nextId = 0
    apiState.sessions = [
      {
        id: 'term-1',
        workspace_id: 'ws_1',
        cwd: '/home/ginwa/pabrik',
        cols: 80,
        rows: 24,
        exited: false,
        backend: 'posix-pty',
      },
      {
        id: 'term-2',
        workspace_id: 'ws_2',
        cwd: '/home/ginwa/kabelweb',
        cols: 80,
        rows: 24,
        exited: false,
        backend: 'posix-pty',
      },
      {
        id: 'term-3',
        workspace_id: 'ws_1',
        cwd: '/home/ginwa/pabrik',
        cols: 80,
        rows: 24,
        exited: true,
        backend: 'posix-pty',
      },
    ]
    document.body.innerHTML = ''
    vi.clearAllMocks()
  })

  it('opens a dialog that lists the live shells grouped per workspace', async () => {
    const wrapper = mountFooter()
    await flush()

    // The strip carries the count of the shells that are running.
    expect(wrapper.find('[data-testid="terminal-footer-count"]').text()).toBe('2')

    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()

    const groups = qAll('[data-testid="terminal-footer-group"]')
    expect(groups).toHaveLength(2)
    // The group heading names the workspace, and the row under it belongs
    // to that workspace.
    const names = qAll('[data-testid="terminal-footer-group-name"]').map((n) =>
      n.textContent?.trim(),
    )
    expect(names).toEqual(['Pabrik SaaS', 'Kabelweb'])
    const rows = qAll('[data-testid="terminal-footer-row"]')
    expect(rows.map((r) => (r as HTMLElement).dataset.session)).toEqual([
      'term-1',
      'term-3',
      'term-2',
    ])
    expect((rows[0] as HTMLElement).dataset.workspace).toBe('ws_1')
    expect((rows[2] as HTMLElement).dataset.workspace).toBe('ws_2')

    wrapper.unmount()
  })

  it('shows a shell whose workspace is gone, dimmed, instead of hiding it', async () => {
    apiState.sessions = [
      ...apiState.sessions,
      {
        id: 'term-9',
        workspace_id: 'ws_deleted',
        cwd: '/home/ginwa/legacy',
        cols: 80,
        rows: 24,
        exited: false,
        backend: 'posix-pty',
      },
    ]
    const wrapper = mountFooter()
    await flush()
    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()

    // The shell still runs, so it is listed — and it says the truth about
    // the workspace that owned it.
    expect(q('[data-session="term-9"]')).not.toBeNull()
    expect(q('[data-testid="terminal-footer-group-gone"]')?.textContent).toContain(
      'workspace deleted',
    )
    const row = q('[data-session="term-9"]') as HTMLElement
    expect(Number(row.style.opacity)).toBeLessThan(1)

    wrapper.unmount()
  })

  it('turns the dialog into the terminal when a shell is picked', async () => {
    const wrapper = mountFooter()
    await flush()
    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()

    ;(q('[data-session="term-1"]') as HTMLElement).click()
    await flush()

    // The list is replaced by the session it named, and the shell is
    // attached to THAT session.
    expect(q('[data-testid="terminal-footer-list"]')).toBeNull()
    expect(q('[data-testid="terminal-footer-terminal"]')).not.toBeNull()
    expect(FakeWebSocket.instances.map((s) => s.url).join(' ')).toContain('id=term-1')
    expect(FakeTerminal.instances).toHaveLength(1)

    wrapper.unmount()
  })

  it('puts the list back when the back arrow is pressed', async () => {
    const wrapper = mountFooter()
    await flush()
    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()
    ;(q('[data-session="term-1"]') as HTMLElement).click()
    await flush()

    ;(q('[data-testid="terminal-footer-back"]') as HTMLElement).click()
    await flush()

    expect(q('[data-testid="terminal-footer-list"]')).not.toBeNull()
    expect(q('[data-testid="terminal-footer-terminal"]')).toBeNull()
    // The socket to the shell is closed: the shell keeps running on the
    // server, the footer just stops watching it.
    expect(FakeWebSocket.instances.every((s) => s.closed)).toBe(true)

    wrapper.unmount()
  })

  it('starts a new shell in the workspace the app is on', async () => {
    const wrapper = mountFooter()
    await flush()
    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()

    ;(q('[data-testid="terminal-footer-new"]') as HTMLElement).click()
    await flush()

    expect(createTerminalSession).toHaveBeenCalledWith('ws_1', '/home/ginwa/pabrik', {})
    // The new shell is opened, not merely created.
    expect(q('[data-testid="terminal-footer-terminal"]')).not.toBeNull()

    wrapper.unmount()
  })

  it('starts a new shell in the workspace of the group it was pressed in', async () => {
    const wrapper = mountFooter()
    await flush()
    await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
    await flush()

    const groupNew = qAll('[data-testid="terminal-footer-group-new"]')[1] as HTMLElement
    groupNew.click()
    await flush()

    expect(createTerminalSession).toHaveBeenCalledWith('ws_2', '', {})

    wrapper.unmount()
  })
})
