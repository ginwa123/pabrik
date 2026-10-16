// Behavioural tests for RoutineView.
import { describe, expect, it, beforeEach, vi } from 'vitest'
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

describe('RoutineView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getRoutineItem').mockResolvedValue({ routine: { ...routineFixture } })
    vi.spyOn(api, 'updateRoutineItem').mockImplementation(async (_ws, _item, data) => ({
      routine: { ...routineFixture, ...data },
    }))
  })

  it('loads and renders the routine fields', async () => {
    const wrapper = mountView()
    await nextTick()
    await nextTick()
    expect(api.getRoutineItem).toHaveBeenCalledWith('ws_1', 'item_r_1')
    const desc = wrapper.find('[data-testid="routine-description"]')
    expect((desc.element as HTMLInputElement).value).toBe('nightly things')
    const sched = wrapper.find('[data-testid="routine-schedule"]')
    expect((sched.element as HTMLInputElement).value).toBe('0 9 * * *')
    expect(wrapper.find('[data-testid="routine-status"]').text()).toContain('next 2026-01-02 09:00:00')
  })

  it('shows a load error when the API fails', async () => {
    vi.mocked(api.getRoutineItem).mockRejectedValueOnce(new Error('HTTP 404'))
    const wrapper = mountView()
    await nextTick()
    await nextTick()
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="routine-error"]').text()).toContain('HTTP 404')
  })

  it('shows an inline error for a bad cron and disables Save', async () => {
    const wrapper = mountView()
    await nextTick()
    await nextTick()
    const sched = wrapper.find('[data-testid="routine-schedule"]')
    await sched.setValue('bogus cron expression with too many fields x')
    await nextTick()
    expect(wrapper.text()).toContain('exactly 5 fields')
    const save = wrapper.find('[data-testid="routine-save"]')
    expect((save.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
  })

  it('saves the edited fields via updateRoutineItem', async () => {
    const wrapper = mountView()
    await nextTick()
    await nextTick()
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
