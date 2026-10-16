/** Tests for WorkerElapsedChip.vue. */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref, type Ref } from 'vue'

import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import type { WorkerActivity } from '../WorkerElapsedChip.vue'

const mountChip = (
  activity: Record<string, WorkerActivity>,
  props: { sessionId: string; variant?: 'chip' | 'text'; testId?: string } = {
    sessionId: 's1',
  },
  nowMs = Date.now(),
) => {
  const provided = ref(activity) as Ref<Record<string, WorkerActivity>>
  const now = ref(nowMs) as Ref<number>
  return mount(WorkerElapsedChip, {
    props,
    global: { provide: { workerActivity: provided, workerNow: now } },
  })
}

const ago = (ms: number) => Date.now() - ms

describe('WorkerElapsedChip', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-10-09T12:00:00Z'))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders nothing when the session has no worker', () => {
    const wrapper = mountChip({})
    expect(wrapper.find('[data-testid="worker-elapsed-chip"]').exists()).toBe(false)
    expect(wrapper.text()).toBe('')
  })

  it('renders nothing for a different session', () => {
    const wrapper = mountChip({
      other: { startedAt: ago(60_000), lastActivityAt: ago(1_000), description: '' },
    })
    expect(wrapper.find('[data-testid="worker-elapsed-chip"]').exists()).toBe(false)
  })

  it('renders the elapsed time since the run started', () => {
    const wrapper = mountChip({
      s1: { startedAt: ago(252_000), lastActivityAt: ago(2_000), description: '' },
    })
    expect(wrapper.text()).toBe('4m 12s')
  })

  it('is not stale while the heartbeat is fresh', () => {
    const wrapper = mountChip({
      s1: { startedAt: ago(600_000), lastActivityAt: ago(3_000), description: '' },
    })
    const chip = wrapper.find('[data-testid="worker-elapsed-chip"]')
    expect(chip.attributes('data-stale')).toBe('false')
    expect(chip.classes()).not.toContain('worker-elapsed--stale')
  })

  it('turns amber once the heartbeat passes the stale threshold', () => {
    // A long run whose last heartbeat is 9 minutes old: alive in the DB,
    // but about to be reaped by the 600s cron.
    const wrapper = mountChip({
      s1: { startedAt: ago(600_000), lastActivityAt: ago(540_000), description: '' },
    })
    const chip = wrapper.find('[data-testid="worker-elapsed-chip"]')
    expect(chip.attributes('data-stale')).toBe('true')
    expect(chip.classes()).toContain('worker-elapsed--stale')
  })

  it('re-renders when the shared ticker advances', async () => {
    // The interval lives in App.vue (`workerNow`), not here — a sidebar
    // mounts one chip per row and a timer per row would be a timer per
    // row. The chip is pure derived state off that shared ref.
    const wrapper = mountChip({
      s1: { startedAt: ago(60_000), lastActivityAt: ago(1_000), description: '' },
    })
    expect(wrapper.text()).toBe('1m 00s')

    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test-only reach into Vue internals.
    const provides = (wrapper.vm as any).$.provides as Record<string, Ref<number> | undefined>
    const now = provides.workerNow
    expect(now).toBeDefined()
    now!.value += 12_000
    await nextTick()
    expect(wrapper.text()).toBe('1m 12s')
  })

  it('owns no timer of its own', () => {
    // One chip, zero intervals: the ticker is app-scoped.
    mountChip({
      s1: { startedAt: ago(60_000), lastActivityAt: ago(1_000), description: '' },
    })
    expect(vi.getTimerCount()).toBe(0)
  })

  it('honours a custom testId so each surface can target its own chip', () => {
    const wrapper = mountChip(
      { s1: { startedAt: ago(30_000), lastActivityAt: ago(1_000), description: '' } },
      { sessionId: 's1', testId: 'chat-elapsed-chip' },
    )
    expect(wrapper.find('[data-testid="chat-elapsed-chip"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worker-elapsed-chip"]').exists()).toBe(false)
  })

  it('applies the text variant for surfaces that already carry a status line', () => {
    const wrapper = mountChip(
      { s1: { startedAt: ago(30_000), lastActivityAt: ago(1_000), description: '' } },
      { sessionId: 's1', variant: 'text' },
    )
    expect(wrapper.find('.worker-elapsed--text').exists()).toBe(true)
    expect(wrapper.find('.worker-elapsed--chip').exists()).toBe(false)
  })

  it('puts the description in the tooltip so the label stays short', () => {
    const wrapper = mountChip({
      s1: {
        startedAt: ago(90_000),
        lastActivityAt: ago(1_000),
        description: 'Tool call: bash',
      },
    })
    expect(wrapper.attributes('title')).toContain('Tool call: bash')
    // The visible label is the duration only.
    expect(wrapper.text()).toBe('1m 30s')
  })

  it('renders without a provided map (isolated mount)', () => {
    // A host that never provided `workerActivity` must not crash.
    const wrapper = mount(WorkerElapsedChip, { props: { sessionId: 's1' } })
    expect(wrapper.text()).toBe('')
    wrapper.unmount()
  })
})
