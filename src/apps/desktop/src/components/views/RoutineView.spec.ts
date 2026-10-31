import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { createPinia, setActivePinia } from 'pinia'
import RoutineView from './RoutineView.vue'
import * as api from '../../api'

const routineFixture = {
  id: 'item_r_1',
  workspace_item_id: 'item_r_1',
  description: 'nightly things',
  instruction: 'do things',
  schedule: '0 9 * * *',
  enabled: true,
  last_run_at: '',
  next_run_at: '2026-01-02 09:00:00',
  last_status: 'idle',
  last_error: '',
  created_at: '',
  updated_at: '',
}

function mountView() {
  return mount(RoutineView, {
    props: {
      item: { id: 'item_r_1', name: 'Nightly', item_type: 'routine' } as never,
      workspaceId: 'ws_1',
      itemId: 'item_r_1',
    },
  })
}

async function settle() {
  await nextTick()
  await nextTick()
}

describe('RoutineView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getRoutineItem').mockResolvedValue({ routine: { ...routineFixture } })
    vi.spyOn(api, 'updateRoutineItem').mockImplementation(async (_ws, _item, data) => ({
      routine: { ...routineFixture, ...data },
    }))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('loads and renders the routine fields', async () => {
    const wrapper = mountView()
    await settle()
    expect(api.getRoutineItem).toHaveBeenCalledWith('ws_1', 'item_r_1')
    const desc = wrapper.find('[data-testid="routine-description"]')
    expect((desc.element as HTMLInputElement).value).toBe('nightly things')
    const sched = wrapper.find('[data-testid="routine-schedule"]')
    expect((sched.element as HTMLInputElement).value).toBe('0 9 * * *')
  })

  it('states the status and the next fire, labelled as UTC', async () => {
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-status"]').text()).toBe('Idle')
    const line = wrapper.find('[data-testid="routine-status-line"]').text()
    expect(line).toContain('next 2026-01-02 09:00:00 UTC')
  })

  it('shows a manual-only routine without a next fire', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, schedule: '', next_run_at: '' },
    })
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-status-line"]').text()).toContain('manual only')
  })

  it('surfaces the last error of a failed run', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'failed', last_error: 'LLM rate limit' },
    })
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-status"]').text()).toBe('Failed')
    expect(wrapper.find('[data-testid="routine-last-error"]').text()).toBe('LLM rate limit')
  })

  it('does not let a disabled routine be run manually', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, enabled: false },
    })
    const wrapper = mountView()
    await settle()
    const run = wrapper.find('[data-testid="routine-run"]')
    expect((run.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
    expect(run.attributes('title')).toBe('Enable the routine to run it')
  })

  it('re-reads the routine while a run is still in flight and stops once it settles', async () => {
    vi.useFakeTimers()
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'running' },
    })
    const wrapper = mountView()
    await vi.advanceTimersByTimeAsync(0)
    const callsAfterLoad = vi.mocked(api.getRoutineItem).mock.calls.length

    await vi.advanceTimersByTimeAsync(5000)
    expect(vi.mocked(api.getRoutineItem).mock.calls.length).toBe(callsAfterLoad + 1)

    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'success' },
    })
    await vi.advanceTimersByTimeAsync(5000)
    const callsAfterSettle = vi.mocked(api.getRoutineItem).mock.calls.length

    await vi.advanceTimersByTimeAsync(20000)
    expect(vi.mocked(api.getRoutineItem).mock.calls.length).toBe(callsAfterSettle)
    wrapper.unmount()
  })

  it('shows a load error when the API fails', async () => {
    vi.mocked(api.getRoutineItem).mockRejectedValueOnce(new Error('HTTP 404'))
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-error"]').text()).toContain('HTTP 404')
  })

  it('shows an inline error for a bad cron and disables Save', async () => {
    const wrapper = mountView()
    await settle()
    await wrapper.find('[data-testid="routine-schedule"]').setValue('0 9 * * * *')
    await nextTick()
    expect(wrapper.text()).toContain('exactly 5 fields')
    expect(
      (wrapper.find('[data-testid="routine-save"]').element as HTMLButtonElement).hasAttribute(
        'disabled',
      ),
    ).toBe(true)
  })

  it('saves the edited fields via updateRoutineItem', async () => {
    const wrapper = mountView()
    await settle()
    await wrapper.find('[data-testid="routine-instruction"]').setValue('do other things')
    await wrapper.find('[data-testid="routine-save"]').trigger('click')
    await nextTick()
    expect(api.updateRoutineItem).toHaveBeenCalledWith('ws_1', 'item_r_1', {
      description: 'nightly things',
      instruction: 'do other things',
      schedule: '0 9 * * *',
      enabled: true,
    })
  })
})
