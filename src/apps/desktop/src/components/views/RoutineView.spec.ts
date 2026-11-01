import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { createPinia, setActivePinia } from 'pinia'
import RoutineView from './RoutineView.vue'
import * as api from '../../api'

const { replaceMock } = vi.hoisted(() => ({ replaceMock: vi.fn() }))
vi.mock('vue-router', () => ({ useRouter: () => ({ replace: replaceMock }) }))

const routineFixture = {
  id: 'item_r_1',
  workspace_item_id: 'item_r_1',
  description: 'nightly things',
  instruction: 'do things',
  schedule: '0 9 * * *',
  selected_profile_model: '',
  enabled: true,
  last_run_at: '',
  next_run_at: '2026-01-02 09:00:00',
  last_status: 'idle',
  last_error: '',
  created_at: '',
  updated_at: '',
}

const agentProfiles = {
  '900ribu': { model: 'deepseek/deepseek-v4.1-flash', base_url: 'https://api.example/v1' },
  switched_off: { model: 'gpt-x', base_url: 'https://off.example', enabled: false },
}

const noWorkers = { workers: [], count: 0 }

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

async function flush() {
  await nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await nextTick()
}

describe('RoutineView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    replaceMock.mockReset()
    vi.spyOn(api, 'getRoutineItem').mockResolvedValue({ routine: { ...routineFixture } })
    vi.spyOn(api, 'updateRoutineItem').mockImplementation(async (_ws, _item, data) => ({
      routine: { ...routineFixture, ...data },
    }))
    vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue({ profiles: agentProfiles })
    vi.spyOn(api, 'getWorkers').mockResolvedValue(noWorkers)
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

  it('shows the agent model the routine already fires under', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, selected_profile_model: '900ribu' },
    })
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-agent-model-picker"]').text()).toContain('900ribu')
  })

  it('offers the workspace agents that are switched on, not the disabled ones', async () => {
    const wrapper = mountView()
    await settle()
    await wrapper.find('[data-testid="routine-agent-model-picker"]').trigger('click')
    const options = wrapper.findAll('[data-testid="routine-agent-model-option"]')
    const labels = options.map((o) => o.text())
    expect(labels.some((l) => l.includes('900ribu'))).toBe(true)
    expect(labels.some((l) => l.includes('switched_off'))).toBe(false)
  })

  it('persists the picked agent model on the routine as soon as it is picked', async () => {
    const wrapper = mountView()
    await settle()
    await wrapper.find('[data-testid="routine-agent-model-picker"]').trigger('click')
    const option = wrapper
      .findAll('[data-testid="routine-agent-model-option"]')
      .find((o) => o.text().includes('900ribu'))
    await option!.trigger('click')
    await nextTick()

    expect(api.updateRoutineItem).toHaveBeenCalledWith('ws_1', 'item_r_1', {
      selected_profile_model: '900ribu',
    })
    expect(wrapper.find('[data-testid="routine-agent-model-picker"]').text()).toContain('900ribu')
  })

  it('keeps the previous agent model when the server rejects the new one', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, selected_profile_model: '900ribu' },
    })
    vi.mocked(api.updateRoutineItem).mockRejectedValue(new Error('HTTP 500'))
    const wrapper = mountView()
    await settle()
    await wrapper.find('[data-testid="routine-agent-model-picker"]').trigger('click')
    const option = wrapper
      .findAll('[data-testid="routine-agent-model-option"]')
      .find((o) => o.text().includes('Default'))
    await option!.trigger('click')
    await nextTick()

    expect(wrapper.find('[data-testid="routine-agent-model-picker"]').text()).toContain('900ribu')
    expect(wrapper.find('[data-testid="routine-agent-model-error"]').text()).toContain('HTTP 500')
  })

  it('lists the chat session that is running so it can be opened', async () => {
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'running' },
    })
    vi.mocked(api.getWorkers).mockResolvedValue({
      workers: [
        {
          id: 'item_r_1',
          session_id: 'item_r_1',
          working_directory: '',
          last_activity: '1793536000',
          last_activity_description: 'read_file src/app.zig',
          created_at: '2026-11-01 12:00:00',
          status: 'running',
          is_running: true,
          queue_count: 0,
        },
      ],
      count: 1,
    })
    const wrapper = mountView()
    await settle()

    const row = wrapper.find('[data-testid="routine-running-session"]')
    expect(row.exists()).toBe(true)
    expect(row.text()).toContain('Nightly')
    expect(row.text()).toContain('read_file src/app.zig')

    await row.trigger('click')
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app/ws_1/chat/item_r_1',
      query: {},
    })
  })

  it('shows the running session right after Run now', async () => {
    vi.spyOn(api, 'runWorkspaceRoutine').mockResolvedValue({ session_id: 'item_r_1' })
    vi.mocked(api.getRoutineItem)
      .mockResolvedValueOnce({ routine: { ...routineFixture } })
      .mockResolvedValue({ routine: { ...routineFixture, last_status: 'running' } })
    vi.mocked(api.getWorkers).mockResolvedValue({
      workers: [
        {
          id: 'item_r_1',
          session_id: 'item_r_1',
          working_directory: '',
          last_activity: '1793536000',
          last_activity_description: 'grep -r TODO src',
          created_at: '2026-11-01 12:00:00',
          status: 'running',
          is_running: true,
          queue_count: 0,
        },
      ],
      count: 1,
    })
    const wrapper = mountView()
    await settle()
    expect(wrapper.find('[data-testid="routine-running-sessions"]').exists()).toBe(false)

    await wrapper.find('[data-testid="routine-run"]').trigger('click')
    await flush()

    expect(api.runWorkspaceRoutine).toHaveBeenCalledWith('ws_1', 'item_r_1', 'item_r_1')
    const row = wrapper.find('[data-testid="routine-running-session"]')
    expect(row.exists()).toBe(true)
    expect(row.text()).toContain('grep -r TODO src')
    wrapper.unmount()
  })

  it('clears the running session once the run settles', async () => {
    vi.useFakeTimers()
    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'running' },
    })
    vi.mocked(api.getWorkers).mockResolvedValue({
      workers: [
        {
          id: 'item_r_1',
          session_id: 'item_r_1',
          working_directory: '',
          last_activity: '1793536000',
          last_activity_description: '',
          created_at: '2026-11-01 12:00:00',
          status: 'running',
          is_running: true,
          queue_count: 0,
        },
      ],
      count: 1,
    })
    const wrapper = mountView()
    await vi.advanceTimersByTimeAsync(0)
    expect(wrapper.find('[data-testid="routine-running-sessions"]').exists()).toBe(true)

    vi.mocked(api.getRoutineItem).mockResolvedValue({
      routine: { ...routineFixture, last_status: 'success' },
    })
    vi.mocked(api.getWorkers).mockResolvedValue(noWorkers)
    await vi.advanceTimersByTimeAsync(5000)

    expect(wrapper.find('[data-testid="routine-running-sessions"]').exists()).toBe(false)
    wrapper.unmount()
  })
})
