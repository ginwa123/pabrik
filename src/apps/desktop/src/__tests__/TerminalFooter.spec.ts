import { mount } from '@vue/test-utils'
import { describe, expect, it, beforeEach, vi } from 'vitest'

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
    proposeDimensions() {
      return { cols: 80, rows: 24 }
    }
  }

  return { FakeTerminal, FakeFitAddon }
})

vi.mock('@xterm/xterm', () => ({ Terminal: FakeTerminal }))
vi.mock('@xterm/addon-fit', () => ({ FitAddon: FakeFitAddon }))

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

interface Row {
  id: string
  workspace_id: string
  cwd: string
  cols: number
  rows: number
  exited: boolean
  backend: string
}

const apiState = {
  sessions: [] as Row[],
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
  deleteTerminalSession: vi.fn(async (id: string) => {
    apiState.sessions = apiState.sessions.filter((s) => s.id !== id)
    return { ok: true }
  }),
  sendTerminalInput: vi.fn(async () => ({ ok: true, bytes: 3 })),
  resizeTerminal: vi.fn(async () => ({ ok: true, cols: 80, rows: 24 })),
}))

import TerminalFooter from '../components/shell/TerminalFooter.vue'
import { createTerminalSession } from '../api'
import { makeLocalStorageStub } from './helpers'

const HEIGHT_KEY = 'pabrik-terminal-panel-height'

const flush = async (rounds = 6) => {
  for (let i = 0; i < rounds; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const WORKSPACES = [
  { id: 'ws_1', name: 'Pabrik SaaS' },
  { id: 'ws_2', name: 'Kabelweb', items: [{ path: '/home/ginwa/kabelweb' }] },
  { id: 'ws_3', name: 'Ruangsql' },
]

const mountFooter = () => mountInWorkspace('ws_1', '/home/ginwa/pabrik')

const mountInWorkspace = (activeWorkspaceId: string, cwd: string) =>
  mount(TerminalFooter, {
    props: {
      workspaces: WORKSPACES,
      activeWorkspaceId,
      cwd,
    },
  })

const openPanel = async (wrapper: ReturnType<typeof mountFooter>) => {
  await wrapper.find('[data-testid="terminal-footer-open"]').trigger('click')
  await flush()
}

const tabIds = (wrapper: ReturnType<typeof mountFooter>) =>
  wrapper.findAll('[data-testid="terminal-tab"]').map((tab) => tab.attributes('data-session'))

const socketIds = () =>
  FakeWebSocket.instances.map((socket) => new URL(socket.url).searchParams.get('id'))

describe('the terminal dock', () => {
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
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.clearAllMocks()
  })

  it('reports how many shells are running on the strip', async () => {
    const wrapper = mountFooter()
    await flush()

    expect(wrapper.find('[data-testid="terminal-footer-count"]').text()).toBe('2')

    wrapper.unmount()
  })

  it('docks the panel inside the window instead of opening a dialog over it', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    const panel = wrapper.find('[data-testid="terminal-panel"]')
    expect(panel.exists()).toBe(true)
    expect(panel.attributes('role')).toBe('region')
    expect(panel.attributes('class')).not.toContain('fixed')
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="terminal-footer-dialog"]').exists()).toBe(false)
    expect(panel.element.parentElement).toBe(
      wrapper.find('[data-testid="terminal-footer"]').element.parentElement,
    )

    wrapper.unmount()
  })

  it('attaches a shell that is already running when the panel opens', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    expect(socketIds()).toEqual(['term-1'])
    expect(FakeTerminal.instances).toHaveLength(1)

    wrapper.unmount()
  })

  it('opens on the shell of the workspace the browser is on', async () => {
    const wrapper = mountInWorkspace('ws_2', '/home/ginwa/kabelweb')
    await flush()
    await openPanel(wrapper)

    expect(socketIds()).toEqual(['term-2'])
    expect(wrapper.find('[data-testid="terminal-tab"][data-session="term-2"]').attributes('data-active')).toBe(
      'true',
    )
    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(false)

    wrapper.unmount()
  })

  it('offers a shell in this workspace instead of attaching another workspace shell', async () => {
    const wrapper = mountInWorkspace('ws_3', '')
    await flush()
    await openPanel(wrapper)

    expect(socketIds()).toEqual([])
    const empty = wrapper.find('[data-testid="terminal-empty"]')
    expect(empty.exists()).toBe(true)
    expect(empty.text()).toContain('No shell in Ruangsql')

    const offered = wrapper.find('[data-testid="terminal-empty-new"]')
    expect(offered.attributes('data-workspace-id')).toBe('ws_3')
    expect(offered.attributes('data-current')).toBe('true')

    await offered.trigger('click')
    await flush()

    expect(tabIds(wrapper)).toEqual(['term-new-1', 'term-1', 'term-3', 'term-2'])
    expect(wrapper.find('[data-session="term-new-1"]').attributes('data-active')).toBe('true')

    wrapper.unmount()
  })

  it('attaches any running shell when the browser names no workspace', async () => {
    const wrapper = mountInWorkspace('', '')
    await flush()
    await openPanel(wrapper)

    expect(socketIds()).toEqual(['term-1'])
    expect(wrapper.find('[data-testid="terminal-footer-workspace"]').exists()).toBe(false)

    wrapper.unmount()
  })

  it('attaches any running shell when the browser names a workspace the app does not know', async () => {
    const wrapper = mountInWorkspace('ws_gone', '')
    await flush()
    await openPanel(wrapper)

    expect(socketIds()).toEqual(['term-1'])

    wrapper.unmount()
  })

  it('follows the workspace the browser navigates to', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)
    expect(socketIds()).toEqual(['term-1'])
    expect(wrapper.find('[data-testid="terminal-footer-workspace"]').text()).toBe('Pabrik SaaS')

    await wrapper.setProps({ activeWorkspaceId: 'ws_2', cwd: '/home/ginwa/kabelweb' })
    await flush()

    expect(FakeWebSocket.instances[0]?.closed).toBe(true)
    expect(socketIds()).toEqual(['term-1', 'term-2'])
    expect(wrapper.find('[data-testid="terminal-tab"][data-session="term-2"]').attributes('data-active')).toBe(
      'true',
    )
    expect(wrapper.find('[data-testid="terminal-footer-workspace"]').text()).toBe('Kabelweb')

    wrapper.unmount()
  })

  it('detaches when the browser moves to a workspace that has no live shell', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.setProps({ activeWorkspaceId: 'ws_3', cwd: '' })
    await flush()

    expect(FakeWebSocket.instances.every((socket) => socket.closed)).toBe(true)
    expect(wrapper.find('[data-testid="terminal-tab"][data-active="true"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="terminal-empty"]').text()).toContain('No shell in Ruangsql')
    expect(tabIds(wrapper)).toContain('term-1')

    wrapper.unmount()
  })

  it('keeps a shell picked by hand while the browser stays on one workspace', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-tab"][data-session="term-2"]').trigger('click')
    await flush()

    await wrapper.setProps({ activeWorkspaceId: 'ws_2', cwd: '/home/ginwa/kabelweb' })
    await flush()

    expect(socketIds()).toEqual(['term-1', 'term-2'])
    expect(FakeWebSocket.instances[1]?.closed).toBe(false)

    wrapper.unmount()
  })

  it('puts the shells of the workspace the browser is on first', async () => {
    const wrapper = mountInWorkspace('ws_2', '/home/ginwa/kabelweb')
    await flush()
    await openPanel(wrapper)

    expect(tabIds(wrapper)).toEqual(['term-2', 'term-1', 'term-3'])

    wrapper.unmount()
  })

  it('puts one tab per shell in the header, shells of a workspace together', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    expect(tabIds(wrapper)).toEqual(['term-1', 'term-3', 'term-2'])
    expect(wrapper.findAll('[data-testid="terminal-tab"]')[0]?.attributes('data-active')).toBe('true')

    wrapper.unmount()
  })

  it('attaches the shell a tab names and drops the socket of the tab left behind', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-tab"][data-session="term-2"]').trigger('click')
    await flush()

    expect(socketIds()).toEqual(['term-1', 'term-2'])
    expect(FakeWebSocket.instances[0]?.closed).toBe(true)
    expect(FakeWebSocket.instances[1]?.closed).toBe(false)
    expect(FakeTerminal.instances[0]?.disposed).toBe(true)
    expect(wrapper.find('[data-session="term-2"]').attributes('data-active')).toBe('true')

    wrapper.unmount()
  })

  it('keeps a shell whose workspace is gone, marked and dimmed', async () => {
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
    await openPanel(wrapper)

    const tab = wrapper.find('[data-testid="terminal-tab"][data-session="term-9"]')
    expect(tab.exists()).toBe(true)
    expect(tab.attributes('data-orphan')).toBe('true')
    expect(tab.attributes('title')).toContain('workspace deleted')

    await tab.trigger('click')
    await flush()

    expect(socketIds()).toContain('term-9')
    expect(wrapper.find('[data-testid="terminal-orphan"]').text()).toContain('workspace deleted')

    wrapper.unmount()
  })

  it('marks the tab of a shell that has exited', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    const tab = wrapper.find('[data-testid="terminal-tab"][data-session="term-3"]')
    expect(tab.attributes('data-exited')).toBe('true')
    expect(tab.attributes('title')).toContain('exited')

    wrapper.unmount()
  })

  it('starts a new shell in the workspace the app is on', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await flush()

    expect(createTerminalSession).toHaveBeenCalledWith('ws_1', '/home/ginwa/pabrik', {})
    expect(tabIds(wrapper)).toContain('term-new-1')
    expect(socketIds()).toContain('term-new-1')
    expect(wrapper.find('[data-session="term-new-1"]').attributes('data-active')).toBe('true')

    wrapper.unmount()
  })

  it('starts a new shell in a workspace picked from the header menu', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-new-menu"]').trigger('click')
    await flush()
    await wrapper
      .find('[data-testid="terminal-new-in-workspace"][data-workspace-id="ws_2"]')
      .trigger('click')
    await flush()

    expect(createTerminalSession).toHaveBeenCalledWith('ws_2', '/home/ginwa/kabelweb', {})
    expect(tabIds(wrapper)).toContain('term-new-1')

    wrapper.unmount()
  })

  it('closes the socket when the panel closes while the shell keeps running', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-close"]').trigger('click')
    await flush()

    expect(wrapper.find('[data-testid="terminal-panel"]').exists()).toBe(false)
    expect(FakeWebSocket.instances.every((socket) => socket.closed)).toBe(true)
    expect(wrapper.find('[data-testid="terminal-footer-count"]').text()).toBe('2')

    wrapper.unmount()
  })

  it('drops the tab and the socket of a killed shell, and asks for one in this workspace', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()

    expect(tabIds(wrapper)).not.toContain('term-1')
    expect(FakeWebSocket.instances[0]?.closed).toBe(true)
    expect(FakeWebSocket.instances).toHaveLength(1)
    expect(wrapper.find('[data-testid="terminal-empty"]').text()).toContain('No shell in Pabrik SaaS')

    wrapper.unmount()
  })

  it('watches the next live shell of this workspace after a kill', async () => {
    apiState.sessions = [
      ...apiState.sessions,
      {
        id: 'term-4',
        workspace_id: 'ws_1',
        cwd: '/home/ginwa/pabrik',
        cols: 80,
        rows: 24,
        exited: false,
        backend: 'posix-pty',
      },
    ]
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()

    expect(socketIds()).toEqual(['term-1', 'term-4'])
    expect(wrapper.find('[data-session="term-4"]').attributes('data-active')).toBe('true')

    wrapper.unmount()
  })

  it('grows the panel when the top edge is dragged and remembers the height', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    const panel = wrapper.find('[data-testid="terminal-panel"]')
    expect(panel.attributes('style')).toContain('height: 280px')

    wrapper
      .find('[data-testid="terminal-panel-resize"]')
      .element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientY: 400 }))
    document.dispatchEvent(new MouseEvent('mousemove', { clientY: 300 }))
    document.dispatchEvent(new MouseEvent('mouseup'))
    await flush()

    expect(panel.attributes('style')).toContain('height: 380px')
    expect(localStorage.getItem(HEIGHT_KEY)).toBe('380')

    wrapper.unmount()
  })

  it('stops a dragged height at what the window can hold', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    const ceiling = Math.round(window.innerHeight * 0.8)
    wrapper
      .find('[data-testid="terminal-panel-resize"]')
      .element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientY: 300 }))
    document.dispatchEvent(new MouseEvent('mousemove', { clientY: -5000 }))
    document.dispatchEvent(new MouseEvent('mouseup'))
    await flush()

    expect(wrapper.find('[data-testid="terminal-panel"]').attributes('style')).toContain(
      `height: ${ceiling}px`,
    )

    wrapper.unmount()
  })

  it('reopens the panel at the height of the last drag', async () => {
    localStorage.setItem(HEIGHT_KEY, '360')
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    expect(wrapper.find('[data-testid="terminal-panel"]').attributes('style')).toContain(
      'height: 360px',
    )

    wrapper.unmount()
  })

  it('maximizes the panel and restores it to the dragged height', async () => {
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    await wrapper.find('[data-testid="terminal-maximize"]').trigger('click')
    await flush()
    expect(wrapper.find('[data-testid="terminal-panel"]').attributes('style')).toContain(
      'height: 70vh',
    )

    await wrapper.find('[data-testid="terminal-maximize"]').trigger('click')
    await flush()
    expect(wrapper.find('[data-testid="terminal-panel"]').attributes('style')).toContain(
      'height: 280px',
    )

    wrapper.unmount()
  })

  it('offers a workspace to start the first shell in when nothing is running', async () => {
    apiState.sessions = []
    const wrapper = mountFooter()
    await flush()
    await openPanel(wrapper)

    expect(wrapper.find('[data-testid="terminal-empty"]').exists()).toBe(true)
    expect(tabIds(wrapper)).toEqual([])

    await wrapper
      .find('[data-testid="terminal-empty-new"][data-workspace-id="ws_2"]')
      .trigger('click')
    await flush()

    expect(createTerminalSession).toHaveBeenCalledWith('ws_2', '/home/ginwa/kabelweb', {})
    expect(tabIds(wrapper)).toEqual(['term-new-1'])

    wrapper.unmount()
  })
})
