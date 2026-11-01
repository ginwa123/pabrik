import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { WorkspaceUsage } from '../api'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, fetchWorkspaceUsage: vi.fn() }
})

import { fetchWorkspaceUsage } from '../api'
import WorkspaceUsageSection from '../components/workspace/WorkspaceUsageSection.vue'

const mockedFetch = vi.mocked(fetchWorkspaceUsage)

function usage(overrides: Partial<WorkspaceUsage> = {}): WorkspaceUsage {
  return {
    workspace_id: 'ws_1',
    range: '30d',
    totals: {
      calls: 20_026,
      sessions: 89,
      input_tokens: 5_559_477_914,
      output_tokens: 17_262_188,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      calls_with_cache: 0,
      excluded_calls: 0,
      tool_calls: 23_474,
      cache_hit_rate: null,
    },
    daily: [
      {
        day: '2026-10-20',
        calls: 2_367,
        input_tokens: 840_592_805,
        cache_read_tokens: 0,
        cache_hit_rate: null,
      },
      {
        day: '2026-10-21',
        calls: 2_368,
        input_tokens: 773_768_377,
        cache_read_tokens: 0,
        cache_hit_rate: null,
      },
    ],
    models: [
      {
        model: 'deepseek-v4.1-flash',
        calls: 8_799,
        input_tokens: 2_265_987_319,
        calls_with_cache: 0,
        cache_hit_rate: null,
      },
    ],
    tools: [{ tool_name: 'command', calls: 15_645 }],
    finish_reasons: [
      { reason: 'tool_calls', calls: 19_772 },
      { reason: 'stop', calls: 254 },
    ],
    cache_series: null,
    ...overrides,
  }
}

function mountSection(workspaceId = 'ws_1') {
  return mount(WorkspaceUsageSection, { props: { workspaceId } })
}

describe('WorkspaceUsageSection', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockedFetch.mockReset()
  })

  it('draws a dash, never 0%, when no call reported a cache counter', async () => {
    mockedFetch.mockResolvedValue(usage())
    const wrapper = mountSection()
    await flushPromises()

    expect(wrapper.get('[data-testid="usage-figure-cache-read-rate"]').text()).toBe('–')
    expect(wrapper.get('[data-testid="usage-figure-cache-read-rate"]').text()).not.toContain('0%')
    expect(wrapper.get('[data-testid="usage-no-telemetry"]').text()).toContain(
      'No provider reported',
    )
  })

  it('renders the totals and the per-model coverage', async () => {
    mockedFetch.mockResolvedValue(usage())
    const wrapper = mountSection()
    await flushPromises()

    expect(wrapper.get('[data-testid="usage-figure-input-tokens"]').text()).toBe('5.56B')
    expect(wrapper.get('[data-testid="usage-figure-calls"]').text()).toBe('20,026')
    expect(wrapper.get('[data-testid="usage-figure-tool-calls"]').text()).toBe('23,474')
    expect(wrapper.get('[data-testid="usage-figure-cache-counters"]').text()).toBe('0.0%')
    expect(wrapper.findAll('[data-testid="usage-model-row"]')).toHaveLength(1)
  })

  it('names the rows it had to exclude instead of printing a rate over 100%', async () => {
    const withExcluded = usage()
    withExcluded.totals = { ...withExcluded.totals, excluded_calls: 3 }
    mockedFetch.mockResolvedValue(withExcluded)
    const wrapper = mountSection()
    await flushPromises()

    expect(wrapper.get('[data-testid="usage-excluded"]').text()).toContain('3 call(s)')
  })

  it('says there is no call in range rather than showing five zeros', async () => {
    const empty = usage()
    empty.totals = { ...empty.totals, calls: 0, input_tokens: 0, sessions: 0, tool_calls: 0 }
    empty.daily = []
    empty.models = []
    empty.tools = []
    empty.finish_reasons = []
    mockedFetch.mockResolvedValue(empty)
    const wrapper = mountSection()
    await flushPromises()

    expect(wrapper.get('[data-testid="usage-empty"]').text()).toContain('No LLM call')
    expect(wrapper.find('[data-testid="usage-cache-panel"]').exists()).toBe(false)
  })

  it('shows the failure and a retry instead of an empty page', async () => {
    mockedFetch.mockRejectedValueOnce(new Error('HTTP 500'))
    const wrapper = mountSection()
    await flushPromises()

    expect(wrapper.get('[data-testid="usage-error"]').text()).toContain('HTTP 500')

    mockedFetch.mockResolvedValueOnce(usage())
    await wrapper.get('[data-testid="usage-retry"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="usage-error"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="usage-figure-calls"]').text()).toBe('20,026')
  })

  it('refetches with the range the user picked', async () => {
    mockedFetch.mockResolvedValue(usage())
    const wrapper = mountSection()
    await flushPromises()
    expect(mockedFetch).toHaveBeenCalledWith('ws_1', '30d')

    await wrapper.get('[data-testid="usage-range-7d"]').trigger('click')
    await flushPromises()
    expect(mockedFetch).toHaveBeenLastCalledWith('ws_1', '7d')
  })

  it('does not paint one workspace totals under another workspace header', async () => {
    mockedFetch.mockResolvedValue(usage())
    const wrapper = mountSection('ws_1')
    await flushPromises()
    expect(wrapper.find('[data-testid="usage-figures"]').exists()).toBe(true)

    await wrapper.setProps({ workspaceId: 'ws_2' })
    await flushPromises()
    expect(wrapper.find('[data-testid="usage-figures"]').exists()).toBe(false)

    mockedFetch.mockResolvedValue({ ...usage(), workspace_id: 'ws_2' })
    const fresh = mountSection('ws_2')
    await flushPromises()
    expect(mockedFetch).toHaveBeenLastCalledWith('ws_2', '30d')
    expect(fresh.find('[data-testid="usage-figures"]').exists()).toBe(true)
  })
})
