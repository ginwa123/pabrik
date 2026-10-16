/** Tests for BackgroundCommandsPopup.vue — the background-command pill + running-command dialog
 * mounted beside the Skills pill in ChatView's composer footer. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import BackgroundCommandsPopup from '../BackgroundCommandsPopup.vue'
import {
  ApiError,
  getBackgroundProcessLog,
  getBackgroundProcesses,
  type BackgroundProcess,
} from '../../../api'
import { __dispatchSseBus } from '../../../helpers/sseBus'

vi.mock('../../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../api')>()
  return {
    ...actual,
    getBackgroundProcesses: vi.fn(),
    getBackgroundProcessLog: vi.fn(),
  }
})

const listMock = vi.mocked(getBackgroundProcesses)
const logMock = vi.mocked(getBackgroundProcessLog)

const SID = 'sess_bg_1'

const RUNNING: BackgroundProcess = {
  pid: 4242,
  command: 'sleep 60',
  log_path: '/tmp/bg-4242.log',
  started_at: Math.floor(Date.now() / 1000) - 120,
  status: 'running',
  running: true,
}

const DONE: BackgroundProcess = {
  pid: 4243,
  command: 'echo hi',
  log_path: '/tmp/bg-4243.log',
  started_at: Math.floor(Date.now() / 1000) - 3600,
  status: 'completed',
  running: false,
}

let wrapper: VueWrapper | null = null

function mountPopup(sessionId: string = SID) {
  return mount(BackgroundCommandsPopup, {
    props: { sessionId },
    attachTo: document.body,
  })
}

function dialogEl(): HTMLElement | null {
  return document.querySelector<HTMLElement>('[data-testid="bg-commands-dialog"]')
}

function rows(): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>('[data-testid="bg-process-row"]'))
}

function cleanupDialogDom(): void {
  document.querySelectorAll('[data-testid="bg-commands-dialog"]').forEach((el) => el.remove())
}

beforeEach(() => {
  listMock.mockResolvedValue({ processes: [], count: 0 })
  logMock.mockResolvedValue({
    pid: 4242,
    log_path: '/tmp/bg-4242.log',
    total_bytes: 9,
    truncated: false,
    content: 'hello log',
  })
})

afterEach(async () => {
  vi.useRealTimers()
  wrapper?.unmount()
  wrapper = null
  cleanupDialogDom()
  vi.clearAllMocks()
})

describe('pill visibility + count', () => {
  it('is hidden when the session has no background processes', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(wrapper.find('[data-testid="bg-commands-pill"]').exists()).toBe(false)
  })

  it('is hidden when processes exist but none are running', async () => {
    listMock.mockResolvedValue({ processes: [DONE], count: 1 })
    wrapper = mountPopup()
    await flushPromises()
    expect(wrapper.find('[data-testid="bg-commands-pill"]').exists()).toBe(false)
  })

  it('shows the running count (e.g. "1 running")', async () => {
    listMock.mockResolvedValue({ processes: [RUNNING, DONE], count: 2 })
    wrapper = mountPopup()
    await flushPromises()
    const pill = wrapper.find('[data-testid="bg-commands-pill"]')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toContain('1')
    expect(pill.text()).toContain('running')
  })
})

describe('dialog rows + status badges', () => {
  it('clicking the pill opens a dialog listing each row with badges', async () => {
    listMock.mockResolvedValue({ processes: [RUNNING, DONE], count: 2 })
    wrapper = mountPopup()
    await flushPromises()

    await wrapper.find('[data-testid="bg-commands-pill"]').trigger('click')
    await nextTick()

    expect(dialogEl()).not.toBeNull()
    expect(rows()).toHaveLength(2)
    const badges = Array.from(document.querySelectorAll('[data-testid="bg-status-badge"]'))
    expect(badges).toHaveLength(2)
    expect(badges[0]?.textContent).toContain('running')
    expect(badges[0]?.getAttribute('data-running')).toBe('true')
    expect(badges[1]?.textContent).toContain('completed')
    expect(badges[1]?.getAttribute('data-running')).toBe('false')
    // Row meta: pid + truncated command visible.
    expect(dialogEl()?.textContent).toContain('pid 4242')
    expect(dialogEl()?.textContent).toContain('sleep 60')
  })

  it('shows the empty state when the dialog opens with no processes', async () => {
    // Pill is hidden when empty, so open the dialog by seeding one
    // running process, then refresh the list to empty.
    listMock.mockResolvedValue({ processes: [RUNNING], count: 1 })
    wrapper = mountPopup()
    await flushPromises()
    await wrapper.find('[data-testid="bg-commands-pill"]').trigger('click')
    await nextTick()
    expect(dialogEl()).not.toBeNull()

    listMock.mockResolvedValue({ processes: [], count: 0 })
    __dispatchSseBus('queue', {
      action: 'deleted',
      id: 'q-1',
      session_id: SID,
    })
    await flushPromises()
    await nextTick()
    expect(document.querySelector('[data-testid="bg-empty"]')).not.toBeNull()
  })
})

describe('log tail on expand', () => {
  async function openDialogWithRunning(): Promise<void> {
    listMock.mockResolvedValue({ processes: [RUNNING], count: 1 })
    wrapper = mountPopup()
    await flushPromises()
    await wrapper.find('[data-testid="bg-commands-pill"]').trigger('click')
    await nextTick()
  }

  function expandFirstRow(): void {
    const row = rows()[0]
    const headerBtn = row?.querySelector('button')
    headerBtn?.click()
  }

  it('fetches the log on expand and renders the tail content', async () => {
    await openDialogWithRunning()
    expect(logMock).not.toHaveBeenCalled()

    expandFirstRow()
    await flushPromises()
    await nextTick()

    expect(logMock).toHaveBeenCalledTimes(1)
    expect(logMock).toHaveBeenCalledWith(SID, 4242, 20480)
    const content = document.querySelector('[data-testid="bg-log-content"]')
    expect(content?.textContent).toBe('hello log')
  })

  it('manual Refresh re-fetches the log', async () => {
    await openDialogWithRunning()
    expandFirstRow()
    await flushPromises()
    await nextTick()
    expect(logMock).toHaveBeenCalledTimes(1)

    const refreshBtn = document.querySelector<HTMLElement>('[data-testid="bg-log-refresh"]')
    refreshBtn?.click()
    await flushPromises()
    expect(logMock).toHaveBeenCalledTimes(2)
  })

  it('renders the missing-log marker content as-is (200, not an error)', async () => {
    logMock.mockResolvedValue({
      pid: 4242,
      log_path: '/tmp/bg-4242.log',
      total_bytes: 0,
      truncated: false,
      content: '(log file not found)',
    })
    await openDialogWithRunning()
    expandFirstRow()
    await flushPromises()
    await nextTick()

    expect(document.querySelector('[data-testid="bg-log-error"]')).toBeNull()
    expect(document.querySelector('[data-testid="bg-log-content"]')?.textContent).toBe(
      '(log file not found)',
    )
  })

  it('renders "process not found" on 404 (unknown pid)', async () => {
    logMock.mockRejectedValue(new ApiError(404, 'Not Found', 'background process not found'))
    await openDialogWithRunning()
    expandFirstRow()
    await flushPromises()
    await nextTick()

    expect(document.querySelector('[data-testid="bg-log-error"]')?.textContent).toContain(
      'process not found',
    )
  })

  it('collapsing the row stops the 2s log auto-refresh', async () => {
    vi.useFakeTimers()
    try {
      await openDialogWithRunning()
      expandFirstRow()
      await vi.advanceTimersByTimeAsync(0)
      expect(logMock).toHaveBeenCalledTimes(1)

      // Running row auto-refreshes every 2s.
      await vi.advanceTimersByTimeAsync(2000)
      expect(logMock).toHaveBeenCalledTimes(2)

      // Collapse -> no more log polls.
      expandFirstRow()
      await vi.advanceTimersByTimeAsync(6000)
      expect(logMock).toHaveBeenCalledTimes(2)
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('list is SSE-push driven (no 5s poll)', () => {
  it('fetches once on mount and does NOT re-poll on a timer', async () => {
    vi.useFakeTimers()
    try {
      wrapper = mountPopup()
      await vi.advanceTimersByTimeAsync(0)
      expect(listMock).toHaveBeenCalledTimes(1)

      await vi.advanceTimersByTimeAsync(5000)
      expect(listMock).toHaveBeenCalledTimes(1)

      await vi.advanceTimersByTimeAsync(15000)
      expect(listMock).toHaveBeenCalledTimes(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('no list calls after unmount', async () => {
    vi.useFakeTimers()
    try {
      wrapper = mountPopup()
      await vi.advanceTimersByTimeAsync(0)
      expect(listMock).toHaveBeenCalledTimes(1)

      wrapper.unmount()
      wrapper = null
      await vi.advanceTimersByTimeAsync(15000)
      expect(listMock).toHaveBeenCalledTimes(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('manual Refresh button re-fetches the list', async () => {
    listMock.mockResolvedValue({ processes: [RUNNING], count: 1 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    await wrapper.find('[data-testid="bg-commands-pill"]').trigger('click')
    await nextTick()
    const btn = document.querySelector<HTMLElement>('[data-testid="bg-list-refresh"]')
    expect(btn).not.toBeNull()
    btn?.click()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('session switch refetches for the new session and resets state', async () => {
    listMock.mockImplementation(async (sid: string) =>
      sid === SID ? { processes: [RUNNING], count: 1 } : { processes: [], count: 0 },
    )
    wrapper = mountPopup(SID)
    await flushPromises()
    expect(wrapper.find('[data-testid="bg-commands-pill"]').exists()).toBe(true)

    await wrapper.setProps({ sessionId: 'sess_other' })
    await flushPromises()
    expect(listMock).toHaveBeenCalledWith('sess_other')
    // New session has nothing running -> pill hides again.
    expect(wrapper.find('[data-testid="bg-commands-pill"]').exists()).toBe(false)
  })
})

describe('SSE-triggered refresh (backgroundProcess primary + queue fallback)', () => {
  it('refreshes the list on background_process created for this session', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    __dispatchSseBus('backgroundProcess', {
      action: 'created',
      session_id: SID,
      pid: 4242,
      command: 'sleep 60',
    })
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('refreshes the list on background_process completed for this session', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    __dispatchSseBus('backgroundProcess', {
      action: 'completed',
      session_id: SID,
      pid: 4242,
      command: 'sleep 60',
    })
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('ignores backgroundProcess events for other sessions', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    __dispatchSseBus('backgroundProcess', {
      action: 'created',
      session_id: 'sess_other',
      pid: 9999,
      command: 'sleep 60',
    })
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)
  })

  it('queue fallback still refreshes (completion also queues a message)', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    __dispatchSseBus('queue', {
      action: 'queued',
      id: 'q-1',
      message: 'hello',
      session_id: SID,
    })
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('ignores queue events for other sessions', async () => {
    listMock.mockResolvedValue({ processes: [], count: 0 })
    wrapper = mountPopup()
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)

    __dispatchSseBus('queue', {
      action: 'queued',
      id: 'q-9',
      message: 'other session',
      session_id: 'sess_other',
    })
    await flushPromises()
    expect(listMock).toHaveBeenCalledTimes(1)
  })
})

describe('ChatView footer wiring (static contract)', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const chatView = readFileSync(join(here, '..', '..', 'views', 'ChatView.vue'), 'utf8')

  it('imports BackgroundCommandsPopup next to SkillsPopup', () => {
    expect(chatView).toContain(
      "import BackgroundCommandsPopup from '../preview/BackgroundCommandsPopup.vue'",
    )
  })

  it('mounts the pill beside the Skills pill in the composer footer', () => {
    const skillsPill = chatView.indexOf('skill{{ sessionSkills.length')
    const mount = chatView.indexOf('<BackgroundCommandsPopup')
    expect(mount).toBeGreaterThan(-1)
    // Mounted AFTER the skills pill button, inside the same footer.
    expect(mount).toBeGreaterThan(skillsPill)
    expect(chatView).toContain(':session-id="sessionId"')
  })

  it('only mounts when a session is active', () => {
    expect(chatView).toContain(
      '<BackgroundCommandsPopup v-if="sessionId" :session-id="sessionId" />',
    )
  })
})
